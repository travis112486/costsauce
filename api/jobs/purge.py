# api/jobs/purge.py
"""Task 12: the scheduled purge job.

Three independent halves, meant to run unattended on a schedule (cron, per
the runbook note carried to Task 14: "api/jobs/purge.py runs daily via
cron"):

  run_purge(db_url, storage_delete=None) -> int
      Hard-deletes organizations whose 30-day grace window has elapsed, via
      migration 0007's `purge_scheduled_orgs(interval)`. Storage objects are
      removed BEFORE the row: a crash between the two leaves the (still
      scheduled) org row behind, so the next run re-selects the same org and
      retries the storage delete, rather than deleting the row first and
      leaving files an org no longer exists to own.

  purge_pending_identities(db_url, ...) -> int
      Finishes what `DELETE /me` cannot: removes the `auth.users` row itself,
      via Supabase's Admin API (`auth.admin.deleteUser`) authenticated with
      the service-role key. Migration 0003 deliberately grants nothing on
      `auth.users` (a GRANT SELECT there was measured to leak every tenant's
      user list), and on Supabase that table is owned by `supabase_auth_admin`
      -- no migration running as the project's migration role can grant
      itself access. Without this half, "delete my account" is a
      deactivation, not a deletion: the user can still mint a JWT and sees an
      empty account, which fails App Store guideline 5.1.1(v). This is the
      reason Task 11 added the `deleted_accounts` tombstone in the first
      place -- see that migration's own comment on the accessor below.

  purge_expired_sync_ops(db_url) -> int
      Reaps `sync_ops` rows past the 7-day idempotency-ledger TTL (spec
      §5.3), via migration 0014's `purge_expired_sync_ops(interval)`
      SECURITY DEFINER function -- same name, deliberately, as this Python
      wrapper; different arity is what disambiguates a call site.

All three halves are independent of each other and of each other's
failures: an org can be purged with accounts still pending identity purge
(unrelated clocks -- DELETE /me carries no grace period), an identity can be
purged for a user who never owned anything, and the sync_ops ledger ages out
on its own 7-day clock tied to neither. None blocks or is blocked by either
of the others; see `run_all` at the bottom, which is what the cron
invocation actually calls.
"""
import asyncio
import logging
import os

import httpx
import psycopg

from api.routes.deletion import GRACE_DAYS

log = logging.getLogger(__name__)

# Single source of truth for the grace period, shared with
# api/routes/deletion.py rather than a second "30" literal living in this
# module. GRACE_DAYS is a human-partner product decision recorded in
# deletion.py (its docstring: "The 30-day window is a human-partner decision
# and MUST be stated in the privacy policy"); this job only consumes it, so a
# future change to that one constant cannot silently leave the SQL argument
# passed to `purge_scheduled_orgs` out of step with what `POST
# /orgs/{id}/deletion` actually promised the user.
GRACE = f"{GRACE_DAYS} days"


# ---------------------------------------------------------------------------
# Half 1: organizations
# ---------------------------------------------------------------------------
class StorageNotConfiguredError(RuntimeError):
    """Raised by `run_purge` when it purged one or more organizations with no
    `storage_delete` callback configured -- their storage was never deleted.

    Carries `.purged` (the count that actually happened; the DB commit is not
    rolled back on this exception) so a caller like `run_all` can still
    report what succeeded while correctly treating the run as failed.
    """

    def __init__(self, purged: int, org_ids: list):
        super().__init__(
            f"{purged} organization(s) were purged with no storage_delete "
            f"configured; their storage was NOT deleted: {org_ids}"
        )
        self.purged = purged
        self.org_ids = org_ids


