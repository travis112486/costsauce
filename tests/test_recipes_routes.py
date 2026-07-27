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


async def test_create_with_item_id_is_422(app_client, seeded_biz, raw_conn):
    """Interface contract: 'items on create must NOT carry ids'. A client
    that echoes an id from some other recipe (or fabricates one) on create
    must be rejected, not silently accepted as if it were an update."""
    s = seeded_biz
    beef = await seed_priced(raw_conn, s["acme_loc"], "Ground Beef", "45.00")
    await raw_conn.commit()
    fake_id = "019fa422-1bf6-7760-83c9-e002b3ea35f6"
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Burger", "menu_price": "11.00",
              "items": [{"id": fake_id, "ingredient_id": str(beef),
                         "qty_base_units": "0.5000"}]},
        headers=auth(s["alice"]))
    assert r.status_code == 422, r.text
    cur = await raw_conn.execute(
        "SELECT count(*) FROM recipes WHERE location_id = %s", (s["acme_loc"],))
    assert (await cur.fetchone())[0] == 0             # no orphaned recipe row


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
    # kept's qty is changed to 0.6000 and the recipe is renamed in the SAME
    # request that also tries to sneak in a duplicate-ingredient insert.
    # Self-review: the whole PUT must roll back on the 409, not just skip
    # the failing insert -- otherwise the update-in-place half of the diff
    # would silently commit while the client sees an error.
    r2 = await app_client.put(
        f"/locations/{s['acme_loc']}/recipes/{rid}",
        json={"name": "Cheeseburger", "menu_price": "11.00",
              "target_fc_pct": "30.00",
              "items": [{"id": kept, "ingredient_id": str(beef),
                         "qty_base_units": "0.6000"},
                        {"ingredient_id": str(beef), "qty_base_units": "0.2500"}]},
        headers=auth(s["alice"]))
    assert r2.status_code == 409
    cur = await raw_conn.execute(
        "SELECT name FROM recipes WHERE id = %s", (rid,))
    assert (await cur.fetchone())[0] == "Burger"      # rename rolled back
    cur = await raw_conn.execute(
        "SELECT qty_base_units FROM recipe_items"
        " WHERE id = %s", (kept,))
    assert str((await cur.fetchone())[0]) == "0.5000"  # qty update rolled back
    cur = await raw_conn.execute(
        "SELECT count(*) FROM recipe_items WHERE recipe_id = %s"
        " AND deleted_at IS NULL", (rid,))
    assert (await cur.fetchone())[0] == 1              # no duplicate live row


async def test_tombstoned_ingredient_cannot_be_added_to_recipe(app_client, seeded_biz,
                                                                raw_conn):
    """A tombstoned ingredient (e.g. a merge loser re-added by a stale
    client) must not be attachable to a recipe -- `_insert_item`'s
    existence check has to exclude deleted rows, or the recipe saves 200
    with a permanently incomplete line (the tombstoned ingredient never
    shows up in costing/listing again)."""
    s = seeded_biz
    beef = await seed_priced(raw_conn, s["acme_loc"], "Ground Beef", "45.00")
    gone = await make_ingredient(raw_conn, s["acme_loc"], "Discontinued Sauce")
    await raw_conn.execute(
        "UPDATE ingredients SET deleted_at = now() WHERE id = %s", (gone,))
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Burger", "menu_price": "11.00",
              "items": [{"ingredient_id": str(beef), "qty_base_units": "0.5000"},
                        {"ingredient_id": str(gone), "qty_base_units": "0.1000"}]},
        headers=auth(s["alice"]))
    assert r.status_code == 404, r.text
    cur = await raw_conn.execute(
        "SELECT count(*) FROM recipes WHERE location_id = %s", (s["acme_loc"],))
    assert (await cur.fetchone())[0] == 0             # whole create rolled back

    # Also exercised on PUT: an existing recipe must not gain a tombstoned
    # ingredient line either.
    r2 = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Burger", "menu_price": "11.00",
              "items": [{"ingredient_id": str(beef), "qty_base_units": "0.5000"}]},
        headers=auth(s["alice"]))
    rid = r2.json()["recipe_id"]
    beef_item_id = r2.json()["items"][0]["id"]
    r3 = await app_client.put(
        f"/locations/{s['acme_loc']}/recipes/{rid}",
        json={"name": "Burger", "menu_price": "11.00", "target_fc_pct": "30.00",
              "items": [{"id": beef_item_id, "ingredient_id": str(beef),
                         "qty_base_units": "0.5000"},
                        {"ingredient_id": str(gone), "qty_base_units": "0.1000"}]},
        headers=auth(s["alice"]))
    assert r3.status_code == 404, r3.text


async def test_bookkeeper_cannot_write_recipes_gets_403(app_client, seeded_biz, raw_conn):
    """A bookkeeper's write hits the `recipe_write` RLS policy's WITH CHECK
    (owner/manager only) and gets denied at SQLSTATE 42501
    InsufficientPrivilege. api/main.py must map that to a clean 403, not let
    it propagate through the psycopg.Error handler (which only knows about
    migration 0007's CS410) into an API 500."""
    from tests.factories import make_user, add_member
    s = seeded_biz
    beef = await seed_priced(raw_conn, s["acme_loc"], "Ground Beef", "45.00")
    dave = await make_user(raw_conn, "dave@acme.test")
    await add_member(raw_conn, dave, s["acme"], "bookkeeper")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Burger", "menu_price": "11.00",
              "items": [{"ingredient_id": str(beef), "qty_base_units": "0.5000"}]},
        headers=auth(dave))
    assert r.status_code == 403, r.text
    assert r.json()["detail"] == "insufficient role for this action"


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
