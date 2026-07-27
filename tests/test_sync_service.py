# tests/test_sync_service.py
"""api/services/sync.py: apply_op's per-field LWW, terminal tombstones,
envelope/parent-liveness gating, and savepoint isolation."""
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from tests.conftest import apply_migrations
from tests.factories import (
    make_user, make_org, add_member, make_location, make_ingredient,
    make_recipe, add_recipe_item)
from api.db import pool_open, tenant_connection
from api.models import SyncOpIn
from api.services.sync import apply_op


def app_url(url):
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def actors(raw_conn):
    await apply_migrations(raw_conn)
    alice = await make_user(raw_conn, "alice@acme.test")     # owner
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    await add_member(raw_conn, alice, acme, "owner")
    loc = await make_location(raw_conn, acme, "Acme Main")
    other_loc = await make_location(raw_conn, bistro, "Bistro Main")
    ing = await make_ingredient(raw_conn, loc, "Chicken Breast")
    recipe = await make_recipe(raw_conn, loc, "Chicken Piccata", "18.99")
    recipe_item = await add_recipe_item(raw_conn, loc, recipe, ing, "2.0000")
    await raw_conn.commit()
    return dict(alice=alice, acme=acme, bistro=bistro, loc=loc,
                other_loc=other_loc, ing=ing, recipe=recipe,
                recipe_item=recipe_item)


@pytest.fixture
async def pool(db_url, actors):
    p = await pool_open(app_url(db_url))
    try:
        yield p
    finally:
        await p.close()


def mkop(**kw):
    defaults = dict(
        op_id=uuid.uuid4(),
        table="ingredients",
        row_id=uuid.uuid4(),
        location_id=uuid.uuid4(),
        client_mutated_at=datetime.now(timezone.utc),
        fields={},
    )
    defaults.update(kw)
    return SyncOpIn(**defaults)


