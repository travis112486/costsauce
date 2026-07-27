# tests/test_purge_job.py
"""Task 12: the scheduled purge job.

Two independent halves:

  run_purge(db_url, storage_delete=None) -> int
      Hard-deletes organizations whose 30-day grace window has elapsed.
      Storage first, so a crash mid-purge leaves the (still scheduled) row
      behind and the job retries, instead of orphaning files whose owning
      org is already gone.

  purge_pending_identities(db_url, ...) -> int
      Finishes what `DELETE /me` cannot: removes the `auth.users` row via
      Supabase's Admin API (service-role key), for every id
      `accounts_pending_identity_purge()` still lists. This is the gap
      Task 11's report closes with a tombstone and hands to this task --
      without it, "delete my account" is a deactivation (the user can still
      mint a JWT and sees an empty account), which fails App Store
      guideline 5.1.1(v).

Both halves are given the standard this codebase already holds itself to for
a third-party wire call (api/services/apple.py, api/services/billing.py):
assert the documented endpoint, method and auth header shape against a fake
transport, not merely that our own code called a mock.
"""
import asyncio
import contextlib
import uuid

import httpx
import psycopg
import pytest

import api.jobs.purge as purge_module
from api.jobs.purge import (
    IdentityPurgeError,
    purge_pending_identities,
    run_all,
    run_purge,
)
from api.routes.deletion import GRACE_DAYS
from api.db import pool_open, tenant_connection
from tests.factories import make_user
from tests.test_auth import mint


# ---------------------------------------------------------------------------
# run_purge -- the org half. The brief's own two given tests, verbatim.
# ---------------------------------------------------------------------------
async def test_purge_job_deletes_storage_prefix_for_each_purged_org(raw_conn, seeded, db_url):
    deleted_prefixes = []

    async def fake_storage_delete(prefix: str):
        deleted_prefixes.append(prefix)

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.commit()
    n = await run_purge(db_url, storage_delete=fake_storage_delete)
    assert n == 1
    assert deleted_prefixes == [f"{seeded['acme']}/"]


async def test_purge_job_is_a_noop_when_nothing_is_due(raw_conn, seeded, db_url, caplog):
    """Review Important-1: also pins the `if not doomed: return 0`
    short-circuit itself. Removing it (mutation M8) still returns 0 here --
    `purge_scheduled_orgs` legitimately finds nothing to delete either way --
    but without the short-circuit, the `storage_delete is None` branch below
    it would fire unconditionally and log an ERROR claiming organizations
    were "about to be purged" when the doomed list is empty. A caplog check
    is what actually distinguishes the short-circuit being there from not.
    """
    with caplog.at_level("ERROR"):
        n = await run_purge(db_url, storage_delete=None)
    assert n == 0
    assert not any("storage" in r.message.lower() for r in caplog.records), (
        "nothing was due, so nothing should have been logged about storage at all"
    )


# ---------------------------------------------------------------------------
# run_purge -- corrections beyond the brief.
# ---------------------------------------------------------------------------
async def test_purge_job_leaves_storage_and_the_org_alive_before_grace_elapses(
    raw_conn, seeded, db_url
):
    """Correction 3: the Python job's own grace check must agree with
    `purge_scheduled_orgs`'s. An org scheduled inside the window must not be
    purged, and -- just as important -- storage must never be touched for it
    either: a false positive here would delete a live org's files while
    leaving the row (and the user) behind.
    """
    called = []

    async def fake_storage_delete(prefix: str):
        called.append(prefix)

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '10 days' "
        "WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.commit()
    n = await run_purge(db_url, storage_delete=fake_storage_delete)
    assert n == 0
    assert called == [], "storage must not be touched inside the grace window"
    cur = await raw_conn.execute(
        "SELECT count(*) FROM organizations WHERE id = %s", (seeded["acme"],)
    )
    assert (await cur.fetchone())[0] == 1


async def test_purge_job_grace_is_the_single_30_day_constant(db_url):
    """Correction 3: 'do not let the Python constant and the SQL argument
    drift'. The value check alone (`GRACE == f"{GRACE_DAYS} days"`) does not
    pin single-sourcing despite this test's name: a hardcoded second literal
    `GRACE = "30 days"` in api/jobs/purge.py satisfies it identically, and
    would silently diverge the day someone changes GRACE_DAYS without
    noticing this module. Checked at the source level instead: GRACE's own
    assignment expression must actually reference the name `GRACE_DAYS`.
    """
    import ast
    import inspect
    import api.jobs.purge as purge_module

    assert GRACE_DAYS == 30
    assert purge_module.GRACE == f"{GRACE_DAYS} days"

    tree = ast.parse(inspect.getsource(purge_module))
    assign = next(
        node for node in ast.walk(tree)
        if isinstance(node, ast.Assign)
        and any(isinstance(t, ast.Name) and t.id == "GRACE" for t in node.targets)
    )
    names_used = {n.id for n in ast.walk(assign.value) if isinstance(n, ast.Name)}
    assert "GRACE_DAYS" in names_used, (
        "GRACE must be derived from GRACE_DAYS in its own source, not merely equal to it"
    )


