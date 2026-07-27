# tests/test_sync_scenarios.py
"""Scenario suite I (Phase 1c, §5.4/§4.2/§5.3): item-count convergence,
stale loser, replay. These exercise the already-built sync stack
(Tasks 1-7) end to end through the HTTP surface -- a failure here means a
real bug in that stack, not a weak assertion to fix here.

Scenario suite II (Task 9) appends two more: §17's reverse-commit-order
race on `server_seq` allocation, and §14's deletion guard applied to the
sync path specifically (offline push discarded, cancel restores).
"""
import asyncio
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from tests.test_ingredients_routes import auth
from tests.test_recipes_routes import seed_priced
from tests.test_sync_push import op, push
from tests.test_sync_service import app_url
from api.db import pool_open, tenant_connection
from api.services import sync as svc


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


async def test_seq_allocation_serializes_with_commit_order(db_url, seeded_biz, raw_conn):
    """spec §17: `sync_row_stamp` (migration 0014) allocates `server_seq` by
    `UPDATE organizations SET sync_counter = sync_counter + 1 ... RETURNING`,
    which takes the org's row lock and holds it for the rest of the writer's
    transaction. A second writer touching the same org must therefore BLOCK
    at the SQL level until the first commits or rolls back -- allocation is
    serialized with commit order by construction, so a lower seq can never
    commit after a higher one already has. If it could, a pull cursored just
    above the first (lower) seq could permanently miss the second row: a
    committed gap below the cursor, which the whole page-cursor contract
    (§5.1) depends on never existing.
    """
    s = seeded_biz
    pool = await pool_open(app_url(db_url))
    seqs: dict[str, int] = {}
    event_a_inserted = asyncio.Event()
    event_a_can_finish = asyncio.Event()
    event_b_can_finish = asyncio.Event()
    task_a = task_b = None
    try:
        async def task_a_fn():
            async with tenant_connection(pool, {"sub": str(s["alice"])}) as conn:
                cur = await conn.execute(
                    "INSERT INTO ingredients (location_id, name, base_unit)"
                    " VALUES (%s, %s, %s) RETURNING server_seq",
                    (s["acme_loc"], "Task A Ingredient", "lb"))
                (seq,) = await cur.fetchone()
                seqs["a"] = seq
                event_a_inserted.set()
                await event_a_can_finish.wait()
            # commit fires on tenant_connection's normal __aexit__, i.e. now

        async def task_b_fn():
            await event_a_inserted.wait()
            async with tenant_connection(pool, {"sub": str(s["alice"])}) as conn:
                # This INSERT fires the same trigger against the SAME org
                # row A's still-open transaction holds the lock on -- it
                # must not return until A commits or rolls back.
                cur = await conn.execute(
                    "INSERT INTO ingredients (location_id, name, base_unit)"
                    " VALUES (%s, %s, %s) RETURNING server_seq",
                    (s["acme_loc"], "Task B Ingredient", "lb"))
                (seq,) = await cur.fetchone()
                seqs["b"] = seq
                await event_b_can_finish.wait()

        task_a = asyncio.create_task(task_a_fn())
        task_b = asyncio.create_task(task_b_fn())

        await asyncio.wait_for(event_a_inserted.wait(), timeout=5)

        # A holds the org row lock uncommitted; B's INSERT must still be
        # stuck acquiring it after a real wait, not just genuinely slow.
        done, pending = await asyncio.wait([task_b], timeout=0.3)
        assert task_b in pending, (
            "task B's INSERT must block on the org counter row lock while "
            "task A's transaction is still uncommitted")
        assert "b" not in seqs

        event_a_can_finish.set()
        await asyncio.wait_for(task_a, timeout=5)   # A commits, releasing the lock

        event_b_can_finish.set()
        await asyncio.wait_for(task_b, timeout=5)   # B can now proceed and commit

        assert seqs["a"] < seqs["b"]

        async with tenant_connection(pool, {"sub": str(s["alice"])}) as conn:
            result = await svc.pull(conn, s["acme"], seqs["a"])
        changes = result["changes"]
        # No committed gap below the cursor: since=seqA sees exactly B's row.
        assert len(changes) == 1
        assert changes[0]["table"] == "ingredients"
        assert changes[0]["row"]["server_seq"] == seqs["b"]
        assert changes[0]["row"]["name"] == "Task B Ingredient"
    finally:
        # Asyncio hygiene: a failed assert above must not leave either task
        # parked forever on an Event nobody ever sets, hanging the run.
        event_a_can_finish.set()
        event_b_can_finish.set()
        for t in (task_a, task_b):
            if t is not None and not t.done():
                t.cancel()
        if task_a is not None:
            await asyncio.gather(task_a, task_b, return_exceptions=True)
        await pool.close()


async def test_offline_push_after_deletion_is_discarded_and_cancel_restores(
        app_client, seeded_biz, raw_conn):
    """spec §14/§6.2 line 295-296 applied to the sync path specifically: a
    device that pushes into a scheduled-for-deletion org must get 410 with
    NOTHING applied and NOTHING ledgered -- an offline device cannot
    resurrect a doomed org just by staying offline through the schedule.
    But a cancelled deletion loses nothing: the exact same batch (same
    op_ids), re-pushed after DELETE /orgs/{id}/deletion, must apply cleanly.
    """
    s = seeded_biz
    hdr = auth(s["alice"])
    zombie_op = op("ingredients", location_id=s["acme_loc"],
                    fields={"name": "Zombie Flour", "base_unit": "lb"})
    batch_id = uuid.uuid4()
    row_id = uuid.UUID(zombie_op["row_id"])
    op_id = uuid.UUID(zombie_op["op_id"])

    r_sched = await app_client.post(f"/orgs/{s['acme']}/deletion", headers=hdr)
    assert r_sched.status_code == 200, r_sched.text

    r_push = await push(app_client, s["acme"], [zombie_op], actor=s["alice"],
                        batch_id=batch_id)
    assert r_push.status_code == 410, r_push.text
    assert "scheduled for deletion" in r_push.text.lower()

    cur = await raw_conn.execute(
        "SELECT count(*) FROM ingredients WHERE id = %s", (row_id,))
    assert (await cur.fetchone())[0] == 0, "discarded push must not create the row"

    cur = await raw_conn.execute(
        "SELECT count(*) FROM sync_ops WHERE op_id = %s", (op_id,))
    assert (await cur.fetchone())[0] == 0, "discarded push must not ledger the op"

    r_cancel = await app_client.delete(f"/orgs/{s['acme']}/deletion", headers=hdr)
    assert r_cancel.status_code == 200, r_cancel.text

    # Re-push the SAME batch: same op_id, same row_id, same fields.
    r_repush = await push(app_client, s["acme"], [zombie_op], actor=s["alice"],
                          batch_id=batch_id)
    assert r_repush.status_code == 200, r_repush.text
    result = r_repush.json()["results"][0]
    assert result["status"] == "applied"
    assert result["row_id"] == zombie_op["row_id"]

    cur = await raw_conn.execute(
        "SELECT name FROM ingredients WHERE id = %s", (row_id,))
    row = await cur.fetchone()
    assert row is not None and row[0] == "Zombie Flour", \
        "a cancelled deletion must not cost the device its queued write"
