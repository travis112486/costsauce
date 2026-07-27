from tests.factories import (
    make_ingredient, make_location, make_purchase, make_recipe, add_recipe_item,
)
from tests.test_auth import mint


def auth(user_id):
    return {"Authorization": f"Bearer {mint(sub=str(user_id))}"}


async def test_create_list_and_duplicate(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/ingredients",
        json={"name": "Chicken Breast", "base_unit": "lb",
              "vendor": "Northgate Provisions"},
        headers=auth(s["alice"]))
    assert r.status_code == 201, r.text
    r2 = await app_client.post(
        f"/locations/{s['acme_loc']}/ingredients",
        json={"name": "chicken breasts", "base_unit": "lb"},
        headers=auth(s["alice"]))
    assert r2.status_code == 409
    assert r2.json()["detail"]["matches"][0]["name"] == "Chicken Breast"
    r3 = await app_client.get(f"/locations/{s['acme_loc']}/ingredients",
                              headers=auth(s["alice"]))
    assert [i["name"] for i in r3.json()] == ["Chicken Breast"]


async def test_match_endpoint(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    await make_ingredient(raw_conn, s["acme_loc"], "Chicken Breast")
    await raw_conn.commit()
    r = await app_client.get(
        f"/locations/{s['acme_loc']}/ingredients/match", params={"name": "chkn"},
        headers=auth(s["alice"]))
    assert r.json()["match"] is None
    r = await app_client.get(
        f"/locations/{s['acme_loc']}/ingredients/match", params={"name": "breast"},
        headers=auth(s["alice"]))
    assert r.json()["match"]["type"] == "fuzzy"


async def test_cross_org_is_404(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.get(f"/locations/{s['acme_loc']}/ingredients",
                             headers=auth(s["bob"]))
    assert r.status_code == 404


async def test_tombstone_and_in_use_guard(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Cheddar")
    rec = await make_recipe(raw_conn, s["acme_loc"], "Burger", "11.00")
    await add_recipe_item(raw_conn, s["acme_loc"], rec, ing, "0.25")
    free = await make_ingredient(raw_conn, s["acme_loc"], "Saffron")
    await raw_conn.commit()
    r = await app_client.delete(
        f"/locations/{s['acme_loc']}/ingredients/{ing}", headers=auth(s["alice"]))
    assert r.status_code == 409                      # in use
    r = await app_client.delete(
        f"/locations/{s['acme_loc']}/ingredients/{free}", headers=auth(s["alice"]))
    assert r.status_code == 204
    cur = await raw_conn.execute(
        "SELECT deleted_at IS NOT NULL FROM ingredients WHERE id = %s", (free,))
    assert (await cur.fetchone())[0] is True
    r = await app_client.delete(
        f"/locations/{s['acme_loc']}/ingredients/{free}", headers=auth(s["alice"]))
    assert r.status_code == 404                      # already gone


async def test_history_ordering(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Limes")
    await make_purchase(raw_conn, s["acme_loc"], ing, "2026-07-01",
                        qty_base_units="10", total_price="20.00",
                        recorded_at="2026-07-01T08:00:00+00:00")
    await make_purchase(raw_conn, s["acme_loc"], ing, "2026-07-01",
                        qty_base_units="10", total_price="30.00",
                        recorded_at="2026-07-01T09:00:00+00:00")
    await make_purchase(raw_conn, s["acme_loc"], ing, "2026-06-01",
                        qty_base_units="10", total_price="10.00")
    await raw_conn.commit()
    r = await app_client.get(
        f"/locations/{s['acme_loc']}/ingredients/{ing}/history",
        headers=auth(s["alice"]))
    prices = [p["total_price"] for p in r.json()["purchases"]]
    assert prices == ["30.00", "20.00", "10.00"]     # rule, not insertion order
    assert r.json()["purchases"][0]["unit_price"] == "3.000000"


async def test_delete_in_use_guard_is_scoped_to_location(app_client, seeded_biz, raw_conn):
    """Self-review regression: a same-org, different-location ingredient's
    in-use state must not leak into this location's 409/404 decision.

    acme2 is a second location in Alice's own org. `ing` lives there and is
    in use by a recipe there. Deleting the SAME ingredient_id through
    acme_loc's URL must 404 (ingredient not found at this location) rather
    than 409 (in use) -- 409 would mean the guard read acme2's recipe_items
    without location scoping."""
    s = seeded_biz
    acme2 = await make_location(raw_conn, s["acme"], "Acme Second")
    ing = await make_ingredient(raw_conn, acme2, "Truffle Oil")
    rec = await make_recipe(raw_conn, acme2, "Risotto", "22.00")
    await add_recipe_item(raw_conn, acme2, rec, ing, "0.10")
    await raw_conn.commit()
    r = await app_client.delete(
        f"/locations/{s['acme_loc']}/ingredients/{ing}", headers=auth(s["alice"]))
    assert r.status_code == 404