async def run_purge(db_url: str, storage_delete=None) -> int:
    """Hard-delete organizations whose grace window has elapsed.

    The candidate set is read via migration 0008's
    `organizations_pending_purge(interval)`, NOT a raw
    `SELECT ... FROM organizations`. `organizations` is FORCE ROW LEVEL
    SECURITY (0004), and the only SELECT policies on it belong to
    `authenticated` (scoped to the caller's own orgs), `deletion_definer` and
    `purge_definer` -- both revoked from the migration runner at the end of
    0007. A plain migration-runner connection issuing that SELECT directly
    (this job's first-draft approach) would see ZERO rows on real,
    non-superuser Supabase -- invisible in THIS codebase's own test harness,
    where `db_url` connects as a genuine Postgres superuser that bypasses RLS
    regardless of FORCE. See 0008's own migration comment for the confirmed
    reproduction against a purpose-built no-privilege role.

    That accessor's `FOR UPDATE ORDER BY id` is load-bearing, not decorative,
    and is why it has to be a SECURITY DEFINER function rather than a plain
    query this job issues itself:

    * `FOR UPDATE` places a row lock on exactly the doomed rows. Locks
      belong to the TRANSACTION that physically takes them, not to whichever
      privilege admitted the read (confirmed empirically: a no-privilege
      role calling a SECURITY DEFINER function that does `FOR UPDATE`
      internally holds the same lock a direct, privileged `FOR UPDATE` would
      have), so it blocks `cancel_org_deletion`'s UPDATE
      (api/routes/deletion.py) against these rows until THIS job's
      transaction ends. Without it, a cancel could commit between this read
      and the storage deletes below, and this job would delete a saved org's
      files anyway -- the storage-side mirror of the row-purge race
      `purge_scheduled_orgs` already guards against with its own advisory
      lock and re-check.
    * `ORDER BY id` matches every other multi-row locker in this codebase
      (`purge_scheduled_orgs`'s own loop, `_lock_caller_orgs`), so two
      overlapping invocations of this job (a slow run still finishing when
      the next scheduled trigger fires) can never deadlock against each
      other over the doomed set.

    `purge_scheduled_orgs` re-checks the identical predicate itself, inside
    this same transaction and therefore against the same `now()` snapshot
    (Postgres fixes `now()` for the lifetime of a transaction), so the set
    it actually deletes cannot differ from the set storage was just cleared
    for -- the FOR UPDATE lock taken above is what makes that guarantee hold
    across the gap between this read and that call, not just the shared
    snapshot.

    NOTE on `interval %s`: the brief's own given code writes the grace
    argument as a bind parameter (`... - interval %s`, params=(GRACE,));
    that is not valid Postgres syntax -- `INTERVAL '...'` is a generic
    type-constant literal and does not accept a bind parameter in that
    position. Confirmed against a live Postgres 17 instance before writing
    this: it raises `SyntaxError: syntax error at or near "$1"`. Written
    here as `%s::interval` instead, which casts a normally-bound text
    parameter.

    Raises `StorageNotConfiguredError` -- AFTER committing the purge -- if
    `storage_delete` was `None` and one or more organizations were actually
    purged. A purge that ran with no storage cleanup wired up must not look
    like a healthy no-op to whatever is watching this job's exit code; see
    the exception's own docstring.
    """
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    storage_skipped_for: list | None = None
    try:
        cur = await conn.execute(
            "SELECT id FROM organizations_pending_purge(%s::interval)", (GRACE,)
        )
        doomed = [r[0] for r in await cur.fetchall()]
        if not doomed:
            await conn.rollback()
            return 0

        if storage_delete is not None:
            for org_id in doomed:
                await storage_delete(f"{org_id}/")
        else:
            # Review Important-3: a misconfigured deployment (no
            # storage_delete wired up -- exactly what __main__ calls with
            # today, since no storage bucket/client exists anywhere in this
            # codebase yet) must not look like a healthy run once something
            # was actually purged. Logging alone was not enough -- combined
            # with a caller that only checks the return value or exit code,
            # a run that purged real rows and orphaned their storage was
            # indistinguishable from an idle night. So this case still
            # completes the purge (the org row itself is not held hostage to
            # a bucket that doesn't exist yet) but is raised as a failure
            # below, once the commit is safely done.
            log.error(
                "storage_delete is not configured; storage objects for %d "
                "organization(s) about to be purged will NOT be deleted: %s",
                len(doomed), doomed,
            )
            storage_skipped_for = doomed

        cur = await conn.execute("SELECT purge_scheduled_orgs(%s::interval)", (GRACE,))
        (purged,) = await cur.fetchone()
        await conn.commit()
    except BaseException:
        await conn.rollback()
        raise
    finally:
        await conn.close()

    if storage_skipped_for is not None:
        raise StorageNotConfiguredError(purged, storage_skipped_for)
    return purged


