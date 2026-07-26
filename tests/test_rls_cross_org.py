# tests/test_rls_cross_org.py
"""The cross-org isolation gate.

A tenancy leak is the one failure mode in this system that is silent:
everything works, and one restaurant's supplier pricing is visible to
another. Every assertion below goes through `tenant_connection` -- the real
app_user -> `SET LOCAL ROLE authenticated` checkout path -- never through the
`raw_conn` owner fixture, which owns every table and would skip the policies
being tested. The two exceptions are the fixture, which seeds as the owner on
purpose, and the catalog assertion at the bottom, which reads pg_class.

Running this file alone must answer "is tenancy intact?" -- so it covers all
seven tenant tables, not the three the task brief named. A hole in
`invite_all` used to sail through every assertion here.

The brief specified seven assertions; they are all still here, widened:

    read locations / organizations  -> test_org_a_cannot_read_org_b_rows
    write into org B                -> test_org_a_cannot_write_into_org_b
    update org B's row by id        -> test_org_a_cannot_update_org_b_row_by_id
    delete org B's row              -> test_org_a_cannot_delete_org_b_row
    escalate via membership insert  -> kept standalone, see its docstring
    unauthenticated sees nothing    -> test_unauthenticated_claims_see_nothing
"""
import pytest
from tests.conftest import apply_migrations, TENANT_TABLES
from tests.factories import make_user, make_org, add_member, make_location
from api.db import pool_open, tenant_connection


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def two_orgs(raw_conn):
    """Two orgs, one owner each, and one row per tenant table per org.

    Seeded through `raw_conn`, which is the owner and bypasses RLS. Nothing
    below reads it back through that connection.
    """
    await apply_migrations(raw_conn, upto=4)
    alice = await make_user(raw_conn, "alice@acme.test")
    bob = await make_user(raw_conn, "bob@bistro.test")
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    alice_m = await add_member(raw_conn, alice, acme, "owner")
    bob_m = await add_member(raw_conn, bob, bistro, "owner")
    acme_loc = await make_location(raw_conn, acme, "Acme Main")
    bistro_loc = await make_location(raw_conn, bistro, "Bistro Main")

    # A user with no profile and no membership. Without one, the cross-tenant
    # INSERT into `profiles` would have to target Bob, who already has a row --
    # and would then be refused by the primary key before any policy ran,
    # passing the test for the wrong reason.
    cur = await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), %s) RETURNING id",
        ("mallory@nowhere.test",),
    )
    (mallory,) = await cur.fetchone()

    ids = dict(alice=alice, bob=bob, mallory=mallory, acme=acme, bistro=bistro,
               alice_m=alice_m, bob_m=bob_m, acme_loc=acme_loc, bistro_loc=bistro_loc)
    for side, org, user in (("acme", acme, alice), ("bistro", bistro, bob)):
        cur = await raw_conn.execute(
            "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at)"
            " VALUES (%s, %s, 'manager', %s, %s, now() + interval '7 days') RETURNING id",
            (org, f"hire@{side}.test", f"invite-{side}", user),
        )
        (ids[f"{side}_invite"],) = await cur.fetchone()
        cur = await raw_conn.execute(
            "INSERT INTO email_verifications (user_id, token_hash, expires_at)"
            " VALUES (%s, %s, now() + interval '1 day') RETURNING id",
            (user, f"verify-{side}"),
        )
        (ids[f"{side}_ev"],) = await cur.fetchone()
        cur = await raw_conn.execute(
            "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at)"
            " VALUES (%s, %s, now() + interval '1 day') RETURNING id",
            (str(user), f"link-{side}"),
        )
        (ids[f"{side}_alr"],) = await cur.fetchone()
    await raw_conn.commit()
    return ids


