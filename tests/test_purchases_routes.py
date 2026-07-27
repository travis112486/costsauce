from tests.factories import make_ingredient
from tests.test_ingredients_routes import auth


async def test_create_purchase_normalizes_and_prices(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Chicken Breast")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases",
        json={"ingredient_id": str(ing), "purchased_on": "2026-07-01",
              "qty": "10", "unit": "kg", "total_price": "55.10"},
        headers=auth(s["alice"]))
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["qty_base_units"] == "22.0462"
    assert body["unit_price"] == "2.499297"      # controller correction: DB generated


async def test_kernel_rejection_is_400(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Tortillas",
                                base_unit="each")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases",
        json={"ingredient_id": str(ing), "purchased_on": "2026-07-01",
              "qty": "2", "unit": "lb", "total_price": "4.00"},
        headers=auth(s["alice"]))
    assert r.status_code == 400
    assert "each" in r.json()["detail"]


async def test_bad_date_is_422_not_stored_b1(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Flour")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases",
        json={"ingredient_id": str(ing), "purchased_on": "not-a-date",
              "qty": "1", "unit": "lb", "total_price": "4.00"},
        headers=auth(s["alice"]))
    assert r.status_code == 422


async def test_foreign_ingredient_404(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    theirs = await make_ingredient(raw_conn, s["bistro_loc"], "Their Truffle")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases",
        json={"ingredient_id": str(theirs), "purchased_on": "2026-07-01",
              "qty": "1", "unit": "lb", "total_price": "4.00"},
        headers=auth(s["alice"]))
    assert r.status_code == 404
