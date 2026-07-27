"""Does migration 0012's schema half hold the money contract?

Everything here runs on raw_conn (superuser): this file tests columns,
checks, and the generated unit_price — not policies. Policies are Task 2.
"""
from decimal import Decimal
import psycopg
import pytest
from tests.conftest import apply_migrations
from tests.factories import (
    make_org, make_location, make_ingredient, make_purchase,
    make_recipe, add_recipe_item,
)


@pytest.fixture
async def biz(raw_conn):
    await apply_migrations(raw_conn, upto=12)
    org = await make_org(raw_conn, "Acme Diner")
    loc = await make_location(raw_conn, org, "Acme Main")
    await raw_conn.commit()
    return dict(org=org, loc=loc)


async def test_unit_price_is_generated_6dp_half_away(raw_conn, biz):
    ing = await make_ingredient(raw_conn, biz["loc"], "Chicken Breast")
    pid = await make_purchase(
        raw_conn, biz["loc"], ing, "2026-07-01",
        qty_base_units="22.0462", total_price="55.10")
    cur = await raw_conn.execute(
        "SELECT unit_price FROM purchases WHERE id = %s", (pid,))
    (up,) = await cur.fetchone()
    # 55.10 / 22.0462 = 2.4992969... -> 2.499297
    assert up == Decimal("2.499297")


async def test_unit_price_cannot_be_written_directly(raw_conn, biz):
    ing = await make_ingredient(raw_conn, biz["loc"], "Limes")
    with pytest.raises(psycopg.errors.GeneratedAlways):
        await raw_conn.execute(
            "INSERT INTO purchases (location_id, ingredient_id, purchased_on,"
            " qty, unit, qty_base_units, total_price, unit_price)"
            " VALUES (%s, %s, '2026-07-01', 1, 'lb', 1, 1, 999)",
            (biz["loc"], ing))
    await raw_conn.rollback()


@pytest.mark.parametrize("qbu,tp,error_type", [
    ("0", "5.00", psycopg.errors.DivisionByZero),
    ("-1", "5.00", psycopg.errors.CheckViolation),
    ("10", "0", psycopg.errors.CheckViolation),
    ("10", "-0.01", psycopg.errors.CheckViolation),
])
async def test_positive_checks_reject(raw_conn, biz, qbu, tp, error_type):
    ing = await make_ingredient(raw_conn, biz["loc"], "Flour")
    with pytest.raises(error_type):
        await make_purchase(raw_conn, biz["loc"], ing, "2026-07-01",
                            qty_base_units=qbu, total_price=tp)
    await raw_conn.rollback()


async def test_live_duplicate_recipe_item_rejected_tombstoned_ok(raw_conn, biz):
    ing = await make_ingredient(raw_conn, biz["loc"], "Cheddar")
    rec = await make_recipe(raw_conn, biz["loc"], "Burger", "11.00")
    item = await add_recipe_item(raw_conn, biz["loc"], rec, ing, "0.25")
    await raw_conn.commit()  # Commit successful inserts before testing duplicate rejection
    with pytest.raises(psycopg.errors.UniqueViolation):
        await add_recipe_item(raw_conn, biz["loc"], rec, ing, "0.50")
    await raw_conn.rollback()
    # re-adding after a tombstone is legal: the unique index is partial
    await raw_conn.execute(
        "UPDATE recipe_items SET deleted_at = now() WHERE id = %s", (item,))
    await add_recipe_item(raw_conn, biz["loc"], rec, ing, "0.50")


async def test_org_hard_delete_cascades_through_business_tables(raw_conn, biz):
    ing = await make_ingredient(raw_conn, biz["loc"], "Cod Fillet")
    await make_purchase(raw_conn, biz["loc"], ing, "2026-07-01",
                        qty_base_units="10", total_price="75.00")
    rec = await make_recipe(raw_conn, biz["loc"], "Fish & Chips", "16.00")
    await add_recipe_item(raw_conn, biz["loc"], rec, ing, "0.5")
    await raw_conn.execute("DELETE FROM organizations WHERE id = %s", (biz["org"],))
    for t in ("ingredients", "purchases", "recipes", "recipe_items"):
        cur = await raw_conn.execute(f"SELECT count(*) FROM {t}")
        assert (await cur.fetchone())[0] == 0, f"{t} survived the org cascade"


async def test_base_unit_check(raw_conn, biz):
    with pytest.raises(psycopg.errors.CheckViolation):
        await make_ingredient(raw_conn, biz["loc"], "Mystery", base_unit="stone")
    await raw_conn.rollback()
