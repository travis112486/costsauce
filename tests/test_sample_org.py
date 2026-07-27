# tests/test_sample_org.py
"""Task 13: the fictional sample org.

The legacy demo (product/app.py:254-263) paired invented prices and drift
percentages with real, trademarked distributors -- Sysco, US Foods, Reinhart
Foodservice, Fresh Point Produce, Regalis. That data is live on the public
demo site today and would otherwise land in App Store screenshots. This file
proves three things about its fictional replacement:

  1. no real distributor name survives anywhere in the schema's seed data,
  2. exactly one organization is flagged `is_sample`, and
  3. nothing tagged as sample-org content is mistaken for a real org's data.

A fourth test pins a deployability defect found while writing migration
0009: see its docstring.
"""
import psycopg
import pytest

from tests.conftest import MIGRATIONS, apply_migrations

BANNED = ["Sysco", "US Foods", "Reinhart", "FreshPoint", "Fresh Point", "Regalis"]


async def test_no_real_distributor_names_anywhere_in_seed(raw_conn):
    """Scans every text-like column of every table in `public`, not just
    `organizations.name` and `locations.name`.

    The brief's version of this check named exactly those two columns.
    Phase 1a has no other table to scan, so that version would pass today
    for a reason that has nothing to do with fictional distributor names:
    an org names itself something like "Acme Diner" and a location is "Main
    Street", neither of which is structurally where a *distributor* name
    would ever land. A real distributor name would show up in
    `vendors`/`ingredients` once Phase 1b adds them (see migration 0009's
    reserved fictional vendor list), and a check pinned to today's two
    columns would stay silently blind to that table the moment it exists --
    the exact allowlist gap `test_every_table_in_public_enables_and_forces_
    rls` (tests/test_rls_cross_org.py) was written to close for RLS, applied
    here to seed-data hygiene instead.

    So this is schema-driven (`information_schema.columns`), not
    table-name-driven: it walks every column in `public` whose type can hold
    a distributor name -- `text`, `character varying`, and `citext` (the
    citext extension registers as a base type, so `data_type` alone would
    miss it; `udt_name` catches it) -- and asserts none of their values
    contain a banned name. A Phase 1b `vendors.name` or
    `ingredients.supplier` column is picked up automatically; nothing here
    needs updating when that migration lands.
    """
    await apply_migrations(raw_conn, upto=9)
    cur = await raw_conn.execute(
        "SELECT table_name, column_name FROM information_schema.columns "
        "WHERE table_schema = 'public' "
        "  AND (data_type IN ('text', 'character varying') OR udt_name = 'citext')"
    )
    text_columns = await cur.fetchall()
    assert text_columns, "sanity: no text-like columns found in public schema"

    values = []
    for table, column in text_columns:
        cur = await raw_conn.execute(
            f'SELECT "{column}" FROM "{table}" WHERE "{column}" IS NOT NULL'
        )
        values.extend(r[0] for r in await cur.fetchall())
    blob = " ".join(values)
    for name in BANNED:
        assert name.lower() not in blob.lower(), f"real distributor name in seed: {name}"


async def test_sample_org_is_flagged(raw_conn):
    await apply_migrations(raw_conn, upto=9)
    cur = await raw_conn.execute("SELECT count(*) FROM organizations WHERE is_sample")
    (n,) = await cur.fetchone()
    assert n == 1


async def test_no_sample_rows_leak_into_a_real_org(raw_conn):
    await apply_migrations(raw_conn, upto=9)
    cur = await raw_conn.execute(
        "SELECT count(*) FROM locations l JOIN organizations o ON o.id = l.org_id "
        "WHERE NOT o.is_sample AND l.name LIKE 'Sample%'"
    )
    (n,) = await cur.fetchone()
    assert n == 0


