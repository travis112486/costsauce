# tests/test_db_checkout.py
import json
import psycopg
import pytest
from tests.conftest import apply_migrations
from api.db import ClaimsLeakError, pool_open, tenant_connection


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


async def test_app_user_has_no_bypassrls(raw_conn):
    await apply_migrations(raw_conn, upto=3)
    cur = await raw_conn.execute(
        "SELECT rolbypassrls, rolsuper, rolinherit FROM pg_roles WHERE rolname = 'app_user'"
    )
    bypass, super_, inherit = await cur.fetchone()
    assert bypass is False, "app_user must never have BYPASSRLS"
    assert super_ is False
    assert inherit is False, "app_user must be NOINHERIT"


async def test_app_user_cannot_bypass_rls_by_any_route(raw_conn):
    """`rolbypassrls is False` on app_user alone is not the guarantee.

    Postgres skips RLS for three reasons, and the test above only rules out
    one of them. The other two are wide open by construction:

    1. 0003 runs `GRANT authenticated TO app_user`, so app_user can `SET ROLE
       authenticated` -- and tenant_connection does exactly that on every
       checkout. NOINHERIT stops passive inheritance, it does not stop SET
       ROLE. If `authenticated`, or anything reachable from it, ever gained
       BYPASSRLS or SUPERUSER, every policy in Task 4 would be silently
       skipped and the assertion above would still be green.
    2. A table's owner bypasses its own RLS unless the table is declared FORCE
       ROW LEVEL SECURITY. So "app_user has no BYPASSRLS" means nothing if a
       future migration ever leaves app_user owning a table.

    Both are checked with pg_has_role(..., 'MEMBER') -- membership, not
    'USAGE' -- because SET ROLE follows membership regardless of NOINHERIT,
    and pg_has_role is transitive, so this keeps holding however deep a future
    grant chain gets.

    Uniquely in this file, this test applies EVERY migration (`upto=None`)
    rather than stopping at 3. The regression it names is a *future*
    migration -- an `ALTER TABLE ... OWNER TO app_user` landing in 0004+ --
    and `raw_conn` rebuilds schema `public` per test, so `upto=3` would mean
    later migrations are never applied and the guarantee would be asserted
    only against tables this task already knows about. This test reads
    catalogs only, so enabling RLS in Task 4 cannot destabilise it; the other
    tests keep `upto=3` deliberately.
    """
    await apply_migrations(raw_conn, upto=None)
    cur = await raw_conn.execute(
        "SELECT rolname FROM pg_roles"
        " WHERE (rolbypassrls OR rolsuper)"
        "   AND pg_has_role('app_user', oid, 'MEMBER')"
    )
    reachable = [row[0] for row in await cur.fetchall()]
    assert reachable == [], (
        f"app_user can SET ROLE into privileged role(s) {reachable}; "
        "RLS is bypassable and every Task 4 policy is decoration"
    )

    # 'auth' as well as 'public': auth.users lives there and 0003 grants it to
    # authenticated. relkind 'p' as well as 'r': partitioned tables carry RLS
    # policies exactly like ordinary ones, so an owned partitioned table is the
    # same bypass.
    cur = await raw_conn.execute(
        "SELECT n.nspname || '.' || c.relname FROM pg_class c"
        "  JOIN pg_namespace n ON n.oid = c.relnamespace"
        " WHERE n.nspname IN ('public', 'auth') AND c.relkind IN ('r', 'p')"
        "   AND pg_has_role('app_user', c.relowner, 'MEMBER')"
    )
    owned = [row[0] for row in await cur.fetchall()]
    assert owned == [], (
        f"app_user owns table(s) {owned}; owners bypass their own RLS "
        "unless the table is FORCE ROW LEVEL SECURITY"
    )


async def test_claims_do_not_survive_checkout(raw_conn, db_url):
    """The whole point of SET LOCAL: org B must never see org A's claims."""
    await apply_migrations(raw_conn, upto=3)
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": "user-a"}) as conn:
        cur = await conn.execute("SELECT current_setting('request.jwt.claims', true)")
        (claims,) = await cur.fetchone()
        assert json.loads(claims)["sub"] == "user-a"
    async with tenant_connection(pool, {"sub": "user-b"}) as conn:
        cur = await conn.execute("SELECT current_setting('request.jwt.claims', true)")
        (claims,) = await cur.fetchone()
        assert json.loads(claims)["sub"] == "user-b", "claims leaked across checkout"
    await pool.close()


