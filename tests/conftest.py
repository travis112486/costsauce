# tests/conftest.py
import atexit
import asyncio
import os
import pathlib
import signal
import subprocess
import time
import uuid
import pytest
import psycopg

MIGRATIONS = pathlib.Path(__file__).parent.parent / "supabase" / "migrations"

# Every table that carries tenancy RLS. `test_rls_cross_org.py` and
# `test_rls_policies.py` both bind to this one tuple so their coverage cannot
# drift apart -- previously each named its own list, and the cross-org gate's
# list was the shorter of the two.
#
# It is still an allowlist, so it cannot be the only guard: a table added by a
# later migration and forgotten here would be invisible to every test that
# iterates it. That gap is closed separately, and without an allowlist, by
# `test_every_table_in_public_enables_and_forces_rls`, which walks pg_class.
# Adding a tenant table means adding it here AND giving it a row in that
# file's `spec` fixture; miss the latter and the parametrised tests raise
# KeyError rather than quietly testing one table fewer.
TENANT_TABLES = (
    "organizations", "memberships", "locations", "invites",
    "profiles", "email_verifications", "apple_link_requests",
)


def _install_container_reaper(name: str):
    """Defence in depth for the disposable container's cleanup.

    The fixture's own `yield url` / `docker kill` teardown below only runs on a
    normal pytest finalization pass. If the test process is interrupted before
    that point -- SIGINT, SIGTERM from a CI job timeout, or an uncaught
    exception elsewhere during session setup -- that teardown code never runs,
    and `--rm` alone does not help: it only auto-removes a container after it
    stops, it does not stop a still-running one. So without this, the
    container leaks indefinitely.

    This registers the same cleanup both as an `atexit` callback (covers
    KeyboardInterrupt/SIGINT and uncaught exceptions, since Python still runs
    atexit callbacks as it unwinds to a normal process exit) and as a SIGTERM
    handler (Python installs no default handler for SIGTERM, so without this
    the process would simply die without running atexit callbacks at all).

    This is explicitly best-effort, not a guarantee: a SIGKILL or an OOM-kill
    of this process leaves no code running in-process to catch it, and no
    signal handler or atexit hook can change that. The residual leak risk in
    that narrow case is accepted; everything else is now covered.
    """

    def cleanup(*_a):
        subprocess.run(["docker", "kill", name], capture_output=True)

    atexit.register(cleanup)
    prior_sigterm = signal.getsignal(signal.SIGTERM)

    def _on_sigterm(signum, frame):
        cleanup()
        signal.signal(signal.SIGTERM, prior_sigterm)
        os.kill(os.getpid(), signal.SIGTERM)

    signal.signal(signal.SIGTERM, _on_sigterm)

    def uninstall():
        atexit.unregister(cleanup)
        signal.signal(signal.SIGTERM, prior_sigterm)

    return cleanup, uninstall


@pytest.fixture(scope="session")
def db_url() -> str:
    """A disposable Postgres 17. Never the Supabase project."""
    url = os.environ.get("TEST_DATABASE_URL")
    if url:
        yield url
        return
    name = f"costsauce-test-{uuid.uuid4().hex[:8]}"
    subprocess.run(
        ["docker", "run", "-d", "--rm", "--name", name,
         "-e", "POSTGRES_PASSWORD=postgres", "-P", "postgres:17"],
        check=True, capture_output=True,
    )
    cleanup, uninstall = _install_container_reaper(name)
    port = subprocess.run(
        ["docker", "port", name, "5432/tcp"],
        check=True, capture_output=True, text=True,
    ).stdout.strip().rsplit(":", 1)[1]
    url = f"postgresql://postgres:postgres@localhost:{port}/postgres"
    for _ in range(60):
        try:
            psycopg.connect(url, connect_timeout=1).close()
            break
        except psycopg.OperationalError:
            time.sleep(0.5)
    else:
        raise RuntimeError("test postgres never became ready")
    yield url
    cleanup()
    uninstall()


async def apply_migrations(conn, upto: int | None = None) -> None:
    for path in sorted(MIGRATIONS.glob("*.sql")):
        number = int(path.name.split("_", 1)[0])
        if upto is not None and number > upto:
            continue
        await conn.execute(path.read_text())
    await conn.commit()