# ---------------------------------------------------------------------------
# Half 2: identities
# ---------------------------------------------------------------------------
class IdentityPurgeError(RuntimeError):
    pass


class PartialIdentityPurgeError(RuntimeError):
    """Raised by `purge_pending_identities` when the run finished but one or
    more pending identities were NOT purged (an Admin API failure, or a
    reported success that the tombstone re-check disproved).

    Review Important-2: every pending id is still attempted regardless of
    what happened to earlier ones (this is raised only after the loop
    finishes, never used to abort it early), but the run as a WHOLE must not
    report success -- a night where the Admin API is down for every account
    and every attempt fails must not look identical to a night with nothing
    pending. `.purged` and `.failed` let a caller like `run_all` still report
    what happened while correctly treating the run as failed.
    """

    def __init__(self, purged: int, failed: int):
        super().__init__(
            f"identity purge finished with {failed} failure(s) (purged {purged})"
        )
        self.purged = purged
        self.failed = failed


async def _delete_identity(
    user_id: str,
    *,
    supabase_url: str,
    service_role_key: str,
    http: httpx.AsyncClient,
) -> bool:
    """One call to Supabase's Admin API, `DELETE /auth/v1/admin/users/{id}`.

    Returns True if the identity is confirmed gone from Supabase's point of
    view (2xx), or already gone (404). 404 here is not "there was nothing to
    do" in the sense api/services/billing.py's no-customer-id case is -- it
    can only mean another purge run already removed this exact identity
    between this job's own read of `accounts_pending_identity_purge()` and
    this call: `deleted_accounts.user_id` is a foreign key onto `auth.users`,
    so a listed row is only possible while the identity it names still
    exists, and the identity's removal and the tombstone's CASCADE-clearing
    happen atomically together. So a 404 for a row we just read as pending
    is a race with a concurrent run, not a stale record -- treated as
    success, never as "nothing needed doing" the way billing.py's None
    customer_id is.

    Raises IdentityPurgeError on any other non-2xx. The message deliberately
    carries only the user id and status code -- never `resp.text` -- so a
    response body containing anything sensitive (Supabase's own error
    payload format is not this codebase's contract to trust) cannot end up
    in a log line the way api/services/apple.py's revoke error message
    includes Apple's response text; unlike Apple's revoke, this endpoint's
    response is not documented anywhere in this codebase as safe to log
    verbatim, and this job runs against every deleted user in the system,
    not developer-supplied test tokens.

    The service-role key is used ONLY in the Authorization/apikey headers of
    this one request. It is never interpolated into a log message, an
    exception, or a query -- headers are the only place it appears, over
    TLS.
    """
    resp = await http.delete(
        f"{supabase_url.rstrip('/')}/auth/v1/admin/users/{user_id}",
        headers={
            "apikey": service_role_key,
            "Authorization": f"Bearer {service_role_key}",
        },
    )
    if resp.status_code == 404:
        return True
    if resp.status_code >= 400:
        raise IdentityPurgeError(
            f"identity purge failed for {user_id}: Supabase Admin API returned "
            f"{resp.status_code}"
        )
    return True


