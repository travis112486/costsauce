# tests/test_merge.py
import pytest
from tests.factories import (
    make_user, add_member, make_ingredient, make_purchase, make_recipe,
    add_recipe_item)
from tests.test_ingredients_routes import auth


@pytest.fixture
async def merge_setup(seeded_biz, raw_conn):
    s = seeded_biz
    keep = await make_ingredient(raw_conn, s["acme_loc"], "Chicken Breast")
    lose = await make_ingredient(raw_conn, s["acme_loc"], "chkn brst")
    await make_purchase(raw_conn, s["acme_loc"], lose, "2026-07-01",
                        qty_base_units="10", total_price="32.00")
    await make_purchase(raw_conn, s["acme_loc"], keep, "2026-06-01",
                        qty_base_units="10", total_price="30.00")
    await raw_conn.commit()
    return dict(s, keep=keep, lose=lose)


async def test_merge_repoints_and_tombstones(app_client, merge_setup, raw_conn):
    m = merge_setup
    r = await app_client.post(
        f"/locations/{m['acme_loc']}/ingredients/{m['keep']}/merge",
        json={"from_id": str(m["lose"])}, headers=auth(m["alice"]))
    assert r.status_code == 200, r.text
    assert r.json()["repointed_purchases"] == 1
    cur = await raw_conn.execute(
        "SELECT count(*) FROM purchases WHERE ingredient_id = %s", (m["keep"],))
    assert (await cur.fetchone())[0] == 2
    cur = await raw_conn.execute(
        "SELECT deleted_at IS NOT NULL FROM ingredients WHERE id = %s",
        (m["lose"],))
    assert (await cur.fetchone())[0] is True


async def test_merge_sums_colliding_recipe_lines(app_client, merge_setup, raw_conn):
    m = merge_setup
    rec = await make_recipe(raw_conn, m["acme_loc"], "Club Sandwich", "14.00")
    await add_recipe_item(raw_conn, m["acme_loc"], rec, m["keep"], "0.2500")
    await add_recipe_item(raw_conn, m["acme_loc"], rec, m["lose"], "0.5000")
    other = await make_recipe(raw_conn, m["acme_loc"], "Wrap", "9.00")
    await add_recipe_item(raw_conn, m["acme_loc"], other, m["lose"], "0.3000")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{m['acme_loc']}/ingredients/{m['keep']}/merge",
        json={"from_id": str(m["lose"])}, headers=auth(m["alice"]))
    assert r.json()["combined_items"] == 1
    assert r.json()["repointed_items"] == 1
    cur = await raw_conn.execute(
        "SELECT qty_base_units::text FROM recipe_items"
        " WHERE recipe_id = %s AND ingredient_id = %s AND deleted_at IS NULL",
        (rec, m["keep"]))
    assert (await cur.fetchone())[0] == "0.7500"     # plate cost preserved
    cur = await raw_conn.execute(
        "SELECT ingredient_id = %s FROM recipe_items"
        " WHERE recipe_id = %s AND deleted_at IS NULL", (m["keep"], other))
    assert (await cur.fetchone())[0] is True


async def test_bookkeeper_gets_403(app_client, merge_setup, raw_conn):
    m = merge_setup
    dave = await make_user(raw_conn, "dave@acme.test")
    await add_member(raw_conn, dave, m["acme"], "bookkeeper")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{m['acme_loc']}/ingredients/{m['keep']}/merge",
        json={"from_id": str(m["lose"])}, headers=auth(dave))
    assert r.status_code == 403


async def test_self_merge_and_foreign_merge(app_client, merge_setup, raw_conn):
    m = merge_setup
    r = await app_client.post(
        f"/locations/{m['acme_loc']}/ingredients/{m['keep']}/merge",
        json={"from_id": str(m["keep"])}, headers=auth(m["alice"]))
    assert r.status_code == 400
    theirs = await make_ingredient(raw_conn, m["bistro_loc"], "Their Chicken")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{m['acme_loc']}/ingredients/{m['keep']}/merge",
        json={"from_id": str(theirs)}, headers=auth(m["alice"]))
    assert r.status_code == 404