async def test_insert_ingredient_applies(pool, actors):
    row_id = uuid.uuid4()
    cm = datetime.now(timezone.utc)
    op = mkop(table="ingredients", row_id=row_id, location_id=actors["loc"],
              client_mutated_at=cm, fields={"name": "Flour", "base_unit": "lb"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "applied", "row_id": str(row_id)}
        cur = await conn.execute(
            "SELECT id, name, base_unit, client_mutated_at FROM ingredients"
            " WHERE id = %s", (row_id,))
        rid, name, base_unit, row_cm = await cur.fetchone()
        assert rid == row_id
        assert name == "Flour"
        assert base_unit == "lb"
        assert row_cm == cm


async def test_update_with_newer_cm_touches_only_named_field(pool, actors, raw_conn):
    cur = await raw_conn.execute(
        "SELECT client_mutated_at, base_unit, vendor FROM ingredients WHERE id = %s",
        (actors["ing"],))
    cm0, base_unit0, vendor0 = await cur.fetchone()
    new_cm = cm0 + timedelta(seconds=1)
    op = mkop(table="ingredients", row_id=actors["ing"], location_id=actors["loc"],
              client_mutated_at=new_cm, fields={"name": "Chicken Thigh"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "applied", "row_id": str(actors["ing"])}
        cur = await conn.execute(
            "SELECT name, base_unit, vendor, client_mutated_at FROM ingredients"
            " WHERE id = %s", (actors["ing"],))
        name, base_unit, vendor, row_cm = await cur.fetchone()
        assert name == "Chicken Thigh"
        assert base_unit == base_unit0
        assert vendor == vendor0
        assert row_cm == new_cm


async def test_update_with_older_cm_is_stale_and_row_untouched(pool, actors, raw_conn):
    cur = await raw_conn.execute(
        "SELECT client_mutated_at, name FROM ingredients WHERE id = %s", (actors["ing"],))
    cm0, name0 = await cur.fetchone()
    older_cm = cm0 - timedelta(seconds=1)
    op = mkop(table="ingredients", row_id=actors["ing"], location_id=actors["loc"],
              client_mutated_at=older_cm, fields={"name": "Sneaky Rename"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "stale", "reason": "older"}
        cur = await conn.execute(
            "SELECT name FROM ingredients WHERE id = %s", (actors["ing"],))
        (name,) = await cur.fetchone()
        assert name == name0


async def test_update_with_equal_cm_applies(pool, actors, raw_conn):
    cur = await raw_conn.execute(
        "SELECT client_mutated_at FROM ingredients WHERE id = %s", (actors["ing"],))
    (cm0,) = await cur.fetchone()
    op = mkop(table="ingredients", row_id=actors["ing"], location_id=actors["loc"],
              client_mutated_at=cm0, fields={"name": "Equal Cm Rename"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "applied", "row_id": str(actors["ing"])}


async def test_op_against_tombstoned_row_is_stale_deleted(pool, actors, raw_conn):
    await raw_conn.execute(
        "UPDATE ingredients SET deleted_at = now() WHERE id = %s", (actors["ing"],))
    await raw_conn.commit()
    op = mkop(table="ingredients", row_id=actors["ing"], location_id=actors["loc"],
              client_mutated_at=datetime.now(timezone.utc) + timedelta(hours=1),
              fields={"name": "Resurrection Attempt"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "stale", "reason": "deleted"}


async def test_tombstone_op_applies_and_row_is_tombstoned(pool, actors, raw_conn):
    cur = await raw_conn.execute(
        "SELECT client_mutated_at FROM ingredients WHERE id = %s", (actors["ing"],))
    (cm0,) = await cur.fetchone()
    new_cm = cm0 + timedelta(seconds=1)
    op = mkop(table="ingredients", row_id=actors["ing"], location_id=actors["loc"],
              client_mutated_at=new_cm, fields={"deleted_at": new_cm.isoformat()})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "applied", "row_id": str(actors["ing"])}
        cur = await conn.execute(
            "SELECT deleted_at FROM ingredients WHERE id = %s", (actors["ing"],))
        (deleted_at,) = await cur.fetchone()
        assert deleted_at is not None


async def test_unknown_field_on_insert_needs_attention(pool, actors):
    op = mkop(table="ingredients", row_id=uuid.uuid4(), location_id=actors["loc"],
              client_mutated_at=datetime.now(timezone.utc),
              fields={"name": "Whatever", "base_unit": "lb", "made_up_field": "x"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result["status"] == "needs_attention"


async def test_identity_field_on_update_needs_attention(pool, actors):
    op = mkop(table="recipe_items", row_id=actors["recipe_item"], location_id=actors["loc"],
              client_mutated_at=datetime.now(timezone.utc) + timedelta(seconds=1),
              fields={"ingredient_id": str(uuid.uuid4())})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result["status"] == "needs_attention"


async def test_envelope_location_not_in_org_needs_attention(pool, actors):
    op = mkop(table="ingredients", row_id=uuid.uuid4(), location_id=actors["other_loc"],
              client_mutated_at=datetime.now(timezone.utc),
              fields={"name": "Cross Org", "base_unit": "lb"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "needs_attention",
                           "reason": "location is not in this organization"}


async def test_future_client_mutated_at_needs_attention(pool, actors):
    op = mkop(table="ingredients", row_id=uuid.uuid4(), location_id=actors["loc"],
              client_mutated_at=datetime.now(timezone.utc) + timedelta(minutes=10),
              fields={"name": "Too Soon", "base_unit": "lb"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result["status"] == "needs_attention"


async def test_purchase_insert_referencing_tombstoned_ingredient_needs_attention(
        pool, actors, raw_conn):
    await raw_conn.execute(
        "UPDATE ingredients SET deleted_at = now() WHERE id = %s", (actors["ing"],))
    await raw_conn.commit()
    op = mkop(table="purchases", row_id=uuid.uuid4(), location_id=actors["loc"],
              client_mutated_at=datetime.now(timezone.utc),
              fields={"ingredient_id": str(actors["ing"]), "purchased_on": "2026-07-01",
                      "qty": "10", "unit": "lb", "qty_base_units": "10",
                      "total_price": "32.00"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "needs_attention",
                           "reason": "referenced ingredient is not live"}


async def test_recipe_item_insert_referencing_tombstoned_ingredient_needs_attention(
        pool, actors, raw_conn):
    dead_ing = await make_ingredient(raw_conn, actors["loc"], "Dead Ingredient")
    await raw_conn.execute(
        "UPDATE ingredients SET deleted_at = now() WHERE id = %s", (dead_ing,))
    await raw_conn.commit()
    op = mkop(table="recipe_items", row_id=uuid.uuid4(), location_id=actors["loc"],
              client_mutated_at=datetime.now(timezone.utc),
              fields={"recipe_id": str(actors["recipe"]), "ingredient_id": str(dead_ing),
                      "qty_base_units": "1.0000"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "needs_attention",
                           "reason": "referenced ingredient is not live"}


async def test_recipe_item_insert_referencing_tombstoned_recipe_needs_attention(
        pool, actors, raw_conn):
    dead_recipe = await make_recipe(raw_conn, actors["loc"], "Dead Recipe", "9.99")
    await raw_conn.execute(
        "UPDATE recipes SET deleted_at = now() WHERE id = %s", (dead_recipe,))
    await raw_conn.commit()
    op = mkop(table="recipe_items", row_id=uuid.uuid4(), location_id=actors["loc"],
              client_mutated_at=datetime.now(timezone.utc),
              fields={"recipe_id": str(dead_recipe), "ingredient_id": str(actors["ing"]),
                      "qty_base_units": "1.0000"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        result = await apply_op(conn, actors["acme"], op)
        assert result == {"status": "needs_attention",
                           "reason": "referenced recipe is not live"}


async def test_savepoint_isolation_lets_next_op_apply_after_failure(pool, actors):
    bad_op = mkop(table="ingredients", row_id=uuid.uuid4(), location_id=actors["loc"],
                  client_mutated_at=datetime.now(timezone.utc),
                  fields={"name": "Missing Base Unit"})  # base_unit NOT NULL -> DB error
    good_row_id = uuid.uuid4()
    good_op = mkop(table="ingredients", row_id=good_row_id, location_id=actors["loc"],
                   client_mutated_at=datetime.now(timezone.utc),
                   fields={"name": "Good Ingredient", "base_unit": "lb"})
    async with tenant_connection(pool, {"sub": str(actors["alice"])}) as conn:
        bad_result = await apply_op(conn, actors["acme"], bad_op)
        assert bad_result["status"] == "needs_attention"
        good_result = await apply_op(conn, actors["acme"], good_op)
        assert good_result == {"status": "applied", "row_id": str(good_row_id)}