async def purge_pending_identities(
    db_url: str,
    *,
    supabase_url: str | None = None,
    service_role_key: str | None = None,
    http: httpx.AsyncClient | None = None,
) -> int:
    """Remove every `auth.users` row that `DELETE /me` could not.

    This is a SEPARATE admin client from the pooled `app_user` connection
    every request-path route uses. `supabase_url`/`service_role_key` are read
    from the environment by default (`SUPABASE_URL` /
    `SUPABASE_SERVICE_ROLE_KEY`) and used for exactly one thing: the Admin
    API call above. Nothing here grants this job's Postgres connection any
    new privilege, and the service-role key never touches Postgres at all --
    it cannot become a route to bypass RLS for ordinary queries, because it
    is never on that path to begin with.

    Enumerates via `accounts_pending_identity_purge()` -- migration 0007's
    SECURITY DEFINER accessor, owned by `purge_definer` -- and NEVER via a
    direct `SELECT ... FROM deleted_accounts`. That table is FORCE RLS with
    only an INSERT policy (a tenant recording its own deletion); a
    non-superuser migration role reading it directly, even with an explicit
    `GRANT SELECT`, would see zero rows and this job would silently purge no
    identities at all -- exactly the failure 0007's own comment on the
    accessor warns about, and exactly why the accessor exists.

    This job also never issues `DELETE FROM deleted_accounts`. There is no
    grant, anywhere, for any role, that would let it -- 0007 hands
    `purge_definer` SELECT on that table and nothing else. The row is
    cleared by ONLY the `ON DELETE CASCADE` from `auth.users`, which fires
    the moment the identity is actually removed. So "clear the tombstone on
    confirmed success" (this task's correction 2) is implemented as: call
    the Admin API, then re-check the SAME accessor for that one user id, and
    count the purge only if it is actually gone. If the accessor still lists
    it after a 2xx/404, the Admin API's answer and the database's state have
    diverged -- logged as an error, left untouched for the next run, never
    assumed complete. This is the one guard against the self-review question
    this task poses directly: a status code alone is not proof, re-reading
    the accessor is.

    One identity failing does not abort the run: every pending id is
    attempted independently of what happened to the ones before it, so a
    single bad row (or a transient 5xx) cannot block every other deletion
    behind it. Nothing is lost on a partial failure either -- an id that
    was not purged this run simply remains in `deleted_accounts`, which
    exists for exactly this, and is retried unchanged next time.

    Raises `PartialIdentityPurgeError` -- only after every pending id has
    been attempted -- if one or more were not purged. Review Important-2:
    the original version of this function caught every per-identity
    exception and simply returned a lower count, which meant a run where the
    Admin API returned 5xx for EVERY pending identity still returned `0` and
    raised nothing -- indistinguishable from a quiet night with nothing
    pending, for the exact half of this job that exists to satisfy App
    Store guideline 5.1.1(v). It no longer does.
    """
    supabase_url = supabase_url or os.environ.get("SUPABASE_URL")
    service_role_key = service_role_key or os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not supabase_url or not service_role_key:
        raise RuntimeError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must both be configured to "
            "purge pending identities"
        )

    owns_client = http is None
    http = http or httpx.AsyncClient(timeout=10)
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=True)
    purged = 0
    failed = 0
    try:
        cur = await conn.execute("SELECT user_id FROM accounts_pending_identity_purge()")
        pending = [r[0] for r in await cur.fetchall()]

        for user_id in pending:
            try:
                await _delete_identity(
                    str(user_id),
                    supabase_url=supabase_url,
                    service_role_key=service_role_key,
                    http=http,
                )
            except Exception:
                # Deliberately total, not just IdentityPurgeError: a timeout,
                # a DNS failure or a TLS error out of httpx must be exactly
                # as non-fatal to the REST of this run as a documented 4xx/5xx
                # from the Admin API. One bad identity must never take the
                # rest of an unattended run down with it -- the loop keeps
                # going; only the eventual return/raise reflects the failure.
                log.exception(
                    "identity purge failed for %s; left in deleted_accounts for "
                    "the next run", user_id,
                )
                failed += 1
                continue

            cur = await conn.execute(
                "SELECT count(*) FROM accounts_pending_identity_purge() WHERE user_id = %s",
                (user_id,),
            )
            (still_pending,) = await cur.fetchone()
            if still_pending:
                log.error(
                    "Supabase reported %s as removed but its tombstone is still "
                    "present; NOT counting it as purged", user_id,
                )
                failed += 1
                continue
            purged += 1
    finally:
        await conn.close()
        if owns_client:
            await http.aclose()

    if failed:
        raise PartialIdentityPurgeError(purged, failed)
    return purged


# ---------------------------------------------------------------------------
# Half 3: sync_ops TTL (§5.3 — the ledger holds 7 days of applied op results)
# ---------------------------------------------------------------------------
SYNC_OPS_TTL = "7 days"