async def test_purge_job_deletes_storage_before_the_org_row_is_gone(raw_conn, seeded, db_url):
    """Storage-first ordering asserted directly against the database, not
    just against call order in the test's own bookkeeping list: at the
    moment the fake storage_delete callback runs, the org row must still
    exist. If a future edit reordered the two operations, this fails even
    though the given brief test (which only checks the callback fired)
    would still pass.
    """
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.commit()

    still_present_when_called = {}

    async def fake_storage_delete(prefix: str):
        conn = await pool_open(db_url)
        try:
            async with conn.connection() as c:
                cur = await c.execute(
                    "SELECT count(*) FROM organizations WHERE id = %s", (seeded["acme"],)
                )
                still_present_when_called["value"] = (await cur.fetchone())[0]
        finally:
            await conn.close()

    n = await run_purge(db_url, storage_delete=fake_storage_delete)
    assert n == 1
    assert still_present_when_called["value"] == 1, (
        "the org row must still exist while storage is being deleted"
    )


async def test_purge_job_storage_failure_leaves_the_org_for_a_clean_retry(
    raw_conn, seeded, db_url
):
    """Idempotency / partial failure for the org half. A crash (here: the
    storage callback raising) between selecting the doomed org and calling
    `purge_scheduled_orgs` must leave the row exactly as it was -- not
    half-purged, not re-scheduled -- so the very next run, with storage
    fixed, purges it cleanly. No SAVEPOINT trickery needed: run_purge's own
    transaction rolls back whole on any exception.
    """
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.commit()

    async def failing_storage_delete(prefix: str):
        raise RuntimeError("storage backend unavailable")

    with pytest.raises(RuntimeError):
        await run_purge(db_url, storage_delete=failing_storage_delete)

    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at IS NOT NULL FROM organizations WHERE id = %s",
        (seeded["acme"],),
    )
    assert (await cur.fetchone())[0] is True, "a failed run must not half-purge the org"

    deleted_prefixes = []

    async def fake_storage_delete(prefix: str):
        deleted_prefixes.append(prefix)

    n = await run_purge(db_url, storage_delete=fake_storage_delete)
    assert n == 1, "the retry must purge cleanly once storage is fixed"
    assert deleted_prefixes == [f"{seeded['acme']}/"]


async def test_purge_job_raises_and_still_purges_when_storage_delete_is_unconfigured(
    raw_conn, seeded, db_url, caplog
):
    """Review Important-3: storage_delete=None is what __main__ (and
    run_all's own default) calls with today, since no storage bucket/client
    exists anywhere in this codebase yet. The first version of this fix only
    logged an ERROR and returned success -- combined with Important-2's
    finding, a run that purged real rows and orphaned every one of their
    storage prefixes was indistinguishable, by return value or exit code,
    from a completely healthy no-op night. The org row still gets purged
    (it is not held hostage to a bucket that doesn't exist), but the run as
    a whole must now be reported as failed.
    """
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.commit()
    with caplog.at_level("ERROR"):
        with pytest.raises(purge_module.StorageNotConfiguredError) as exc_info:
            await run_purge(db_url, storage_delete=None)
    assert exc_info.value.purged == 1
    cur = await raw_conn.execute("SELECT count(*) FROM organizations WHERE id = %s",
                                  (seeded["acme"],))
    assert (await cur.fetchone())[0] == 0, (
        "the org row is still actually purged despite the run being reported as failed"
    )
    assert any("storage" in r.message.lower() for r in caplog.records), (
        "an unconfigured storage_delete on a real purge must be logged loudly"
    )


# Seconds of grace still left on the org when the cancel request begins. The
# window elapses while that request is still in flight, which is what puts the
# real cancel endpoint and the real purge job on the same org at the same time
# -- see the test below.
_BOUNDARY_SLACK_SECONDS = 2


