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


async def test_underflow_to_zero_is_400_not_500(app_client, seeded_biz, raw_conn):
    """A qty so tiny it rounds to 0.0000 base units at 4dp must be rejected
    by the kernel with a 400, not inserted -- the DB's generated unit_price
    column is round(total/qty_base_units, 6), so a stored zero would divide
    by zero before the CHECK constraint ever fires, and psycopg's raw
    DivisionByZero would surface as an API 500."""
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Saffron")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases",
        json={"ingredient_id": str(ing), "purchased_on": "2026-07-01",
              "qty": "0.00001", "unit": "g", "total_price": "4.00"},
        headers=auth(s["alice"]))
    assert r.status_code == 400, r.text
    cur = await raw_conn.execute(
        "SELECT count(*) FROM purchases WHERE ingredient_id = %s", (ing,))
    assert (await cur.fetchone())[0] == 0


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
