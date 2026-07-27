# tests/test_sync_ops_rls.py
"""sync_ops (0014 §5): the idempotency ledger.

Catalog checks run through raw_conn (owner, bypasses RLS -- that's the point,
they read pg_class/information_schema). Every access-control assertion goes
through `tenant_connection` -- the real app_user -> `SET LOCAL ROLE
authenticated` checkout path -- never raw_conn, which owns the table and
would sail through any policy being tested.
"""
import uuid

import pytest

from tests.conftest import apply_migrations
from tests.factories import make_user, make_org, add_member, make_location
from api.db import pool_open, tenant_connection


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def two_orgs(raw_conn):
    await apply_migrations(raw_conn)  # all, incl. 0014
    alice = await make_user(raw_conn, "alice@acme.test")
    bob = await make_user(raw_conn, "bob@bistro.test")
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    await add_member(raw_conn, alice, acme, "owner")
    await add_member(raw_conn, bob, bistro, "owner")
    await make_location(raw_conn, acme, "Acme Main")
    await make_location(raw_conn, bistro, "Bistro Main")
    await raw_conn.commit()
    return dict(alice=alice, bob=bob, acme=acme, bistro=bistro)


# --- (a) catalog -------------------------------------------------------


async def test_sync_ops_exists_and_rls_enabled_forced(raw_conn):
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT relrowsecurity, relforcerowsecurity FROM pg_class"
        " WHERE relnamespace = 'public'::regnamespace AND relname = 'sync_ops'"
    )
    row = await cur.fetchone()
    assert row is not None, "sync_ops table does not exist"
    assert row == (True, True), "sync_ops must ENABLE and FORCE row level security"


async def test_authenticated_has_exactly_select_insert(raw_conn):
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT privilege_type FROM information_schema.role_table_grants"
        " WHERE table_schema = 'public' AND table_name = 'sync_ops'"
        "   AND grantee = 'authenticated'"
    )
    privs = {r[0] for r in await cur.fetchall()}
    assert privs == {"SELECT", "INSERT"}, privs


# --- (b) behavior, through the real RLS checkout path -------------------


async def test_alice_can_insert_and_sees_only_her_org(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    op_id = str(uuid.uuid4())
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        await conn.execute(
            "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
            " VALUES (%s, %s, uuid_generate_v7(), '{}')",
            (op_id, two_orgs["acme"]),
        )
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute("SELECT op_id FROM sync_ops")
        seen = {str(r[0]) for r in await cur.fetchall()}
    await pool.close()
    assert seen == {op_id}, f"TENANCY LEAK or missing own row: saw {seen}"


async def test_insert_into_other_org_is_rls_denied(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(
                "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
                " VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}')",
                (two_orgs["bistro"],),
            )
    await pool.close()
    assert "row-level security" in str(exc.value).lower(), str(exc.value)


async def test_update_is_not_granted(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute(
            "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
            " VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}') RETURNING op_id",
            (two_orgs["acme"],),
        )
        (op_id,) = await cur.fetchone()
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(
                "UPDATE sync_ops SET batch_id = uuid_generate_v7() WHERE op_id = %s",
                (op_id,),
            )
    await pool.close()
    assert "permission denied" in str(exc.value).lower(), str(exc.value)


async def test_delete_is_not_granted(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute(
            "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
            " VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}') RETURNING op_id",
            (two_orgs["acme"],),
        )
        (op_id,) = await cur.fetchone()
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute("DELETE FROM sync_ops WHERE op_id = %s", (op_id,))
    await pool.close()
    assert "permission denied" in str(exc.value).lower(), str(exc.value)


# --- (c) purge_expired_sync_ops -----------------------------------------


async def test_purge_expired_sync_ops_deletes_old_keeps_fresh(raw_conn, two_orgs):
    cur = await raw_conn.execute(
        "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json, applied_at)"
        " VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}',"
        "         now() - interval '8 days') RETURNING op_id",
        (two_orgs["acme"],),
    )
    (stale_id,) = await cur.fetchone()
    cur = await raw_conn.execute(
        "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
        " VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}') RETURNING op_id",
        (two_orgs["acme"],),
    )
    (fresh_id,) = await cur.fetchone()
    await raw_conn.commit()

    cur = await raw_conn.execute("SELECT purge_expired_sync_ops('7 days'::interval)")
    (deleted,) = await cur.fetchone()
    assert deleted == 1, "expected exactly the backdated row to be reaped"

    cur = await raw_conn.execute("SELECT op_id FROM sync_ops")
    remaining = {r[0] for r in await cur.fetchall()}
    assert remaining == {fresh_id}, (stale_id, fresh_id, remaining)