@pytest.mark.parametrize(
    "settle_seconds",
    [0.3, 1.5],
    ids=["under-deadlock_timeout", "past-deadlock_timeout"],
)
async def test_the_real_cancel_endpoint_racing_the_real_purge_job_never_deadlocks(
    app_client, raw_conn, seeded, db_url, settle_seconds
):
    """`DELETE /orgs/{id}/deletion` (the real route, over HTTP) against
    `run_purge` (the real job). Both shipping paths, no reconstruction.

    Final-review Important-1 and Important-2, in one test.

    The version of this test that shipped before drove a bare `UPDATE
    organizations SET deletion_scheduled_at = NULL` on a tenant connection,
    WITHOUT `members._lock_org`, which the real `cancel_org_deletion` always
    calls first (api/routes/deletion.py). Its sibling in
    tests/test_deletion.py called a local `_purge()` that ran only
    `purge_scheduled_orgs`, skipping `organizations_pending_purge` and
    therefore the `FOR UPDATE`. Each replica dropped exactly the one lock
    that made a lock-order inversion between the two paths disappear:

        purge   organizations_pending_purge   row lock (FOR UPDATE)
             -> purge_scheduled_orgs          advisory lock
        cancel  members._lock_org             advisory lock
             -> UPDATE organizations          row lock

    Opposite order, same two locks. Reproduced against Postgres 17 with the
    real migrations in BOTH victim directions -- which is why this is
    parametrised on how long the two are left contending:

      * `under-deadlock_timeout` -- the purge starts waiting on the advisory
        lock less than `deadlock_timeout` (1s) after the cancel started
        waiting on the row lock, so the CANCEL's detector fires first and the
        cancel is the victim: an uncaught `psycopg.Error` out of the route,
        i.e. HTTP 500 on a legitimate cancel.
      * `past-deadlock_timeout` -- the realistic case for a bucket-prefix
        delete. The cancel's detector fires while the purge is still inside
        `storage_delete`, finds no cycle, and Postgres does not re-arm it; so
        when the purge finally waits, the PURGE is the victim -- after it has
        already deleted the storage of an org the cancel then goes on to
        save. Irreversible data loss the day a bucket exists.

    Getting both real paths onto the same org at once needs one thing the
    naive interleaving does not have. `cancel_org_deletion` refuses (410) once
    the grace window has elapsed, and the purge only takes orgs whose window
    HAS elapsed -- so the two overlap only while a cancel that began inside
    the window is still in flight when the window closes. `now()` is fixed for
    the lifetime of a transaction, so that is a real, reachable state, not a
    contrivance: the org here has `_BOUNDARY_SLACK_SECONDS` of grace left when
    the cancel's transaction starts, and the cancel then waits on the org lock
    (held here by `members._lock_org` itself, exactly as a concurrent invite,
    role change or `DELETE /me` would hold it) while the window elapses
    underneath it.

    With the lock order fixed, this is deliberately NOT a test for one
    outcome: once both parties agree on advisory-then-row, whichever acquires
    the org lock first wins, and both winners are correct. What must hold is
    that the two answers are CONSISTENT -- an org that survives must still
    have its storage, and an org that is gone must have had its storage
    deleted -- and that neither party is ever aborted by the deadlock
    detector.
    """
    from api.routes import members as members_module

    # Due for purge in `_BOUNDARY_SLACK_SECONDS`, not yet.
    await raw_conn.execute(
        "UPDATE organizations "
        "   SET deletion_scheduled_at = now() - %s::interval + %s::interval "
        " WHERE id = %s",
        (f"{GRACE_DAYS} days", f"{_BOUNDARY_SLACK_SECONDS} seconds", seeded["acme"]),
    )
    await raw_conn.commit()

    entered_storage_delete = asyncio.Event()
    release_storage_delete = asyncio.Event()
    deleted_prefixes = []

    async def blocking_storage_delete(prefix: str):
        deleted_prefixes.append(prefix)
        entered_storage_delete.set()
        await release_storage_delete.wait()

    lock_pool = await pool_open(db_url.replace("postgres:postgres", "app_user:app_pw"))
    holder_locked = asyncio.Event()
    holder_release = asyncio.Event()

    async def hold_the_org_lock():
        """Stand in for any other org operation already holding the lock.

        Uses `members._lock_org` -- the same function, on a real tenant
        connection -- rather than re-deriving `hashtextextended(...)` here,
        so this cannot drift from the four call sites that must agree on it.
        """
        async with tenant_connection(lock_pool, {"sub": str(seeded["alice"])}) as conn:
            await members_module._lock_org(conn, seeded["acme"])
            holder_locked.set()
            await holder_release.wait()

    try:
        holder_task = asyncio.create_task(hold_the_org_lock())
        await asyncio.wait_for(holder_locked.wait(), timeout=5)

        # The cancel's transaction (and therefore its `now()`, and therefore
        # its grace-window verdict) is fixed HERE, while the org is still
        # inside the window. It then blocks in `_lock_org`.
        cancel_task = asyncio.create_task(
            app_client.delete(
                f"/orgs/{seeded['acme']}/deletion",
                headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
            )
        )
        await asyncio.sleep(0.3)
        assert not cancel_task.done(), "the cancel must block on the held org lock"

        # Let the window elapse, then start the purge -- which now sees the
        # same org as due, on its own later `now()`.
        await asyncio.sleep(_BOUNDARY_SLACK_SECONDS + 0.5)
        purge_task = asyncio.create_task(
            run_purge(db_url, storage_delete=blocking_storage_delete)
        )
        # Pre-fix the purge takes the row lock immediately and lands in
        # storage_delete; post-fix it queues behind the advisory lock and
        # never gets here until the holder lets go. Both are expected, so this
        # wait is best-effort rather than an assertion.
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(entered_storage_delete.wait(), timeout=1.0)

        holder_release.set()
        await asyncio.wait_for(holder_task, timeout=5)

        # Both parties are now contending. `settle_seconds` is how long they
        # are left to do it, which is what selected the victim pre-fix.
        await asyncio.sleep(settle_seconds)
        release_storage_delete.set()

        purged = await asyncio.wait_for(purge_task, timeout=20)
        cancel_response = await asyncio.wait_for(cancel_task, timeout=20)
    finally:
        holder_release.set()
        release_storage_delete.set()
        await lock_pool.close()

    assert cancel_response.status_code != 500, (
        "the cancel must never be aborted by the deadlock detector; got "
        f"{cancel_response.status_code} {cancel_response.text!r}"
    )

    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at IS NULL FROM organizations WHERE id = %s",
        (seeded["acme"],),
    )
    row = await cur.fetchone()

    if cancel_response.status_code == 200:
        # The cancel won the org lock. The org is saved -- and its storage
        # must be untouched, which is the whole point of taking the lock
        # before deleting anything.
        assert purged == 0, "an org the cancel saved must not have been purged"
        assert deleted_prefixes == [], (
            "the purge deleted the storage of an org that was then saved -- this "
            "is the irreversible half of the lock-order inversion"
        )
        assert row is not None and row[0] is True, (
            "a 200 cancel must leave the org present and unscheduled"
        )
    else:
        # The purge won. The org is really gone and its storage really went
        # with it; the cancel loses cleanly with a 404, not a deadlock.
        assert cancel_response.status_code == 404, (
            f"unexpected cancel outcome: {cancel_response.status_code} "
            f"{cancel_response.text!r}"
        )
        assert purged == 1
        assert deleted_prefixes == [f"{seeded['acme']}/"]
        assert row is None, "the org must actually be gone, not silently no-op'd"


