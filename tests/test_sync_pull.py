# tests/test_sync_pull.py
"""GET /sync: page-capped cursor pull, tombstones included (Task 7, spec §5).

Covers: route-created rows showing up in the pull with correct table tags
and string-typed money (never floats -- the money contract), global seq
ordering across all four tables, an exhausted cursor returning empty with
has_more False, tombstoned rows still appearing (deleted_at non-null,
never omitted), a page-cap walk across several pages with no gaps or
duplicates and chained cursors, 404 for a non-member org (same
indistinguishable-from-unknown rule as POST /sync), a deletion-scheduled
org still allowing reads (only writes are frozen), and strict per-org
isolation (bistro rows never leaking into an acme pull).
"""
import uuid
from datetime import datetime, timezone

from tests.factories import make_ingredient
from tests.test_auth import mint
from tests.test_sync_push import op, push
from api.services import sync as svc


def auth(user_id):
    return {"Authorization": f"Bearer {mint(sub=str(user_id))}"}


async def pull(app_client, org_id, *, actor, since=0):
    return await app_client.get(
        "/sync",
        params={"org_id": str(org_id), "since": since},
        headers=auth(actor),
    )


# ---------------------------------------------------------------------------
# Basic visibility + money contract
# ---------------------------------------------------------------------------