@pytest.fixture
def spec(two_orgs):
    """Per table: Alice's own row, Bob's row, and a cross-tenant INSERT.

    `mine` and `theirs` are values of `key`, so one read, one update and one
    delete assertion serve all seven tables unchanged. A table added to
    TENANT_TABLES but not here raises KeyError -- loudly -- rather than
    shrinking the gate by one table in silence.
    """
    t = two_orgs
    return {
        "organizations": dict(
            key="id", mine=t["acme"], theirs=t["bistro"], col="name", val="pwned",
            # There is no INSERT policy on organizations by design (orgs are
            # created out of band), so any insert at all must be refused.
            insert=("INSERT INTO organizations (name) VALUES ('Trojan')", ()),
        ),
        "memberships": dict(
            key="id", mine=t["alice_m"], theirs=t["bob_m"], col="role", val="owner",
            insert=("INSERT INTO memberships (user_id, org_id, role)"
                    " VALUES (%s, %s, 'manager')", (t["mallory"], t["bistro"])),
        ),
        "locations": dict(
            key="id", mine=t["acme_loc"], theirs=t["bistro_loc"], col="name", val="pwned",
            insert=("INSERT INTO locations (org_id, name) VALUES (%s, 'Trojan')",
                    (t["bistro"],)),
        ),
        "invites": dict(
            key="id", mine=t["acme_invite"], theirs=t["bistro_invite"],
            col="email", val="pwned@x.test",
            insert=("INSERT INTO invites (org_id, email, role, token_hash, invited_by,"
                    " expires_at) VALUES (%s, 'x@x.test', 'owner', 'trojan-invite', %s,"
                    " now() + interval '1 day')", (t["bistro"], t["alice"])),
        ),
        "profiles": dict(
            key="user_id", mine=t["alice"], theirs=t["bob"],
            col="contact_email", val="pwned@x.test",
            insert=("INSERT INTO profiles (user_id, contact_email) VALUES (%s, 'x@x.test')",
                    (t["mallory"],)),
        ),
        "email_verifications": dict(
            key="id", mine=t["acme_ev"], theirs=t["bistro_ev"],
            col="token_hash", val="pwned-verify",
            insert=("INSERT INTO email_verifications (user_id, token_hash, expires_at)"
                    " VALUES (%s, 'trojan-verify', now() + interval '1 day')", (t["bob"],)),
        ),
        "apple_link_requests": dict(
            key="id", mine=t["acme_alr"], theirs=t["bistro_alr"],
            col="token_hash", val="pwned-link",
            insert=("INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at)"
                    " VALUES (%s, 'trojan-link', now() + interval '1 day')",
                    (str(t["bob"]),)),
        ),
    }


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_org_a_cannot_read_org_b_rows(db_url, two_orgs, spec, table):
    s = spec[table]
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute(f"SELECT {s['key']} FROM {table}")
        seen = {r[0] for r in await cur.fetchall()}
    await pool.close()
    # Both halves matter. The first catches a policy set that denies
    # everything -- which would satisfy every other assertion in this file.
    assert s["mine"] in seen, f"{table}: caller cannot see their own row"
    assert seen == {s["mine"]}, f"TENANCY LEAK: {table} exposed {seen - {s['mine']}}"


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_org_a_cannot_write_into_org_b(db_url, two_orgs, spec, table):
    """WITH CHECK is the clause under test. USING alone would allow this."""
    sql, args = spec[table]["insert"]
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(sql, args)
    await pool.close()
    # Not just "it failed": a missing GRANT would also raise here, and would
    # go on doing so after every policy in 0004 was deleted.
    assert "row-level security" in str(exc.value).lower(), str(exc.value)


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_org_a_cannot_update_org_b_row_by_id(db_url, two_orgs, spec, table):
    s = spec[table]
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute(
            f"UPDATE {table} SET {s['col']} = %s WHERE {s['key']} = %s",
            (s["val"], s["theirs"]),
        )
        assert cur.rowcount == 0, f"TENANCY LEAK: updated another org's {table} row"
    await pool.close()


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_org_a_cannot_delete_org_b_row(db_url, two_orgs, spec, table):
    s = spec[table]
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute(f"DELETE FROM {table} WHERE {s['key']} = %s", (s["theirs"],))
        assert cur.rowcount == 0, f"TENANCY LEAK: deleted another org's {table} row"
    await pool.close()


async def test_org_a_cannot_escalate_by_inserting_membership(db_url, two_orgs):
    """Kept separate from the parametrised insert above, which adds a third
    party to Bistro. This is the sharper case: Alice writing *herself* into
    Bistro as an owner, the one insert that would hand her every other table.
    """
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(
                "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, 'owner')",
                (two_orgs["alice"], two_orgs["bistro"]),
            )
    await pool.close()
    assert "row-level security" in str(exc.value).lower()


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_unauthenticated_claims_see_nothing(db_url, two_orgs, table):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {}) as conn:
        cur = await conn.execute(f"SELECT count(*) FROM {table}")
        (n,) = await cur.fetchone()
    await pool.close()
    assert n == 0, f"a caller with no sub saw {n} rows of {table}"


async def test_every_table_in_public_enables_and_forces_rls(raw_conn):
    """Deliberately NOT an allowlist -- that is the whole point.

    Every other RLS assertion in this suite iterates TENANT_TABLES, so a table
    added by a later migration is not merely unchecked, it is never looked
    for. `pg_policies` makes that worse: a table with zero policies contributes
    zero rows, so the with_check audit passes vacuously. And 0003's ALTER
    DEFAULT PRIVILEGES hands `authenticated` full DML on any future table
    automatically, with no GRANT line in the new migration to prompt its author
    to think about access, while RLS stays off by default. The combination is a
    readable, writable, world-visible table that the whole suite stays green
    over -- and Tasks 6-14 add exactly such tables.

    So this walks pg_class instead: whatever exists in `public` must be
    protected. Applies EVERY migration on disk (no `upto`) -- pinning a version
    here would restore precisely the blindness it exists to remove.
    """
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class"
        " WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p')"
        " ORDER BY relname"
    )
    rows = await cur.fetchall()
    present = {name for name, _, _ in rows}
    assert present >= set(TENANT_TABLES), f"tables vanished: {set(TENANT_TABLES) - present}"
    unguarded = [name for name, enabled, forced in rows if not (enabled and forced)]
    assert unguarded == [], (
        f"{unguarded}: every table in `public` must ENABLE and FORCE row level "
        "security. A new tenant table inherits full DML for `authenticated` from "
        "0003's ALTER DEFAULT PRIVILEGES but no policies, so until both flags are "
        "set it is readable and writable by every tenant. Add the two ALTER TABLE "
        "lines and its policies to the migration, and add it to TENANT_TABLES and "
        "to the `spec` fixture in this file."
    )