async def test_run_purge_works_for_a_restricted_migration_runner_role(raw_conn, seeded, db_url):
    """Review Important-1 (the headline finding): the previous version of
    this test called `organizations_pending_purge` directly, over the same
    superuser connection every other test in this file shares, and never
    invoked `run_purge` at all. That pinned the migration, not the shipping
    job -- confirmed by restoring this task's original broken first draft
    (the raw `SELECT ... FROM organizations ... FOR UPDATE` in
    api/jobs/purge.py) and watching the previous version of this test still
    pass alongside the rest of the file (21/21).

    This drives `run_purge` itself, over a connection whose role is
    `NOSUPERUSER NOBYPASSRLS NOINHERIT` -- standing in for the real,
    restricted migration-runner identity Task 14 will deploy this job under
    -- holding ONLY the three `EXECUTE` grants a deployed job actually needs
    (`organizations_pending_purge`, `purge_scheduled_orgs`,
    `accounts_pending_identity_purge`) and nothing else on `organizations`
    directly. A raw `SELECT` against `organizations` is proven to fail for
    this same role first, so the contrast is real: if `run_purge` ever
    regresses to reading the table directly, this fails with
    `InsufficientPrivilege` the way it actually would in production, instead
    of silently passing because the test's own connection happens to be a
    superuser.
    """
    deleted_prefixes = []

    async def fake_storage_delete(prefix: str):
        deleted_prefixes.append(prefix)

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.execute(
        "CREATE ROLE test_purge_job_runner LOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT "
        "PASSWORD 'x'"
    )
    # Schema USAGE only -- a real migration runner obviously has this (it
    # created every object in the schema). No table-level grant of any kind
    # on `organizations` itself; only the three EXECUTE grants a deployed
    # job needs.
    await raw_conn.execute("GRANT USAGE ON SCHEMA public TO test_purge_job_runner")
    await raw_conn.execute(
        "GRANT EXECUTE ON FUNCTION organizations_pending_purge(interval) "
        "TO test_purge_job_runner"
    )
    await raw_conn.execute(
        "GRANT EXECUTE ON FUNCTION purge_scheduled_orgs(interval) TO test_purge_job_runner"
    )
    await raw_conn.execute(
        "GRANT EXECUTE ON FUNCTION accounts_pending_identity_purge() TO test_purge_job_runner"
    )
    await raw_conn.commit()

    restricted_url = db_url.replace("postgres:postgres", "test_purge_job_runner:x")
    try:
        probe = await psycopg.AsyncConnection.connect(restricted_url, autocommit=True)
        try:
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                await probe.execute("SELECT id FROM organizations")
        finally:
            await probe.close()

        n = await run_purge(restricted_url, storage_delete=fake_storage_delete)
        assert n == 1
        assert deleted_prefixes == [f"{seeded['acme']}/"]

        cur = await raw_conn.execute(
            "SELECT count(*) FROM organizations WHERE id = %s", (seeded["acme"],)
        )
        assert (await cur.fetchone())[0] == 0, "run_purge must have actually purged the org"
    finally:
        await raw_conn.execute(
            "REVOKE EXECUTE ON FUNCTION organizations_pending_purge(interval) "
            "FROM test_purge_job_runner"
        )
        await raw_conn.execute(
            "REVOKE EXECUTE ON FUNCTION purge_scheduled_orgs(interval) "
            "FROM test_purge_job_runner"
        )
        await raw_conn.execute(
            "REVOKE EXECUTE ON FUNCTION accounts_pending_identity_purge() "
            "FROM test_purge_job_runner"
        )
        await raw_conn.execute("REVOKE USAGE ON SCHEMA public FROM test_purge_job_runner")
        await raw_conn.execute("DROP ROLE test_purge_job_runner")
        await raw_conn.commit()


