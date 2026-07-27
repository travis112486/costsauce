# tests/test_sync_scenarios.py
"""Scenario suite I (Phase 1c, §5.4/§4.2/§5.3): item-count convergence,
stale loser, replay. These exercise the already-built sync stack
(Tasks 1-7) end to end through the HTTP surface -- a failure here means a
real bug in that stack, not a weak assertion to fix here.
"""
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from tests.test_ingredients_routes import auth
from tests.test_recipes_routes import seed_priced
from tests.test_sync_push import op, push


async def test_two_edits_converge_on_item_count(app_client, seeded_biz, raw_conn):
    """spec §5.4's burger: device B edits a line in place via PUT; device A
    (an offline re-save) pushes INSERT ops with fresh uuids for the SAME
    (recipe, ingredient) pairs, dated later. The canonical (recipe_id,
    ingredient_id) upsert must fold device A's inserts onto the existing
    lines -- never create duplicates -- and the newer writer (A) must win."""
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
    assert r.status_code == 201, r.text
    rid = r.json()["recipe_id"]
    items = {i["ingredient_id"]: i for i in r.json()["items"]}
    beef_item_id = items[str(beef)]["id"]
    bun_item_id = items[str(bun)]["id"]

    # Device B: online edit of the beef line's qty via PUT (update in place).
    r_b = await app_client.put(
        f"/locations/{s['acme_loc']}/recipes/{rid}",
        json={"name": "Burger", "menu_price": "11.00", "target_fc_pct": "30.00",
              "items": [{"id": beef_item_id, "ingredient_id": str(beef),
                         "qty_base_units": "0.4000"},
                        {"id": bun_item_id, "ingredient_id": str(bun),
                         "qty_base_units": "1.0000"}]},
        headers=auth(s["alice"]))
    assert r_b.status_code == 200, r_b.text

    # Device A: was offline since before the recipe even existed, re-saves
    # its own local copy of both lines as fresh INSERT ops with new uuids,
    # timestamped after B's PUT.
    later = datetime.now(timezone.utc) + timedelta(seconds=5)
    beef_op = op("recipe_items", row_id=uuid.uuid4(), location_id=s["acme_loc"],
                 fields={"recipe_id": rid, "ingredient_id": str(beef),
                         "qty_base_units": "0.6000"},
                 client_mutated_at=later)
    bun_op = op("recipe_items", row_id=uuid.uuid4(), location_id=s["acme_loc"],
                fields={"recipe_id": rid, "ingredient_id": str(bun),
                        "qty_base_units": "1.5000"},
                client_mutated_at=later)
    r_a = await push(app_client, s["acme"], [beef_op, bun_op], actor=s["alice"])
    assert r_a.status_code == 200, r_a.text
    results = r_a.json()["results"]

    # Both ops fold onto the pre-existing canonical lines -- fresh uuids are
    # never granted rows of their own.
    assert results[0]["status"] == "applied"
    assert results[0]["row_id"] == beef_item_id
    assert results[1]["status"] == "applied"
    assert results[1]["row_id"] == bun_item_id

    cur = await raw_conn.execute(
        "SELECT count(*) FROM recipe_items WHERE recipe_id = %s AND deleted_at IS NULL",
        (uuid.UUID(rid),))
    assert (await cur.fetchone())[0] == 2   # never 4

    r_get = await app_client.get(f"/locations/{s['acme_loc']}/recipes/{rid}",
                                 headers=auth(s["alice"]))
    assert r_get.status_code == 200, r_get.text
    body = r_get.json()
    by_id = {i["id"]: i for i in body["items"]}
    assert len(body["items"]) == 2
    assert by_id[beef_item_id]["qty_base_units"] == "0.6000"
    assert by_id[bun_item_id]["qty_base_units"] == "1.5000"

    beef_unit = Decimal("45.00") / Decimal("10")
    bun_unit = Decimal("12.00") / Decimal("10")
    beef_cost = (Decimal("0.6000") * beef_unit).quantize(Decimal("0.01"))
    bun_cost = (Decimal("1.5000") * bun_unit).quantize(Decimal("0.01"))
    plate = (beef_cost + bun_cost).quantize(Decimal("0.01"))
    assert by_id[beef_item_id]["cost"] == str(beef_cost)
    assert by_id[bun_item_id]["cost"] == str(bun_cost)
    assert body["plate_cost"] == str(plate)


async def test_stale_thirty_day_edit_loses(app_client, seeded_biz, raw_conn):
    """spec §4.2 anti-case: the newer edit wins even though the stale one
    syncs later in wall-clock time -- LWW is decided by client_mutated_at,
    not arrival order."""
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Soup", "menu_price": "10.00", "items": []},
        headers=auth(s["alice"]))
    assert r.status_code == 201, r.text
    rid = r.json()["recipe_id"]

    r2 = await app_client.put(
        f"/locations/{s['acme_loc']}/recipes/{rid}",
        json={"name": "Soup", "menu_price": "15.00", "target_fc_pct": "30.00",
              "items": []},
        headers=auth(s["alice"]))
    assert r2.status_code == 200, r2.text
    assert r2.json()["menu_price"] == "15.00"

    stale_op = op("recipes", row_id=uuid.UUID(rid), location_id=s["acme_loc"],
                  fields={"menu_price": "11.00"},
                  client_mutated_at=datetime.now(timezone.utc) - timedelta(days=30))
    r3 = await push(app_client, s["acme"], [stale_op], actor=s["alice"])
    assert r3.status_code == 200, r3.text
    result = r3.json()["results"][0]
    assert result["status"] == "stale"
    assert result["reason"] == "older"

    r4 = await app_client.get(f"/locations/{s['acme_loc']}/recipes/{rid}",
                              headers=auth(s["alice"]))
    assert r4.status_code == 200, r4.text
    assert r4.json()["menu_price"] == "15.00"


async def test_replay_after_concurrent_edit(app_client, seeded_biz, raw_conn):
    """A byte-identical replay of an already-ledgered op must return the
    ORIGINAL applied result and touch nothing -- even when a later, distinct
    edit (the PUT to 'Beta') has since moved the row."""
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Soup", "menu_price": "10.00", "items": []},
        headers=auth(s["alice"]))
    assert r.status_code == 201, r.text
    rid = r.json()["recipe_id"]

    rename_op = op("recipes", row_id=uuid.UUID(rid), location_id=s["acme_loc"],
                   fields={"name": "Alpha"},
                   client_mutated_at=datetime.now(timezone.utc) + timedelta(seconds=1))
    r1 = await push(app_client, s["acme"], [rename_op], actor=s["alice"])
    assert r1.status_code == 200, r1.text
    original_result = r1.json()["results"][0]
    assert original_result["status"] == "applied"
    assert original_result["row_id"] == rid

    r2 = await app_client.put(
        f"/locations/{s['acme_loc']}/recipes/{rid}",
        json={"name": "Beta", "menu_price": "10.00", "target_fc_pct": "30.00",
              "items": []},
        headers=auth(s["alice"]))
    assert r2.status_code == 200, r2.text
    assert r2.json()["name"] == "Beta"

    # Byte-identical replay: same op_id, same fields, same client_mutated_at.
    r3 = await push(app_client, s["acme"], [rename_op], actor=s["alice"])
    assert r3.status_code == 200, r3.text
    replayed_result = r3.json()["results"][0]
    assert replayed_result == {**original_result, "replayed": True}

    cur = await raw_conn.execute(
        "SELECT name FROM recipes WHERE id = %s", (uuid.UUID(rid),))
    assert (await cur.fetchone())[0] == "Beta"    # replay touched nothing