async def test_seed_insert_applies_for_a_non_superuser_owner(raw_conn, db_url):
    """Deployability defect found while writing migration 0009, not
    hypothetical: `organizations` is FORCE ROW LEVEL SECURITY (0004), and
    FORCE applies to the table's OWNER too, not only to `authenticated`. On
    real Supabase the migration-running role owns every table it creates via
    migration and is documented (0007/0008) to be neither a superuser nor
    BYPASSRLS. `organizations` deliberately carries no INSERT policy at all
    (0004: orgs are "created out of band"), and `locations`'s only policies
    are scoped `TO authenticated` -- a role the migration runner is not and
    does not inherit. A bare `INSERT INTO organizations` / `INSERT INTO
    locations`, run as that role, is therefore rejected outright: `new row
    violates row-level security policy for table "organizations"`.

    This repo's own local harness (`raw_conn`) connects as a genuine
    Postgres superuser, which bypasses RLS regardless of FORCE -- so an
    unguarded version of migration 0009 passes every other test in this file
    and would still fail the first real `supabase db push` (Task 14). That
    is exactly the failure class the task brief warns is easy to miss: "the
    local test harness connects as a superuser, so it is invisible unless
    you deliberately test with an unprivileged role."

    So this runs THIS FILE'S ACTUAL TEXT (read from disk, the real shipping
    migration -- not a hand-copied simplified version of its INSERTs) over a
    connection whose role is `NOSUPERUSER NOBYPASSRLS NOINHERIT` and which
    has been made the OWNER of `organizations`/`locations` -- mirroring
    `test_run_purge_works_for_a_restricted_migration_runner_role`
    (tests/test_purge_job.py), which drives the equivalent point for the
    purge job's SQL functions.
    """
    await apply_migrations(raw_conn, upto=8)

    migration_path = next(MIGRATIONS.glob("0009_*.sql"))
    migration_sql = migration_path.read_text()

    await raw_conn.execute(
        "CREATE ROLE test_sample_org_seed_runner LOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT "
        "PASSWORD 'x'"
    )
    await raw_conn.execute("GRANT USAGE ON SCHEMA public TO test_sample_org_seed_runner")
    # Ownership, not just a grant -- this is what actually reproduces the
    # Supabase situation: the migration runner owns every table it creates,
    # and FORCE ROW LEVEL SECURITY makes that ownership NOT exempt it from
    # policy checks the way it ordinarily would.
    await raw_conn.execute("ALTER TABLE organizations OWNER TO test_sample_org_seed_runner")
    await raw_conn.execute("ALTER TABLE locations OWNER TO test_sample_org_seed_runner")
    await raw_conn.commit()

    restricted_url = db_url.replace("postgres:postgres", "test_sample_org_seed_runner:x")
    try:
        conn = await psycopg.AsyncConnection.connect(restricted_url, autocommit=False)
        try:
            await conn.execute(migration_sql)
            await conn.commit()
        finally:
            await conn.close()

        # Not just "it didn't raise": confirm the actual rows landed, over the
        # superuser connection this time (reading the result is not the part
        # under test here -- writing it, as the restricted role, is).
        cur = await raw_conn.execute(
            "SELECT name, plan, is_sample FROM organizations "
            "WHERE id = '00000000-0000-7000-8000-00000000cafe'"
        )
        (name, plan, is_sample) = await cur.fetchone()
        assert (name, plan, is_sample) == ("The Copper Ladle (Sample)", "pro", True)

        cur = await raw_conn.execute(
            "SELECT name FROM locations "
            "WHERE org_id = '00000000-0000-7000-8000-00000000cafe'"
        )
        (loc_name,) = await cur.fetchone()
        assert loc_name == "Sample Kitchen"

        # Defense in depth: the transient seed-insert policies must not survive
        # the migration. Left in place, either one is a live, permanent widening
        # of "no INSERT policy on organizations" (0004) for whichever role ran
        # this migration -- harmless in isolation (that role already has full
        # DDL power over the schema) but not what 0004 documents as the
        # invariant, and not what this migration's own comment promises.
        cur = await raw_conn.execute(
            "SELECT policyname FROM pg_policies "
            "WHERE tablename IN ('organizations', 'locations') "
            "  AND policyname LIKE '%seed_insert%'"
        )
        assert await cur.fetchall() == []
    finally:
        # Final-review Minor: roles are CLUSTER-level, so they outlive the
        # `DROP SCHEMA public CASCADE` every test performs. Without this,
        # running this file twice in one session (`pytest tests/x.py
        # tests/test_sample_org.py`, a re-run under `--lf`, or simply a second
        # parametrisation later) fails on `CREATE ROLE ... already exists`,
        # for a reason that has nothing to do with what is being tested.
        # tests/test_purge_job.py's equivalent role already cleans up in a
        # `finally`; this matches it.
        #
        # REASSIGN before DROP: this role was made the OWNER of
        # `organizations`/`locations` above, and Postgres refuses to drop a
        # role that still owns objects or holds privileges.
        await raw_conn.execute(
            "REASSIGN OWNED BY test_sample_org_seed_runner TO CURRENT_USER"
        )
        await raw_conn.execute("DROP OWNED BY test_sample_org_seed_runner")
        await raw_conn.execute("DROP ROLE test_sample_org_seed_runner")
        await raw_conn.commit()
