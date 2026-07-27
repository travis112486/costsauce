from tests.factories import (
    make_ingredient, make_purchase, make_recipe, add_recipe_item)
from tests.test_ingredients_routes import auth


async def seed_drifting_lime(raw_conn, loc):
    """Lime at $1.00/unit baseline x3, latest $1.31 -> +31.0%."""
    ing = await make_ingredient(raw_conn, loc, "Limes")
    for d in ("2026-05-01", "2026-05-15", "2026-06-01"):
        await make_purchase(raw_conn, loc, ing, d,
                            qty_base_units="10", total_price="10.00")
    await make_purchase(raw_conn, loc, ing, "2026-07-01",
                        qty_base_units="10", total_price="13.10")
    return ing


async def test_dashboard_alerts_and_movers(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    await seed_drifting_lime(raw_conn, s["acme_loc"])
    flat = await make_ingredient(raw_conn, s["acme_loc"], "Flour")
    for d in ("2026-05-01", "2026-05-15", "2026-06-01", "2026-07-01"):
        await make_purchase(raw_conn, s["acme_loc"], flat, d,
                            qty_base_units="10", total_price="10.00")
    sparse = await make_ingredient(raw_conn, s["acme_loc"], "Saffron")
    await make_purchase(raw_conn, s["acme_loc"], sparse, "2026-07-01",
                        qty_base_units="1", total_price="9.00")
    await raw_conn.commit()
    r = await app_client.get(f"/locations/{s['acme_loc']}/dashboard",
                             headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert [a["name"] for a in body["alerts"]] == ["Limes"]
    assert body["alerts"][0]["drift_pct"] == "31.0"
    mover_names = [m["name"] for m in body["top_movers"]]
    assert "Saffron" not in mover_names          # below baseline floor
    assert body["summary"]["total_alerts"] == 1


async def test_dashboard_menu_items_and_summary(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    lime = await seed_drifting_lime(raw_conn, s["acme_loc"])
    rec = await make_recipe(raw_conn, s["acme_loc"], "Margarita Special",
                            "10.00", target_fc_pct="30.00")
    await add_recipe_item(raw_conn, s["acme_loc"], rec, lime, "2.0000")
    await raw_conn.commit()
    r = await app_client.get(f"/locations/{s['acme_loc']}/dashboard",
                             headers=auth(s["alice"]))
    item = r.json()["menu_items"][0]
    # plate = 2.0 x 1.310000 = 2.62 ; fc = 26.2% ; suggested:
    # ceildiv(262*10000, 3000*50)*50 = 18*50 = 900 cents
    assert item["plate_cost"] == "2.62"
    assert item["fc_pct"] == "26.2"
    assert item["status"] == "ok"
    assert item["suggested_price"] == "9.00"
    assert item["complete"] is True


async def test_completeness_contract_no_reprice_from_partial(
        app_client, seeded_biz, raw_conn):
    s = seeded_biz
    lime = await seed_drifting_lime(raw_conn, s["acme_loc"])
    ghost = await make_ingredient(raw_conn, s["acme_loc"], "Ghost Pepper")
    rec = await make_recipe(raw_conn, s["acme_loc"], "Haunted Taco", "12.00")
    await add_recipe_item(raw_conn, s["acme_loc"], rec, lime, "1.0000")
    await add_recipe_item(raw_conn, s["acme_loc"], rec, ghost, "0.1000")
    await raw_conn.commit()
    r = await app_client.get(f"/locations/{s['acme_loc']}/dashboard",
                             headers=auth(s["alice"]))
    item = r.json()["menu_items"][0]
    assert item["complete"] is False
    assert item["status"] is None
    assert item["suggested_price"] is None
    assert item["fc_pct"] is None
    assert item["plate_cost"] == "1.31"        # resolvable part, still honest
    flags = {i["name"]: i["is_resolvable"] for i in item["items"]}
    assert flags == {"Limes": True, "Ghost Pepper": False}
    assert r.json()["summary"]["incomplete_count"] == 1
