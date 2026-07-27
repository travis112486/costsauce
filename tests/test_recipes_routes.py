from tests.factories import make_ingredient, make_purchase
from tests.test_ingredients_routes import auth


async def seed_priced(raw_conn, loc, name, price):
    ing = await make_ingredient(raw_conn, loc, name)
    for d in ("2026-05-01", "2026-05-15", "2026-06-01", "2026-07-01"):
        await make_purchase(raw_conn, loc, ing, d,
                            qty_base_units="10", total_price=price)
    return ing


async def test_create_and_get_costed(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    beef = await seed_priced(raw_conn, s["acme_loc"], "Ground Beef", "45.00")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Burger", "menu_price": "11.00",
              "items": [{"ingredient_id": str(beef), "qty_base_units": "0.5000"}]},
        headers=auth(s["alice"]))
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["plate_cost"] == "2.25"          # 0.5 x 4.500000
    assert body["fc_pct"] == "20.5"              # 2.25/11.00 -> 20.4545 -> 20.5
    assert body["status"] == "ok"


async def test_put_is_upsert_diff_not_delete_reinsert(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    beef = await seed_priced(raw_conn, s["acme_loc"], "Ground Beef", "45.00")
    bun = await seed_priced(raw_conn, s["acme_loc"], "Brioche Bun", "12.00")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Burger", "menu_price": "11.00",
              "items": [{"ingredient_id": str(beef), "qty_base_units": "0.5000"},
                        {"ingredient_id": str(bun), "qty_base_units": "1.0000"}]},
        headers=auth(s["alice"]))
    rid = r.json()["recipe_id"]
    items = {i["name"]: i for i in r.json()["items"]}
    beef_item_id = items["Ground Beef"]["id"]
    # update beef qty in place, DROP the bun, round-trip the id
    r2 = await app_client.put(
        f"/locations/{s['acme_loc']}/recipes/{rid}",
        json={"name": "Burger", "menu_price": "11.00", "target_fc_pct": "30.00",
              "items": [{"id": beef_item_id, "ingredient_id": str(beef),
                         "qty_base_units": "0.7500"}]},
        headers=auth(s["alice"]))
    assert r2.status_code == 200, r2.text
    assert [i["id"] for i in r2.json()["items"]] == [beef_item_id]  # in place
    cur = await raw_conn.execute(
        "SELECT count(*) FROM recipe_items WHERE recipe_id = %s"
        " AND deleted_at IS NOT NULL", (rid,))
    assert (await cur.fetchone())[0] == 1        # bun tombstoned, not deleted


async def test_put_conflict_on_duplicate_live_ingredient(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    beef = await seed_priced(raw_conn, s["acme_loc"], "Ground Beef", "45.00")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Burger", "menu_price": "11.00",
              "items": [{"ingredient_id": str(beef), "qty_base_units": "0.5000"}]},
        headers=auth(s["alice"]))
    rid = r.json()["recipe_id"]
    kept = r.json()["items"][0]["id"]
    r2 = await app_client.put(
        f"/locations/{s['acme_loc']}/recipes/{rid}",
        json={"name": "Burger", "menu_price": "11.00", "target_fc_pct": "30.00",
              "items": [{"id": kept, "ingredient_id": str(beef),
                         "qty_base_units": "0.5000"},
                        {"ingredient_id": str(beef), "qty_base_units": "0.2500"}]},
        headers=auth(s["alice"]))
    assert r2.status_code == 409


async def test_delete_tombstones_recipe_and_items(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    beef = await seed_priced(raw_conn, s["acme_loc"], "Ground Beef", "45.00")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Burger", "menu_price": "11.00",
              "items": [{"ingredient_id": str(beef), "qty_base_units": "0.5000"}]},
        headers=auth(s["alice"]))
    rid = r.json()["recipe_id"]
    r2 = await app_client.delete(f"/locations/{s['acme_loc']}/recipes/{rid}",
                                 headers=auth(s["alice"]))
    assert r2.status_code == 204
    r3 = await app_client.get(f"/locations/{s['acme_loc']}/recipes",
                              headers=auth(s["alice"]))
    assert r3.json() == []