@pytest.fixture
async def raw_conn(db_url):
    """Owner-role connection. Fresh schema per test."""
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    await conn.execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public")
    await conn.execute("DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth")
    await conn.execute(
        "CREATE TABLE auth.users ("
        "  id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb DEFAULT '{}')"
    )
    await conn.commit()
    yield conn
    await conn.close()


from httpx import AsyncClient, ASGITransport


@pytest.fixture
async def seeded(raw_conn):
    from tests.factories import make_user, make_org, add_member, make_location
    # Renumbering note (Task 7 fix report): this cap was chosen as "everything
    # through Task 13's sample-org migration" when that migration was still
    # numbered 0006. Task 7 took 0005 for email_verification_binding, which
    # bumped Task 11's deletion migration to 0006 and Task 13's sample-org
    # migration to 0007 -- so the cap moved to 7 to preserve the original
    # intent (a stale `upto=6` would now stop one migration short, silently
    # excluding Task 13's once it lands). Harmless today: migrations 0006/0007
    # don't exist yet, so this applies everything that does (currently 0001-5).
    await apply_migrations(raw_conn, upto=7)
    alice = await make_user(raw_conn, "alice@acme.test")
    bob = await make_user(raw_conn, "bob@bistro.test")
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    await add_member(raw_conn, alice, acme, "owner")
    await add_member(raw_conn, bob, bistro, "owner")
    await make_location(raw_conn, acme, "Acme Main")
    await raw_conn.commit()
    return dict(alice=alice, bob=bob, acme=acme, bistro=bistro)


@pytest.fixture(scope="session")
def _roles_bootstrapped(db_url):
    """Guarantee `app_user`/`authenticated` exist before any `app_client` pool
    ever opens, independent of which test happens to run first.

    `db_url` hands out ONE Postgres container for the whole session, but every
    other fixture that applies migrations (`raw_conn` + `seeded`) is
    function-scoped: it only runs when a specific test asks for it, and it
    drops/recreates `public`/`auth` at the START of that test, not before the
    session. `app_client` authenticates as `app_user` -- a role migration 0003
    creates -- but nothing upstream forced 0003 to have run yet. Empirically,
    `test_missing_token_is_401` (the first test pytest collects) requests only
    `app_client`, and even tests that request both `app_client` and `seeded`
    still fail: pytest sets up same-scope fixtures in the order they appear as
    parameters, and every test here lists `app_client` first, so its pool-open
    races ahead of `seeded`'s migrations. Reproduced directly: all 7 tests in
    this file failed with `psycopg_pool.PoolTimeout` / `FATAL: password
    authentication failed for user "app_user"` before this fixture existed.

    Migrating once here, before any pool exists, removes the ordering
    dependency entirely. It is safe to run only once per session: the roles
    migration 0003 creates are cluster-level, not schema objects, so they
    survive every later `DROP SCHEMA ... CASCADE` that `raw_conn` performs,
    and 0003/0004 are written to be idempotent (`IF NOT EXISTS` role guards,
    `CREATE OR REPLACE` functions) so a later from-scratch re-application by
    `seeded` never conflicts with this bootstrap having already run.
    """

    async def _bootstrap():
        conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
        await conn.execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public")
        await conn.execute("DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth")
        await conn.execute(
            "CREATE TABLE auth.users ("
            "  id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb DEFAULT '{}')"
        )
        await conn.commit()
        await apply_migrations(conn)
        await conn.close()

    asyncio.run(_bootstrap())


@pytest.fixture
async def app_client(db_url, monkeypatch, _roles_bootstrapped):
    monkeypatch.setenv("JWT_SECRET", "test-jwt-secret")
    monkeypatch.setenv("JWT_ISSUER", "https://khohfrfqzbieaiikqlsa.supabase.co/auth/v1")
    monkeypatch.setenv("DATABASE_URL", db_url.replace("postgres:postgres", "app_user:app_pw"))
    from api.main import create_app
    app = create_app()
    async with app.router.lifespan_context(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
            yield c