# ---------------------------------------------------------------------------
# purge_pending_identities -- the identity half.
# ---------------------------------------------------------------------------
async def _tombstone(raw_conn, user_id) -> int:
    cur = await raw_conn.execute(
        "SELECT count(*) FROM deleted_accounts WHERE user_id = %s", (user_id,)
    )
    return (await cur.fetchone())[0]


async def test_purge_pending_identities_calls_the_documented_admin_api_endpoint(
    raw_conn, seeded, db_url
):
    """Wire-contract test, matching api/services/apple.py's standard: the
    real DELETE method, the real documented path
    (`/auth/v1/admin/users/{id}`), and the real service-role auth header
    shape -- not merely that our own code invoked a mock.

    The fake handler also performs the delete it is standing in for
    (`DELETE FROM auth.users ... `, committed) so that the tombstone's own
    `ON DELETE CASCADE` actually fires, exactly as it would against real
    Supabase. That is what lets this test assert the job clears the
    tombstone only through a REAL confirmed removal, not through the job
    trusting its own HTTP call blindly.
    """
    carol = await make_user(raw_conn, "carol@acme-diner.example.com")
    await raw_conn.execute("DELETE FROM profiles WHERE user_id = %s", (carol,))
    await raw_conn.execute("INSERT INTO deleted_accounts (user_id) VALUES (%s)", (carol,))
    await raw_conn.commit()
    assert await _tombstone(raw_conn, carol) == 1

    seen = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        seen["method"] = request.method
        seen["url"] = str(request.url)
        seen["apikey"] = request.headers.get("apikey")
        seen["authorization"] = request.headers.get("authorization")
        await raw_conn.execute("DELETE FROM auth.users WHERE id = %s", (carol,))
        await raw_conn.commit()
        return httpx.Response(200, json={"id": str(carol)})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        n = await purge_pending_identities(
            db_url,
            supabase_url="https://x.supabase.co",
            service_role_key="sr-key-abc",
            http=client,
        )

    assert n == 1
    assert seen["method"] == "DELETE"
    assert seen["url"] == f"https://x.supabase.co/auth/v1/admin/users/{carol}"
    assert seen["apikey"] == "sr-key-abc"
    assert seen["authorization"] == "Bearer sr-key-abc"
    assert await _tombstone(raw_conn, carol) == 0


async def test_purge_pending_identities_never_selects_deleted_accounts_directly(raw_conn, seeded):
    """`deleted_accounts` is FORCE RLS with no SELECT policy at all for the
    migration runner -- only `accounts_pending_identity_purge()` (SECURITY
    DEFINER, owned by `purge_definer`) can read it. This codebase's own test
    harness connects as a real Postgres superuser, which bypasses RLS
    regardless of the accessor -- so a runtime test cannot tell a raw
    `SELECT ... FROM deleted_accounts` apart from the accessor here (both
    would return real rows locally, even though only the accessor works
    once deployed against a non-superuser Supabase migration role).

    Static guard on the actual shipping SQL instead of the runtime result:
    walk the module's AST for every string literal passed to a `.execute(`
    call (i.e. every query this module can possibly issue -- prose in
    docstrings/comments is not parsed as a call argument at all, so it can't
    produce a false positive the way a plain substring search over the
    whole source would) and assert none of them name the table.
    """
    import ast
    import inspect
    import api.jobs.purge as purge_module

    tree = ast.parse(inspect.getsource(purge_module))
    queries = [
        node.args[0].value
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "execute"
        and node.args
        and isinstance(node.args[0], ast.Constant)
        and isinstance(node.args[0].value, str)
    ]
    assert queries, "expected to find at least one .execute(...) call to check"
    assert not any("deleted_accounts" in q for q in queries), (
        f"a query references deleted_accounts directly: {queries}"
    )