async def test_route_created_row_appears_with_table_tag_and_string_money(
        app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Flour")
    await raw_conn.commit()

    purchase_op = op("purchases", location_id=s["acme_loc"], fields={
        "ingredient_id": str(ing), "purchased_on": "2026-07-01",
        "qty": "5", "unit": "lb", "qty_base_units": "5.0000",
        "total_price": "20.00",
    })
    r = await push(app_client, s["acme"], [purchase_op], actor=s["alice"])
    assert r.status_code == 200, r.text
    assert r.json()["results"][0]["status"] == "applied"

    r2 = await pull(app_client, s["acme"], actor=s["alice"])
    assert r2.status_code == 200, r2.text
    body = r2.json()
    purchases = [c for c in body["changes"] if c["table"] == "purchases"]
    assert len(purchases) == 1
    row = purchases[0]["row"]
    assert row["id"] == purchase_op["row_id"]
    assert isinstance(row["total_price"], str)
    assert row["total_price"] == "20.00"
    assert isinstance(row["qty_base_units"], str)
    assert isinstance(row["server_seq"], int)


# ---------------------------------------------------------------------------
# Global seq ordering across tables
# ---------------------------------------------------------------------------

async def test_global_seq_ordering_across_tables(app_client, seeded_biz):
    s = seeded_biz
    ops = [
        op("ingredients", location_id=s["acme_loc"], fields={"name": "Salt", "base_unit": "oz"}),
        op("recipes", location_id=s["acme_loc"], fields={"name": "Soup", "menu_price": "8.00"}),
        op("ingredients", location_id=s["acme_loc"], fields={"name": "Pepper", "base_unit": "oz"}),
    ]
    r = await push(app_client, s["acme"], ops, actor=s["alice"])
    assert r.status_code == 200, r.text

    r2 = await pull(app_client, s["acme"], actor=s["alice"])
    assert r2.status_code == 200, r2.text
    changes = r2.json()["changes"]
    seqs = [c["row"]["server_seq"] for c in changes]
    assert seqs == sorted(seqs)
    assert len(set(seqs)) == len(seqs)


# ---------------------------------------------------------------------------
# Cursor exhaustion
# ---------------------------------------------------------------------------

async def test_since_cursor_returns_empty_and_has_more_false(app_client, seeded_biz):
    s = seeded_biz
    o = op("ingredients", location_id=s["acme_loc"], fields={"name": "Sugar", "base_unit": "lb"})
    r = await push(app_client, s["acme"], [o], actor=s["alice"])
    assert r.status_code == 200, r.text

    r2 = await pull(app_client, s["acme"], actor=s["alice"])
    cursor = r2.json()["cursor"]
    assert r2.json()["has_more"] is False

    r3 = await pull(app_client, s["acme"], actor=s["alice"], since=cursor)
    assert r3.status_code == 200, r3.text
    body3 = r3.json()
    assert body3["changes"] == []
    assert body3["has_more"] is False
    assert body3["cursor"] == cursor


# ---------------------------------------------------------------------------
# Tombstones
# ---------------------------------------------------------------------------

async def test_tombstoned_ingredient_appears_with_deleted_at(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing_id = uuid.uuid4()
    insert_op = op("ingredients", row_id=ing_id, location_id=s["acme_loc"],
                   fields={"name": "Basil", "base_unit": "oz"})
    r = await push(app_client, s["acme"], [insert_op], actor=s["alice"])
    assert r.status_code == 200, r.text

    delete_op = op("ingredients", row_id=ing_id, location_id=s["acme_loc"],
                   fields={"deleted_at": datetime.now(timezone.utc).isoformat()},
                   client_mutated_at=datetime.now(timezone.utc))
    r2 = await push(app_client, s["acme"], [delete_op], actor=s["alice"])
    assert r2.status_code == 200, r2.text
    assert r2.json()["results"][0]["status"] == "applied"

    r3 = await pull(app_client, s["acme"], actor=s["alice"])
    assert r3.status_code == 200, r3.text
    ingredients = [c for c in r3.json()["changes"]
                   if c["table"] == "ingredients" and c["row"]["id"] == str(ing_id)]
    assert len(ingredients) == 1
    assert ingredients[0]["row"]["deleted_at"] is not None


# ---------------------------------------------------------------------------
# Page-cap walk
# ---------------------------------------------------------------------------

async def test_page_cap_walk_no_gaps_or_dupes_and_chained_cursors(
        app_client, seeded_biz, monkeypatch):
    s = seeded_biz
    monkeypatch.setattr(svc, "SYNC_PAGE_CAP", 3)

    ops = [op("ingredients", location_id=s["acme_loc"],
              fields={"name": f"Item {i}", "base_unit": "lb"})
           for i in range(5)]
    r = await push(app_client, s["acme"], ops, actor=s["alice"])
    assert r.status_code == 200, r.text

    seen_ids = []
    since = 0
    pages = 0
    while True:
        r2 = await pull(app_client, s["acme"], actor=s["alice"], since=since)
        assert r2.status_code == 200, r2.text
        body = r2.json()
        pages += 1
        assert len(body["changes"]) <= 3
        seen_ids.extend(c["row"]["id"] for c in body["changes"])
        if not body["has_more"]:
            assert body["cursor"] == since or len(body["changes"]) > 0
            since = body["cursor"]
            break
        assert body["cursor"] != since
        since = body["cursor"]
        assert pages < 10  # guard against an infinite loop on a bug

    assert pages == 2
    assert len(seen_ids) == 5
    assert len(set(seen_ids)) == 5
    expected = {o["row_id"] for o in ops}
    assert set(seen_ids) == expected

    # Cursor is now exhausted: one more pull is empty.
    r3 = await pull(app_client, s["acme"], actor=s["alice"], since=since)
    assert r3.json()["changes"] == []
    assert r3.json()["has_more"] is False


# ---------------------------------------------------------------------------
# Org resolution + tenant isolation
# ---------------------------------------------------------------------------

async def test_non_member_org_is_404(app_client, seeded_biz):
    s = seeded_biz
    r = await pull(app_client, s["bistro"], actor=s["alice"])
    assert r.status_code == 404


async def test_unknown_org_is_404(app_client, seeded_biz):
    s = seeded_biz
    r = await pull(app_client, uuid.uuid4(), actor=s["alice"])
    assert r.status_code == 404


async def test_scheduled_org_still_pulls_200(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    o = op("ingredients", location_id=s["acme_loc"], fields={"name": "Cumin", "base_unit": "oz"})
    r = await push(app_client, s["acme"], [o], actor=s["alice"])
    assert r.status_code == 200, r.text

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() WHERE id = %s",
        (s["acme"],))
    await raw_conn.commit()

    r2 = await pull(app_client, s["acme"], actor=s["alice"])
    assert r2.status_code == 200, r2.text
    assert any(c["row"]["id"] == o["row_id"] for c in r2.json()["changes"])


async def test_bistro_rows_never_in_acme_pull(app_client, seeded_biz):
    s = seeded_biz
    bistro_op = op("ingredients", location_id=s["bistro_loc"],
                   fields={"name": "Bistro Only", "base_unit": "lb"})
    r = await push(app_client, s["bistro"], [bistro_op], actor=s["bob"])
    assert r.status_code == 200, r.text

    acme_op = op("ingredients", location_id=s["acme_loc"],
                fields={"name": "Acme Only", "base_unit": "lb"})
    r2 = await push(app_client, s["acme"], [acme_op], actor=s["alice"])
    assert r2.status_code == 200, r2.text

    r3 = await pull(app_client, s["acme"], actor=s["alice"])
    assert r3.status_code == 200, r3.text
    ids = {c["row"]["id"] for c in r3.json()["changes"]}
    assert acme_op["row_id"] in ids
    assert bistro_op["row_id"] not in ids