async def purge_expired_sync_ops(db_url: str) -> int:
    """Delete ledger rows older than the TTL via migration 0014's SECURITY
    DEFINER reaper. Same identity note as the other halves: sync_ops is
    FORCE RLS with member-scoped policies, so a direct DELETE from this
    connection would remove zero rows on real Supabase; the definer function
    is the only sanctioned path."""
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    try:
        cur = await conn.execute(
            "SELECT purge_expired_sync_ops(%s::interval)", (SYNC_OPS_TTL,))
        (n,) = await cur.fetchone()
        await conn.commit()
        return n
    except BaseException:
        await conn.rollback()
        raise
    finally:
        await conn.close()


# ---------------------------------------------------------------------------
# Cron entrypoint
# ---------------------------------------------------------------------------
async def run_all(db_url: str, *, storage_delete=None) -> tuple[int, int, int]:
    """What the daily cron invocation actually calls.

    The three halves are attempted independently: an Admin API outage must
    not stop insolvent orgs (and their storage) from being cleared on
    schedule, a storage backend outage must not stop identity purges that
    have nothing to do with organizations at all, and neither must stop the
    sync_ops ledger from aging out on its own 7-day clock. All three are
    attempted regardless of whether another raised, and any failure is
    re-raised only after all three have had their turn -- so cron's own
    failure signal (a non-zero exit code) still fires, but no half can
    silently starve another of runtime.

    `getattr(exc, "purged", 0)` on each catch: `StorageNotConfiguredError`
    and `PartialIdentityPurgeError` both carry `.purged` for exactly this --
    so a half that finished with real work done but is still correctly
    reported as failed does not also lose that count. `purge_expired_sync_ops`
    raises no such subclass (a failed connection or query has nothing partial
    to report), so it falls back to the same `getattr` default of 0 as any
    other half's plain exception. Logged explicitly (not just the traceback)
    and attached to the RuntimeError this raises, so a caller with its own
    monitoring around this job -- not merely watching the exit code -- can
    still recover how much actually happened before the failure. A plain
    exception (a missing env var, a network error before anything ran) has
    no `.purged`, and 0 is the right answer for it.
    """
    failed: list[str] = []
    orgs_purged = 0
    identities_purged = 0
    sync_ops_purged = 0

    try:
        orgs_purged = await run_purge(db_url, storage_delete=storage_delete)
    except Exception as exc:
        orgs_purged = getattr(exc, "purged", 0)
        log.exception("organization purge failed (purged %d before failing)", orgs_purged)
        failed.append("organizations")

    try:
        identities_purged = await purge_pending_identities(db_url)
    except Exception as exc:
        identities_purged = getattr(exc, "purged", 0)
        log.exception("identity purge failed (purged %d before failing)", identities_purged)
        failed.append("identities")

    try:
        sync_ops_purged = await purge_expired_sync_ops(db_url)
    except Exception as exc:
        sync_ops_purged = getattr(exc, "purged", 0)
        log.exception("sync_ops purge failed (purged %d before failing)", sync_ops_purged)
        failed.append("sync_ops")

    if failed:
        exc = RuntimeError(f"purge job failed for: {', '.join(failed)}")
        exc.orgs_purged = orgs_purged
        exc.identities_purged = identities_purged
        exc.sync_ops_purged = sync_ops_purged
        raise exc
    return orgs_purged, identities_purged, sync_ops_purged


if __name__ == "__main__":
    # Review Important-4: deliberately NOT `DATABASE_URL` -- api/main.py
    # reads that for the pooled `app_user` connection the API server uses,
    # which holds none of the EXECUTE grants this job needs on
    # `organizations_pending_purge`, `purge_scheduled_orgs`,
    # `accounts_pending_identity_purge`, or `purge_expired_sync_ops` (all
    # four are granted only to the migration-runner identity). Deployed in
    # one environment where both variables happened to be set to the app
    # server's own value, this job would fail every call with
    # `InsufficientPrivilege`. A distinct name makes that collision
    # structurally impossible instead of a runbook note someone has to
    # remember.
    logging.basicConfig(level=logging.INFO)
    _orgs_purged, _identities_purged, _sync_ops_purged = asyncio.run(
        run_all(os.environ["PURGE_DATABASE_URL"])
    )
    print(
        f"orgs_purged={_orgs_purged} identities_purged={_identities_purged} "
        f"sync_ops_purged={_sync_ops_purged}"
    )