async def test_purge_pending_identities_treats_a_race_with_another_run_as_success(
    raw_conn, seeded, db_url
):
    """A 404 from the Admin API for a user id this job's own SELECT just
    listed can only mean another purge run already finished it in between
    (deleted_accounts.user_id's FK guarantees the row referenced a real,
    still-existing auth.users row at tombstone-write time, and the CASCADE
    that clears it is atomic with the auth.users delete -- so there is no
    window where the identity is gone but the tombstone survives, other
    than exactly this race). Simulated directly: pre-remove the identity
    behind the job's back, then have the fake Admin API 404.
    """
    dave = await make_user(raw_conn, "dave@acme-diner.example.com")
    await raw_conn.execute("DELETE FROM profiles WHERE user_id = %s", (dave,))
    await raw_conn.execute("INSERT INTO deleted_accounts (user_id) VALUES (%s)", (dave,))
    await raw_conn.commit()

    async def handler(request: httpx.Request) -> httpx.Response:
        # Simulate: another run already deleted this identity for real.
        await raw_conn.execute("DELETE FROM auth.users WHERE id = %s", (dave,))
        await raw_conn.commit()
        return httpx.Response(404, json={"message": "User not found"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        n = await purge_pending_identities(
            db_url, supabase_url="https://x.supabase.co", service_role_key="k", http=client,
        )
    assert n == 1
    assert await _tombstone(raw_conn, dave) == 0


async def test_purge_pending_identities_does_not_abort_when_one_identity_fails(
    raw_conn, seeded, db_url
):
    """One bad identity must not stop the REST of an unattended run --
    otherwise a single persistently-failing account (or just one bad HTTP
    response) would silently block every other deletion behind it forever.
    That is still true: the loop below processes `bad` and `good` regardless
    of order. But review Important-2: the run as a WHOLE must not then
    report success -- `purge_pending_identities` now raises
    `PartialIdentityPurgeError` (carrying the split) once every pending id
    has been attempted, rather than silently returning a lower count.
    """
    good = await make_user(raw_conn, "good@acme-diner.example.com")
    bad = await make_user(raw_conn, "bad@acme-diner.example.com")
    for uid in (good, bad):
        await raw_conn.execute("DELETE FROM profiles WHERE user_id = %s", (uid,))
        await raw_conn.execute("INSERT INTO deleted_accounts (user_id) VALUES (%s)", (uid,))
    await raw_conn.commit()

    async def handler(request: httpx.Request) -> httpx.Response:
        target = request.url.path.rsplit("/", 1)[1]
        if target == str(bad):
            return httpx.Response(500, text="internal error")
        await raw_conn.execute("DELETE FROM auth.users WHERE id = %s", (good,))
        await raw_conn.commit()
        return httpx.Response(200, json={"id": str(good)})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(purge_module.PartialIdentityPurgeError) as exc_info:
            await purge_pending_identities(
                db_url, supabase_url="https://x.supabase.co", service_role_key="k", http=client,
            )

    assert exc_info.value.purged == 1, "the good identity must still be purged"
    assert exc_info.value.failed == 1
    assert await _tombstone(raw_conn, good) == 0
    assert await _tombstone(raw_conn, bad) == 1, "the failed one must survive for a retry"


async def test_purge_pending_identities_does_not_clear_a_tombstone_that_lied_about_success(
    raw_conn, seeded, db_url
):
    """The self-review question this exists to answer: can the job clear a
    tombstone for an identity that still exists? Simulated with an Admin
    API that returns 200 without actually removing the row -- a
    misbehaving or misconfigured endpoint. The job must not trust the
    status code alone; it must not count this as purged, the tombstone must
    survive for the next run to catch, and (review Important-2) the run
    must be reported as failed rather than a quiet `0`.
    """
    erin = await make_user(raw_conn, "erin@acme-diner.example.com")
    await raw_conn.execute("DELETE FROM profiles WHERE user_id = %s", (erin,))
    await raw_conn.execute("INSERT INTO deleted_accounts (user_id) VALUES (%s)", (erin,))
    await raw_conn.commit()

    async def lying_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"id": str(erin)})  # never actually deletes anything

    async with httpx.AsyncClient(transport=httpx.MockTransport(lying_handler)) as client:
        with pytest.raises(purge_module.PartialIdentityPurgeError) as exc_info:
            await purge_pending_identities(
                db_url, supabase_url="https://x.supabase.co", service_role_key="k", http=client,
            )

    assert exc_info.value.purged == 0, "a 200 that did not actually remove the identity must not count as purged"
    assert exc_info.value.failed == 1
    assert await _tombstone(raw_conn, erin) == 1, "the tombstone must survive for a retry"


