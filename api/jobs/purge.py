# api/jobs/purge.py
"""Task 12: the scheduled purge job.

Two independent halves, meant to run unattended on a schedule (cron, per the
runbook note carried to Task 14: "api/jobs/purge.py runs daily via cron"):

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

Both halves are independent of each other and of each other's failures: an
org can be purged with accounts still pending identity purge (unrelated
clocks -- DELETE /me carries no grace period), and an identity can be purged
for a user who never owned anything. Neither blocks or is blocked by the
other; see `run_all` at the bottom, which is what the cron invocation
actually calls.
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
async def run_purge(db_url: str, storage_delete=None) -> int:
    """Hard-delete organizations whose grace window has elapsed.

    The candidate set is selected with `... ORDER BY id FOR UPDATE` in the
    SAME transaction that later calls `purge_scheduled_orgs`, and this is
    load-bearing, not decorative:

    * `FOR UPDATE` takes a row lock on exactly the doomed rows that blocks
      `cancel_org_deletion`'s UPDATE (api/routes/deletion.py) against them
      until this transaction ends. Without it, a cancel could commit
      between this SELECT and the storage deletes below, and this job would
      then delete a saved org's files anyway -- the storage-side mirror of
      the row-purge race migration 0007's `purge_scheduled_orgs` already
      guards against with its own advisory lock and re-check.
    * `ORDER BY id` matches every other multi-row locker in this codebase
      (`purge_scheduled_orgs`'s own loop, `_lock_caller_orgs`), so two
      overlapping invocations of this job (a slow run still finishing when
      the next scheduled trigger fires) can never deadlock against each
      other over the doomed set.

    `purge_scheduled_orgs` re-checks the identical predicate itself, inside
    this same transaction and therefore against the same `now()` snapshot
    (Postgres fixes `now()` for the lifetime of a transaction), so the set
    it actually deletes cannot differ from the set storage was just cleared
    for -- the FOR UPDATE lock is what makes that guarantee hold across the
    gap between this SELECT and that call, not just the shared snapshot.

    NOTE on `interval %s`: the brief's own given code writes this as a bind
    parameter (`... - interval %s`, params=(GRACE,)); that is not valid
    Postgres syntax -- `INTERVAL '...'` is a generic type-constant literal
    and does not accept a bind parameter in that position. Confirmed against
    a live Postgres 17 instance before writing this: it raises
    `SyntaxError: syntax error at or near "$1"`. Written here as `%s::interval`
    instead, which casts a normally-bound text parameter.
    """
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    try:
        cur = await conn.execute(
            "SELECT id::text FROM organizations WHERE deletion_scheduled_at IS NOT NULL "
            "AND deletion_scheduled_at < now() - %s::interval ORDER BY id FOR UPDATE",
            (GRACE,),
        )
        doomed = [r[0] for r in await cur.fetchall()]
        if not doomed:
            await conn.rollback()
            return 0

        if storage_delete is not None:
            for org_id in doomed:
                await storage_delete(f"{org_id}/")
        else:
            # Silent here would mean a misconfigured deployment (no
            # storage_delete wired up -- exactly what the brief's own
            # __main__ calls with) orphans every purged org's files forever,
            # with nothing anywhere to notice. Loud instead: the purge still
            # proceeds (see Task 12 report for why this is not blocked
            # outright -- no storage bucket/client exists anywhere in this
            # codebase yet for this job to call), but it cannot happen quietly.
            log.error(
                "storage_delete is not configured; storage objects for %d "
                "organization(s) about to be purged were NOT deleted: %s",
                len(doomed), doomed,
            )

        cur = await conn.execute("SELECT purge_scheduled_orgs(%s::interval)", (GRACE,))
        (purged,) = await cur.fetchone()
        await conn.commit()
        return purged
    except BaseException:
        await conn.rollback()
        raise
    finally:
        await conn.close()


# ---------------------------------------------------------------------------
# Half 2: identities
# ---------------------------------------------------------------------------
class IdentityPurgeError(RuntimeError):
    pass


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
                # rest of an unattended run down with it.
                log.exception(
                    "identity purge failed for %s; left in deleted_accounts for "
                    "the next run", user_id,
                )
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
                continue
            purged += 1
    finally:
        await conn.close()
        if owns_client:
            await http.aclose()
    return purged


# ---------------------------------------------------------------------------
# Cron entrypoint
# ---------------------------------------------------------------------------
async def run_all(db_url: str, *, storage_delete=None) -> tuple[int, int]:
    """What the daily cron invocation actually calls.

    The two halves are attempted independently: an Admin API outage must not
    stop insolvent orgs (and their storage) from being cleared on schedule,
    and a storage backend outage must not stop identity purges that have
    nothing to do with organizations at all. Both are attempted regardless
    of whether the other raised, and any failure is re-raised only after
    both have had their turn -- so cron's own failure signal (a non-zero
    exit code) still fires, but neither half can silently starve the other
    of runtime.
    """
    failed: list[str] = []
    orgs_purged = 0
    identities_purged = 0

    try:
        orgs_purged = await run_purge(db_url, storage_delete=storage_delete)
    except Exception:
        log.exception("organization purge failed")
        failed.append("organizations")

    try:
        identities_purged = await purge_pending_identities(db_url)
    except Exception:
        log.exception("identity purge failed")
        failed.append("identities")

    if failed:
        raise RuntimeError(f"purge job failed for: {', '.join(failed)}")
    return orgs_purged, identities_purged


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    _orgs_purged, _identities_purged = asyncio.run(run_all(os.environ["DATABASE_URL"]))
    print(f"orgs_purged={_orgs_purged} identities_purged={_identities_purged}")
