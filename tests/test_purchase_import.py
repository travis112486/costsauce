# tests/test_purchase_import.py
"""Task 2 (Phase 1d): CSV purchase import route.

Legacy semantics: product/app.py:673-733 (POST /api/purchases/import).
Frozen interface: .superpowers/sdd/2026-07-27-phase-1d-web-client/task-2-brief.md
"""
from tests.factories import make_ingredient
from tests.test_ingredients_routes import auth


CSV_TWO_ROWS = (
    "item,vendor,date,qty,unit,total\n"
    "Chicken,Test Vendor,2026-07-01,10,kg,55.10\n"
    "Truffle Oil,Gourmet Co,2026-07-02,1,each,25.00\n"
)


async def test_csv_text_matches_and_creates(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Chicken Breast")
    await raw_conn.commit()

    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        data={"csv_text": CSV_TWO_ROWS},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body == {"rows_processed": 2, "created": 1, "matched": 1, "errors": []}

    cur = await raw_conn.execute(
        "SELECT p.total_price::text, p.qty_base_units::text, p.source,"
        "       i.name, i.source, i.category, i.base_unit, i.vendor"
        "  FROM purchases p JOIN ingredients i ON i.id = p.ingredient_id"
        " WHERE p.location_id = %s ORDER BY p.total_price::numeric",
        (s["acme_loc"],))
    rows = await cur.fetchall()
    assert len(rows) == 2
    # Truffle Oil purchase (25.00, created ingredient)
    truffle = rows[0]
    assert truffle == ("25.00", "1.0000", "import", "Truffle Oil", "import",
                       "Imported", "each", "Gourmet Co")
    # Chicken Breast purchase (55.10, matched existing ingredient)
    chicken = rows[1]
    assert chicken[0] == "55.10"
    assert chicken[1] == "22.0462"
    assert chicken[2] == "import"
    assert chicken[3] == "Chicken Breast"
    assert chicken[4] == "manual"       # existing ingredient untouched

    # confirm the matched ingredient really is the pre-existing one
    cur = await raw_conn.execute(
        "SELECT ingredient_id FROM purchases"
        " WHERE location_id = %s AND total_price = '55.10'", (s["acme_loc"],))
    (matched_id,) = await cur.fetchone()
    assert str(matched_id) == str(ing)


async def test_file_upload_variant(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    await make_ingredient(raw_conn, s["acme_loc"], "Chicken Breast")
    await raw_conn.commit()

    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        files={"file": ("p.csv", CSV_TWO_ROWS.encode(), "text/csv")},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    assert r.json() == {"rows_processed": 2, "created": 1, "matched": 1, "errors": []}


async def test_file_wins_over_csv_text(app_client, seeded_biz, raw_conn):
    """Frozen interface: file wins if both are provided."""
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        data={"csv_text": "item,vendor,date,qty,unit,total\n"},  # header-only: 0 rows
        files={"file": ("p.csv",
                        b"item,vendor,date,qty,unit,total\n"
                        b"Truffle Oil,Gourmet Co,2026-07-02,1,each,25.00\n",
                        "text/csv")},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    assert r.json() == {"rows_processed": 1, "created": 1, "matched": 0, "errors": []}


async def test_neither_file_nor_csv_text_is_422(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        data={},
        headers=auth(s["alice"]))
    assert r.status_code == 422, r.text


async def test_missing_column_is_400(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        data={"csv_text": "item,vendor,date,qty,unit\nChicken,V,2026-07-01,1,lb\n"},
        headers=auth(s["alice"]))
    assert r.status_code == 400
    assert "total" in r.json()["detail"]


async def test_bad_date_row_reports_correct_row_number(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    csv_text = (
        "item,vendor,date,qty,unit,total\n"
        "Flour,Vendor A,2026-07-01,10,lb,20.00\n"
        "Sugar,Vendor B,not-a-date,5,lb,10.00\n"
        "Salt,Vendor C,2026-07-03,2,lb,4.00\n"
    )
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        data={"csv_text": csv_text},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["rows_processed"] == 3
    assert body["created"] == 2          # Flour and Salt land; Sugar's row failed
    assert body["matched"] == 0
    assert len(body["errors"]) == 1
    assert body["errors"][0]["row"] == 3          # header=1, first data row=2

    cur = await raw_conn.execute(
        "SELECT count(*) FROM ingredients WHERE location_id = %s AND name = 'Sugar'",
        (s["acme_loc"],))
    assert (await cur.fetchone())[0] == 0, "failed row must not leak a created ingredient"
    cur = await raw_conn.execute(
        "SELECT count(*) FROM purchases WHERE location_id = %s", (s["acme_loc"],))
    assert (await cur.fetchone())[0] == 2


async def test_duplicate_new_name_in_one_csv_creates_once(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    csv_text = (
        "item,vendor,date,qty,unit,total\n"
        "Saffron,Vendor A,2026-07-01,1,each,50.00\n"
        "saffron,Vendor A,2026-07-02,2,each,90.00\n"
    )
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        data={"csv_text": csv_text},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body == {"rows_processed": 2, "created": 1, "matched": 1, "errors": []}

    cur = await raw_conn.execute(
        "SELECT count(*) FROM ingredients"
        " WHERE location_id = %s AND name ILIKE 'saffron'", (s["acme_loc"],))
    assert (await cur.fetchone())[0] == 1
    cur = await raw_conn.execute(
        "SELECT count(*) FROM purchases WHERE location_id = %s", (s["acme_loc"],))
    assert (await cur.fetchone())[0] == 2


async def test_non_member_is_404(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        data={"csv_text": "item,vendor,date,qty,unit,total\n"},
        headers=auth(s["bob"]))
    assert r.status_code == 404


async def test_header_only_csv_is_zeros(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/purchases/import",
        data={"csv_text": "item,vendor,date,qty,unit,total\n"},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    assert r.json() == {"rows_processed": 0, "created": 0, "matched": 0, "errors": []}