async def test_run_all_is_non_zero_when_every_pending_identity_fails(raw_conn, seeded, db_url):
    """Review Important-2's exact reproduction: with the Admin API returning
    500 for every one of three pending identities, the previous version of
    this job had `purge_pending_identities` return `0` and raise nothing,
    `run_all` return `(0, 0)`, and `__main__` exit 0 -- a permanently broken
    Supabase credential or a total Admin API outage was indistinguishable
    from an idle night with nothing pending, for the exact half of this job
    that exists to satisfy App Store 5.1.1(v). Driven through `run_all`
    itself (not just `purge_pending_identities` in isolation), with the org
    half a no-op, so the ONLY thing that can make this fail is the identity
    half's own accounting.
    """
    ids = [
        await make_user(raw_conn, f"allfail{i}@acme-diner.example.com") for i in range(3)
    ]
    for uid in ids:
        await raw_conn.execute("DELETE FROM profiles WHERE user_id = %s", (uid,))
        await raw_conn.execute("INSERT INTO deleted_accounts (user_id) VALUES (%s)", (uid,))
    await raw_conn.commit()

    async def always_500(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="Supabase Admin API unreachable")

    async def fake_orgs(db_url, storage_delete=None):
        return 0

    async def fake_sync_ops(db_url):
        return 0

    async def real_identities_with_failing_transport(db_url, **kwargs):
        async with httpx.AsyncClient(transport=httpx.MockTransport(always_500)) as client:
            return await purge_pending_identities(
                db_url, supabase_url="https://x.supabase.co", service_role_key="k",
                http=client,
            )

    import unittest.mock
    with unittest.mock.patch.object(purge_module, "run_purge", fake_orgs), \
         unittest.mock.patch.object(purge_module, "purge_expired_sync_ops", fake_sync_ops), \
         unittest.mock.patch.object(
             purge_module, "purge_pending_identities", real_identities_with_failing_transport
         ):
        with pytest.raises(RuntimeError, match="identities") as exc_info:
            await run_all(db_url)

    assert exc_info.value.orgs_purged == 0
    assert exc_info.value.identities_purged == 0, (
        "all three failed, so zero identities were actually purged this run"
    )
    for uid in ids:
        assert await _tombstone(raw_conn, uid) == 1, "every failed identity must survive for a retry"


async def test_purge_pending_identities_requires_supabase_credentials(db_url, seeded):
    """Judgement call mirroring api/services/billing.py's missing-API-key
    path: a misconfigured deployment must raise loudly rather than silently
    doing nothing, and must not attempt any network call while unconfigured.
    """
    called = {"value": False}

    async def handler(request: httpx.Request) -> httpx.Response:
        called["value"] = True
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(RuntimeError):
            await purge_pending_identities(
                db_url, supabase_url=None, service_role_key=None, http=client,
            )
    assert called["value"] is False


async def test_purge_pending_identities_never_logs_the_service_role_key(
    raw_conn, seeded, db_url, caplog
):
    """The service-role key must never end up in logs, including on the
    failure path where it would be tempting to dump request context for
    debugging."""
    flynn = await make_user(raw_conn, "flynn@acme-diner.example.com")
    await raw_conn.execute("DELETE FROM profiles WHERE user_id = %s", (flynn,))
    await raw_conn.execute("INSERT INTO deleted_accounts (user_id) VALUES (%s)", (flynn,))
    await raw_conn.commit()
    secret = "sr-super-secret-do-not-log-8675309"

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="boom")

    with caplog.at_level("DEBUG"):
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            with pytest.raises(purge_module.PartialIdentityPurgeError):
                await purge_pending_identities(
                    db_url, supabase_url="https://x.supabase.co", service_role_key=secret,
                    http=client,
                )
    assert secret not in caplog.text


async def test_purge_pending_identities_is_a_noop_when_nothing_is_pending(db_url, seeded):
    called = {"value": False}

    async def handler(request: httpx.Request) -> httpx.Response:
        called["value"] = True
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        n = await purge_pending_identities(
            db_url, supabase_url="https://x.supabase.co", service_role_key="k", http=client,
        )
    assert n == 0
    assert called["value"] is False


async def test_delete_identity_raises_the_documented_error_on_an_unhandled_status():
    """`_delete_identity` is the unit purge_pending_identities' per-user loop
    wraps in its own try/except; asserted directly so the exception type the
    outer loop is catching is proven, not assumed."""
    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(403, text="forbidden")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(IdentityPurgeError):
            await purge_module._delete_identity(
                "019fa079-9012-7def-9cd0-3d749170b8d6",
                supabase_url="https://x.supabase.co",
                service_role_key="k",
                http=client,
            )


