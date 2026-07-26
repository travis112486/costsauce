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


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


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


async def test_purge_job_is_a_noop_when_nothing_is_due(raw_conn, seeded, db_url):
    n = await run_purge(db_url, storage_delete=None)
    assert n == 0


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
    drift'. Pinned by deriving api.jobs.purge.GRACE from
    api.routes.deletion.GRACE_DAYS directly, rather than a second literal
    '30' living in this module -- so a change to the one place the grace
    period is actually a product decision (deletion.py's docstring says so)
    automatically propagates here instead of silently diverging.
    """
    import api.jobs.purge as purge_module

    assert GRACE_DAYS == 30
    assert purge_module.GRACE == f"{GRACE_DAYS} days"


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


async def test_purge_job_logs_and_still_purges_when_storage_delete_is_unconfigured(
    raw_conn, seeded, db_url, caplog
):
    """storage_delete=None is what the brief's own __main__ entrypoint calls
    with. Silently skipping storage cleanup for a real purge (not the given
    no-op test's empty case) must not pass unnoticed -- an operator reading
    logs needs to see that files were left behind.
    """
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.commit()
    with caplog.at_level("ERROR"):
        n = await run_purge(db_url, storage_delete=None)
    assert n == 1
    assert any("storage" in r.message.lower() for r in caplog.records), (
        "an unconfigured storage_delete on a real purge must be logged loudly"
    )


async def test_purge_job_does_not_purge_an_org_a_racing_cancel_saves(raw_conn, seeded, db_url):
    """The FOR UPDATE row lock this job takes on the doomed set must block a
    concurrent cancel-style UPDATE (api/routes/deletion.py's
    cancel_org_deletion) for the whole duration of the run, so a cancel that
    starts while storage is being deleted cannot commit until after this
    job has already committed its own decision. Proven by forcing the
    interleaving, not by hoping for it: the cancel is only released once
    run_purge is done, and it must then see the org gone (matching
    `purge_scheduled_orgs`'s own re-check), i.e. it loses the race cleanly.
    """
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.commit()

    entered_storage_delete = asyncio.Event()
    release_storage_delete = asyncio.Event()

    async def blocking_storage_delete(prefix: str):
        entered_storage_delete.set()
        await release_storage_delete.wait()

    purge_task = asyncio.create_task(run_purge(db_url, storage_delete=blocking_storage_delete))
    await asyncio.wait_for(entered_storage_delete.wait(), timeout=5)

    cancel_conn = await pool_open(app_url(db_url))
    try:
        async def try_cancel():
            async with tenant_connection(cancel_conn, {"sub": str(seeded["alice"])}) as conn:
                await conn.execute(
                    "UPDATE organizations SET deletion_scheduled_at = NULL "
                    "WHERE id = %s AND deletion_scheduled_at IS NOT NULL",
                    (seeded["acme"],),
                )

        cancel_task = asyncio.create_task(try_cancel())
        await asyncio.sleep(0.3)
        assert not cancel_task.done(), "the cancel must block behind run_purge's row lock"

        release_storage_delete.set()
        purged = await purge_task
        assert purged == 1

        await asyncio.wait_for(cancel_task, timeout=5)
    finally:
        await cancel_conn.close()

    cur = await raw_conn.execute("SELECT count(*) FROM organizations WHERE id = %s",
                                  (seeded["acme"],))
    assert (await cur.fetchone())[0] == 0, (
        "the org must actually be gone -- the cancel lost the race, not silently no-op'd"
    )


async def test_organizations_pending_purge_works_for_a_caller_with_no_privilege_on_organizations(
    raw_conn, seeded, db_url
):
    """Pins the exact defect this task's own first draft shipped and this
    file's other tests cannot rule out: `db_url` connects as a genuine
    Postgres superuser, which bypasses `organizations`' FORCE ROW LEVEL
    SECURITY regardless of grants -- so a raw `SELECT ... FOR UPDATE`
    against it "worked" in every other test here even when it would return
    zero rows (silently) or fail outright (loudly) for the actual
    non-superuser role a real Supabase migration runner is. This creates a
    deliberately unprivileged role, grants it EXECUTE on
    `organizations_pending_purge` ONLY, and proves: a raw SELECT still fails
    for that role, while the accessor still returns the real row and takes
    a real lock -- so the SECURITY DEFINER elevation this migration relies
    on does not depend on the caller happening to be a superuser.
    """
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.execute(
        "CREATE ROLE test_no_privilege_caller LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD 'x'"
    )
    # Schema USAGE only -- a real migration runner obviously has this (it
    # created every object in the schema). No table-level grant on
    # `organizations` itself, which is the one privilege this test is
    # actually about.
    await raw_conn.execute("GRANT USAGE ON SCHEMA public TO test_no_privilege_caller")
    await raw_conn.execute(
        "GRANT EXECUTE ON FUNCTION organizations_pending_purge(interval) "
        "TO test_no_privilege_caller"
    )
    await raw_conn.commit()

    caller_url = db_url.replace("postgres:postgres", "test_no_privilege_caller:x")
    try:
        conn = await psycopg.AsyncConnection.connect(caller_url, autocommit=True)
        try:
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                await conn.execute("SELECT id FROM organizations")

            cur = await conn.execute(
                "SELECT id FROM organizations_pending_purge(interval '30 days')"
            )
            assert await cur.fetchall() == [(seeded["acme"],)]
        finally:
            await conn.close()
    finally:
        await raw_conn.execute(
            "REVOKE EXECUTE ON FUNCTION organizations_pending_purge(interval) "
            "FROM test_no_privilege_caller"
        )
        await raw_conn.execute("REVOKE USAGE ON SCHEMA public FROM test_no_privilege_caller")
        await raw_conn.execute("DROP ROLE test_no_privilege_caller")
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
            supabase_url="https://khohfrfqzbieaiikqlsa.supabase.co",
            service_role_key="sr-key-abc",
            http=client,
        )

    assert n == 1
    assert seen["method"] == "DELETE"
    assert seen["url"] == f"https://khohfrfqzbieaiikqlsa.supabase.co/auth/v1/admin/users/{carol}"
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
    """One bad identity must not stop the rest of an unattended run --
    otherwise a single persistently-failing account (or just one bad HTTP
    response) would silently block every other deletion behind it forever.
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
        n = await purge_pending_identities(
            db_url, supabase_url="https://x.supabase.co", service_role_key="k", http=client,
        )

    assert n == 1, "the good identity must still be purged despite the bad one failing"
    assert await _tombstone(raw_conn, good) == 0
    assert await _tombstone(raw_conn, bad) == 1, "the failed one must survive for a retry"


async def test_purge_pending_identities_does_not_clear_a_tombstone_that_lied_about_success(
    raw_conn, seeded, db_url
):
    """The self-review question this exists to answer: can the job clear a
    tombstone for an identity that still exists? Simulated with an Admin
    API that returns 200 without actually removing the row -- a
    misbehaving or misconfigured endpoint. The job must not trust the
    status code alone; it must not count this as purged, and the tombstone
    must survive for the next run to catch.
    """
    erin = await make_user(raw_conn, "erin@acme-diner.example.com")
    await raw_conn.execute("DELETE FROM profiles WHERE user_id = %s", (erin,))
    await raw_conn.execute("INSERT INTO deleted_accounts (user_id) VALUES (%s)", (erin,))
    await raw_conn.commit()

    async def lying_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"id": str(erin)})  # never actually deletes anything

    async with httpx.AsyncClient(transport=httpx.MockTransport(lying_handler)) as client:
        n = await purge_pending_identities(
            db_url, supabase_url="https://x.supabase.co", service_role_key="k", http=client,
        )

    assert n == 0, "a 200 that did not actually remove the identity must not count as purged"
    assert await _tombstone(raw_conn, erin) == 1, "the tombstone must survive for a retry"


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

    monkeypatch.setattr(purge_module, "run_purge", boom)
    monkeypatch.setattr(purge_module, "purge_pending_identities", fake_identities)

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

    monkeypatch.setattr(purge_module, "run_purge", fake_orgs)
    monkeypatch.setattr(purge_module, "purge_pending_identities", boom)

    with pytest.raises(RuntimeError, match="identities"):
        await run_all(db_url)

    assert org_called["value"] is True, (
        "an identity-purge failure must not prevent the org half from running"
    )


async def test_run_all_returns_both_counts_when_both_halves_succeed(monkeypatch, db_url, seeded):
    async def fake_orgs(db_url, storage_delete=None):
        return 2

    async def fake_identities(db_url, **kwargs):
        return 5

    monkeypatch.setattr(purge_module, "run_purge", fake_orgs)
    monkeypatch.setattr(purge_module, "purge_pending_identities", fake_identities)

    result = await run_all(db_url)
    assert result == (2, 5)
