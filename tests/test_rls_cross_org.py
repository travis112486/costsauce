# tests/test_rls_cross_org.py
"""The cross-org isolation gate.

A tenancy leak is the one failure mode in this system that is silent:
everything works, and one restaurant's supplier pricing is visible to
another. Every assertion below goes through `tenant_connection` -- the real
app_user -> `SET LOCAL ROLE authenticated` checkout path -- never through the
`raw_conn` owner fixture, which owns every table and would skip the policies
being tested.
"""
import pytest
from tests.conftest import apply_migrations
from tests.factories import make_user, make_org, add_member, make_location
from api.db import pool_open, tenant_connection


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def two_orgs(raw_conn):
    await apply_migrations(raw_conn, upto=4)
    alice = await make_user(raw_conn, "alice@acme.test")
    bob = await make_user(raw_conn, "bob@bistro.test")
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    await add_member(raw_conn, alice, acme, "owner")
    await add_member(raw_conn, bob, bistro, "owner")
    acme_loc = await make_location(raw_conn, acme, "Acme Main")
    bistro_loc = await make_location(raw_conn, bistro, "Bistro Main")
    await raw_conn.commit()
    return dict(alice=alice, bob=bob, acme=acme, bistro=bistro,
                acme_loc=acme_loc, bistro_loc=bistro_loc)


async def test_org_a_cannot_read_org_b_locations(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute("SELECT id FROM locations")
        rows = await cur.fetchall()
    await pool.close()
    ids = {r[0] for r in rows}
    assert two_orgs["acme_loc"] in ids
    assert two_orgs["bistro_loc"] not in ids, "TENANCY LEAK: read another org's location"


async def test_org_a_cannot_read_org_b_organizations(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute("SELECT id FROM organizations")
        rows = await cur.fetchall()
    await pool.close()
    assert {r[0] for r in rows} == {two_orgs["acme"]}


async def test_org_a_cannot_write_into_org_b(db_url, two_orgs):
    """WITH CHECK is the clause under test. USING alone would allow this."""
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(
                "INSERT INTO locations (org_id, name) VALUES (%s, 'Trojan')",
                (two_orgs["bistro"],),
            )
    await pool.close()
    assert "row-level security" in str(exc.value).lower()


async def test_org_a_cannot_update_org_b_row_by_id(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute(
            "UPDATE locations SET name = 'pwned' WHERE id = %s", (two_orgs["bistro_loc"],)
        )
        assert cur.rowcount == 0, "TENANCY LEAK: updated another org's row"
    await pool.close()


async def test_org_a_cannot_delete_org_b_row(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute("DELETE FROM locations WHERE id = %s", (two_orgs["bistro_loc"],))
        assert cur.rowcount == 0
    await pool.close()


async def test_org_a_cannot_escalate_by_inserting_membership(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(
                "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, 'owner')",
                (two_orgs["alice"], two_orgs["bistro"]),
            )
    await pool.close()
    assert "row-level security" in str(exc.value).lower()


async def test_unauthenticated_claims_see_nothing(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {}) as conn:
        cur = await conn.execute("SELECT count(*) FROM locations")
        (n,) = await cur.fetchone()
    await pool.close()
    assert n == 0, "a caller with no sub must see nothing"