# ---------------------------------------------------------------------------
# purge_expired_sync_ops -- the sync_ops half (Task 10). The ledger holds
# 7 days of applied op results (§5.3); this reaps rows past the TTL via
# migration 0014's `purge_expired_sync_ops(interval)` SECURITY DEFINER
# reaper. sync_ops does not exist until migration 0014, so this half needs
# `seeded_biz` (all migrations), not the org/identity halves' `seeded`
# (pinned to upto=9 -- see that fixture's own comment).
# ---------------------------------------------------------------------------
async def test_purge_expired_sync_ops_deletes_backdated_rows_and_keeps_fresh_ones(
    raw_conn, seeded_biz, db_url
):
    s = seeded_biz
    old_op = uuid.uuid4()
    fresh_op = uuid.uuid4()
    await raw_conn.execute(
        "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
        " VALUES (%s, %s, uuid_generate_v7(), '{}')",
        (old_op, s["acme"]),
    )
    await raw_conn.execute(
        "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
        " VALUES (%s, %s, uuid_generate_v7(), '{}')",
        (fresh_op, s["acme"]),
    )
    await raw_conn.execute(
        "UPDATE sync_ops SET applied_at = now() - interval '8 days' WHERE op_id = %s",
        (old_op,),
    )
    await raw_conn.commit()

    n = await purge_module.purge_expired_sync_ops(db_url)
    assert n == 1

    cur = await raw_conn.execute("SELECT op_id FROM sync_ops")
    remaining = {r[0] for r in await cur.fetchall()}
    assert remaining == {fresh_op}, "the fresh row must survive; only the backdated one is reaped"


# ---------------------------------------------------------------------------
# run_all -- the cron entrypoint. Not in the brief's interface list, but it
# is what api/jobs/purge.py's __main__ block actually calls, so it ships and
# is tested like anything else that ships.
# ---------------------------------------------------------------------------
async def test_run_all_runs_the_identity_half_even_when_the_org_half_fails(
    monkeypatch, db_url, seeded
):
    async def boom(db_url, storage_delete=None):
        raise RuntimeError("organizations backend unreachable")

    identity_called = {"value": False}

    async def fake_identities(db_url, **kwargs):
        identity_called["value"] = True
        return 0

    async def fake_sync_ops(db_url):
        return 0

    monkeypatch.setattr(purge_module, "run_purge", boom)
    monkeypatch.setattr(purge_module, "purge_pending_identities", fake_identities)
    monkeypatch.setattr(purge_module, "purge_expired_sync_ops", fake_sync_ops)

    with pytest.raises(RuntimeError, match="organizations"):
        await run_all(db_url)

    assert identity_called["value"] is True, (
        "an org-purge failure must not prevent the identity half from running"
    )


async def test_run_all_runs_the_org_half_even_when_the_identity_half_fails(
    monkeypatch, db_url, seeded
):
    org_called = {"value": False}

    async def fake_orgs(db_url, storage_delete=None):
        org_called["value"] = True
        return 3

    async def boom(db_url, **kwargs):
        raise RuntimeError("Supabase Admin API unreachable")

    async def fake_sync_ops(db_url):
        return 0

    monkeypatch.setattr(purge_module, "run_purge", fake_orgs)
    monkeypatch.setattr(purge_module, "purge_pending_identities", boom)
    monkeypatch.setattr(purge_module, "purge_expired_sync_ops", fake_sync_ops)

    with pytest.raises(RuntimeError, match="identities"):
        await run_all(db_url)

    assert org_called["value"] is True, (
        "an identity-purge failure must not prevent the org half from running"
    )


async def test_run_all_runs_the_other_halves_even_when_the_sync_ops_half_fails(
    monkeypatch, db_url, seeded
):
    """Task 10's own failure-independence pin, mirroring the two tests above:
    an unreachable ledger reaper must not stop insolvent orgs or pending
    identities from being cleared on schedule, and the run must still be
    reported as failed with "sync_ops" identifying which half broke.
    """
    org_called = {"value": False}
    identity_called = {"value": False}

    async def fake_orgs(db_url, storage_delete=None):
        org_called["value"] = True
        return 1

    async def fake_identities(db_url, **kwargs):
        identity_called["value"] = True
        return 2

    async def boom(db_url):
        raise RuntimeError("sync_ops database unreachable")

    monkeypatch.setattr(purge_module, "run_purge", fake_orgs)
    monkeypatch.setattr(purge_module, "purge_pending_identities", fake_identities)
    monkeypatch.setattr(purge_module, "purge_expired_sync_ops", boom)

    with pytest.raises(RuntimeError, match="sync_ops"):
        await run_all(db_url)

    assert org_called["value"] is True, (
        "a sync_ops-purge failure must not prevent the org half from running"
    )
    assert identity_called["value"] is True, (
        "a sync_ops-purge failure must not prevent the identity half from running"
    )


async def test_run_all_returns_three_counts_when_all_halves_succeed(monkeypatch, db_url, seeded):
    async def fake_orgs(db_url, storage_delete=None):
        return 2

    async def fake_identities(db_url, **kwargs):
        return 5

    async def fake_sync_ops(db_url):
        return 7

    monkeypatch.setattr(purge_module, "run_purge", fake_orgs)
    monkeypatch.setattr(purge_module, "purge_pending_identities", fake_identities)
    monkeypatch.setattr(purge_module, "purge_expired_sync_ops", fake_sync_ops)

    result = await run_all(db_url)
    assert result == (2, 5, 7)
