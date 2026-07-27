# tests/test_business_rls.py
"""Policies on the four business tables: role-shaped writes, org isolation
via location_id, and the scheduled-org write freeze."""
import pytest
from tests.conftest import apply_migrations
from tests.factories import (
    make_user, make_org, add_member, make_location, make_ingredient)
from api.db import pool_open, tenant_connection


def app_url(url):
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def actors(raw_conn):
    await apply_migrations(raw_conn)
    alice = await make_user(raw_conn, "alice@acme.test")    # owner
    carol = await make_user(raw_conn, "carol@acme.test")    # manager
    dave = await make_user(raw_conn, "dave@acme.test")      # bookkeeper
    bob = await make_user(raw_conn, "bob@bistro.test")      # other org
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    for u, r in ((alice, "owner"), (carol, "manager"), (dave, "bookkeeper")):
        await add_member(raw_conn, u, acme, r)
    await add_member(raw_conn, bob, bistro, "owner")
    loc = await make_location(raw_conn, acme, "Acme Main")
    b_loc = await make_location(raw_conn, bistro, "Bistro Main")
    ing = await make_ingredient(raw_conn, loc, "Chicken Breast")
    await raw_conn.commit()
    return dict(alice=alice, carol=carol, dave=dave, bob=bob,
                acme=acme, loc=loc, b_loc=b_loc, ing=ing)


@pytest.fixture
async def pool(db_url, actors):
    p = await pool_open(app_url(db_url))
    try:
        yield p
    finally:
        await p.close()


async def test_bookkeeper_can_insert_purchase(pool, actors):
    async with tenant_connection(pool, {"sub": str(actors["dave"])}) as conn:
        await conn.execute(
            "INSERT INTO purchases (location_id, ingredient_id, purchased_on,"
            " qty, unit, qty_base_units, total_price)"
            " VALUES (%s, %s, '2026-07-01', 10, 'lb', 10, 32.00)",
            (actors["loc"], actors["ing"]))


async def test_bookkeeper_cannot_write_recipes(pool, actors):
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(actors["dave"])}) as conn:
            await conn.execute(
                "INSERT INTO recipes (location_id, name, menu_price)"
                " VALUES (%s, 'Sneaky Special', 9.99)", (actors["loc"],))
    assert "row-level security" in str(exc.value).lower()


async def test_manager_can_write_recipes(pool, actors):
    async with tenant_connection(pool, {"sub": str(actors["carol"])}) as conn:
        await conn.execute(
            "INSERT INTO recipes (location_id, name, menu_price)"
            " VALUES (%s, 'Daily Special', 12.00)", (actors["loc"],))


async def test_cross_org_insert_blocked_by_with_check(pool, actors):
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(actors["bob"])}) as conn:
            await conn.execute(
                "INSERT INTO ingredients (location_id, name, base_unit)"
                " VALUES (%s, 'Trojan Truffle', 'lb')", (actors["loc"],))
    assert "row-level security" in str(exc.value).lower()


async def test_cross_org_read_sees_nothing(pool, actors):
    async with tenant_connection(pool, {"sub": str(actors["bob"])}) as conn:
        for t in ("ingredients", "purchases", "recipes", "recipe_items"):
            cur = await conn.execute(f"SELECT count(*) FROM {t}")
            assert (await cur.fetchone())[0] == 0, f"{t} leaked cross-org"


async def test_delete_is_not_granted(pool, actors):
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
            await conn.execute("DELETE FROM ingredients WHERE id = %s",
                               (actors["ing"],))
    assert "permission denied" in str(exc.value).lower()


async def test_scheduled_org_write_freeze_cs410(pool, actors, raw_conn):
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() WHERE id = %s",
        (actors["acme"],))
    await raw_conn.commit()
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
            await conn.execute(
                "INSERT INTO ingredients (location_id, name, base_unit)"
                " VALUES (%s, 'Too Late', 'lb')", (actors["loc"],))
    assert getattr(exc.value, "sqlstate", None) == "CS410"