async def test_claims_are_cleared_after_rollback(raw_conn, db_url):
    await apply_migrations(raw_conn, upto=3)
    pool = await pool_open(app_url(db_url))
    with pytest.raises(RuntimeError):
        async with tenant_connection(pool, {"sub": "user-c"}):
            raise RuntimeError("boom")
    async with tenant_connection(pool, {"sub": "user-d"}) as conn:
        cur = await conn.execute("SELECT current_setting('request.jwt.claims', true)")
        (claims,) = await cur.fetchone()
        assert json.loads(claims)["sub"] == "user-d"
    await pool.close()


async def test_a_leaked_claim_from_a_bare_set_is_detected(raw_conn, db_url):
    """Covers the ClaimsLeakError canary, which nothing else touches.

    Deleting the canary from api/db.py leaves every other test in this file
    green, which makes it read as dead code to a future refactor. It is not:
    it is the *only* detector for a whole class of leak. Note that removing it
    composes with a second defect to defeat the suite entirely -- with the
    canary gone AND the claims set session-wide instead of SET LOCAL, checkout
    1 writes `user-a` and reads `user-a`, checkout 2 overwrites with `user-b`
    and reads `user-b`, so test_claims_do_not_survive_checkout passes while
    claims are in fact persisting on the pooled connection the whole time.

    So simulate the leak directly: poison a pooled connection with a bare SET,
    commit it so it survives the pool's rollback-on-return, and require the
    next tenant_connection to refuse to hand it out. This is also the only
    direct assertion on ClaimsLeakError, which the brief lists as a Produced
    interface.
    """
    await apply_migrations(raw_conn, upto=3)
    pool = await pool_open(app_url(db_url))
    async with pool.connection() as conn:
        await conn.execute("SET request.jwt.claims = '{\"sub\": \"ghost\"}'")
        await conn.commit()

    with pytest.raises(ClaimsLeakError, match="ghost"):
        async with tenant_connection(pool, {"sub": "user-g"}):
            pass  # pragma: no cover -- checkout must fail before the body runs
    await pool.close()


async def test_role_does_not_survive_checkout(raw_conn, db_url):
    """The identity swap is `SET LOCAL ROLE`, and it must die with the txn too.

    The claims tests above would all still pass if the role swap were a plain
    `SET ROLE` -- or if it were dropped entirely. Assert both halves directly:
    inside the block the connection really has become `authenticated` (a bare
    app_user has no table privileges at all, so Task 4's policies would never
    even be reached), and the next caller out of the pool is plain app_user
    again.
    """
    await apply_migrations(raw_conn, upto=3)
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": "user-e"}) as conn:
        cur = await conn.execute("SELECT current_user, session_user")
        current_user, session_user = await cur.fetchone()
        assert current_user == "authenticated", "tenant_connection must SET LOCAL ROLE"
        assert session_user == "app_user", "the pool must log in as app_user"
    async with pool.connection() as conn:
        cur = await conn.execute("SELECT current_user")
        (current_user,) = await cur.fetchone()
        assert current_user == "app_user", "role leaked across checkout"
    await pool.close()


async def test_table_access_arrives_only_with_the_role_swap(raw_conn, db_url):
    """0003's GRANT block is the other half of this task, and nothing else
    covers it. If `GRANT USAGE ON SCHEMA public` or the table grants were
    missing, every Task 4 policy test would fail for a reason that has nothing
    to do with policies. And the migration's "deliberately powerless" comment
    is a claim about app_user that should be enforced, not just asserted in
    prose: reads must become possible only after SET LOCAL ROLE, never before.
    """
    await apply_migrations(raw_conn, upto=3)
    await raw_conn.execute("INSERT INTO organizations (name) VALUES ('Acme')")
    await raw_conn.commit()
    pool = await pool_open(app_url(db_url))

    async with tenant_connection(pool, {"sub": "user-f"}) as conn:
        cur = await conn.execute("SELECT count(*) FROM organizations")
        assert (await cur.fetchone())[0] == 1, "authenticated must be able to read"
        cur = await conn.execute("SELECT count(*) FROM auth.users")
        assert (await cur.fetchone())[0] == 0, "authenticated must be able to read auth.users"

    async with pool.connection() as conn:
        with pytest.raises(psycopg.Error):
            await conn.execute("SELECT count(*) FROM organizations")
        await conn.rollback()
    await pool.close()
