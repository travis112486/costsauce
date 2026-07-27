# tests/test_sync_push.py
"""POST /sync: atomic FK-ordered batch apply (Task 6, spec §5-6).

Covers: applied rows becoming visible, input-order/op_id preservation on
results, cursor reporting the org's sync_counter, 404 for unknown AND
non-member orgs (RLS makes them indistinguishable), 413 for an oversized
batch, op_id idempotency both within one batch and across batches,
needs_attention ops never touching the ledger, per-role rejection alongside
a same-batch op that succeeds, child-before-parent payload ordering being
corrected by TABLE_ORDER, and the scheduled-org 410 discarding the whole
batch before anything is applied.
"""
import uuid
from datetime import datetime, timezone

from tests.factories import make_ingredient, make_user, add_member
from tests.test_auth import mint
from api.services import sync as svc


def auth(user_id):
    return {"Authorization": f"Bearer {mint(sub=str(user_id))}"}


def op(table, *, row_id=None, location_id, fields=None, client_mutated_at=None,
       op_id=None):
    return {
        "op_id": str(op_id or uuid.uuid4()),
        "table": table,
        "row_id": str(row_id or uuid.uuid4()),
        "location_id": str(location_id),
        "client_mutated_at": (client_mutated_at or datetime.now(timezone.utc)).isoformat(),
        "fields": fields or {},
    }


async def push(app_client, org_id, ops, *, actor, batch_id=None):
    return await app_client.post(
        "/sync",
        json={"org_id": str(org_id), "batch_id": str(batch_id or uuid.uuid4()), "ops": ops},
        headers=auth(actor),
    )


# ---------------------------------------------------------------------------
# Basic apply + visibility
# ---------------------------------------------------------------------------

async def test_insert_applies_and_row_is_visible(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    row_id = uuid.uuid4()
    o = op("ingredients", row_id=row_id, location_id=s["acme_loc"],
           fields={"name": "Chicken Breast", "base_unit": "lb"})
    r = await push(app_client, s["acme"], [o], actor=s["alice"])
    assert r.status_code == 200, r.text
    result = r.json()["results"][0]
    assert result["status"] == "applied"
    assert result["row_id"] == str(row_id)
    assert result["op_id"] == o["op_id"]

    cur = await raw_conn.execute(
        "SELECT name, base_unit FROM ingredients WHERE id = %s", (row_id,))
    row = await cur.fetchone()
    assert row == ("Chicken Breast", "lb")


async def test_results_preserve_input_order_and_carry_op_id(app_client, seeded_biz):
    """recipes ranks after ingredients in TABLE_ORDER, so listing the recipe
    op FIRST forces the handler to apply it SECOND internally -- the results
    list must still come back in the caller's original order."""
    s = seeded_biz
    recipe_op = op("recipes", location_id=s["acme_loc"],
                   fields={"name": "Soup", "menu_price": "8.00"})
    ing_op = op("ingredients", location_id=s["acme_loc"],
               fields={"name": "Salt", "base_unit": "oz"})
    r = await push(app_client, s["acme"], [recipe_op, ing_op], actor=s["alice"])
    assert r.status_code == 200, r.text
    results = r.json()["results"]
    assert len(results) == 2
    assert results[0]["op_id"] == recipe_op["op_id"]
    assert results[1]["op_id"] == ing_op["op_id"]
    assert results[0]["status"] == "applied"
    assert results[1]["status"] == "applied"


async def test_cursor_equals_org_sync_counter(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    o = op("ingredients", location_id=s["acme_loc"],
           fields={"name": "Sugar", "base_unit": "lb"})
    r = await push(app_client, s["acme"], [o], actor=s["alice"])
    assert r.status_code == 200, r.text
    cur = await raw_conn.execute(
        "SELECT sync_counter FROM organizations WHERE id = %s", (s["acme"],))
    (counter,) = await cur.fetchone()
    assert r.json()["cursor"] == counter


# ---------------------------------------------------------------------------
# Org resolution: unknown vs non-member are both 404
# ---------------------------------------------------------------------------

async def test_non_member_org_is_404(app_client, seeded_biz):
    s = seeded_biz
    o = op("ingredients", location_id=s["bistro_loc"], fields={"name": "X", "base_unit": "lb"})
    r = await push(app_client, s["bistro"], [o], actor=s["alice"])
    assert r.status_code == 404


async def test_unknown_org_is_404(app_client, seeded_biz):
    s = seeded_biz
    o = op("ingredients", location_id=s["acme_loc"], fields={"name": "X", "base_unit": "lb"})
    r = await push(app_client, uuid.uuid4(), [o], actor=s["alice"])
    assert r.status_code == 404


# ---------------------------------------------------------------------------
# Batch size limit
# ---------------------------------------------------------------------------

async def test_oversized_batch_is_413(app_client, seeded_biz):
    s = seeded_biz
    ops = [op("ingredients", location_id=s["acme_loc"],
              fields={"name": f"X{i}", "base_unit": "lb"})
           for i in range(svc.MAX_BATCH_OPS + 1)]
    r = await push(app_client, s["acme"], ops, actor=s["alice"])
    assert r.status_code == 413


# ---------------------------------------------------------------------------
# op_id idempotency
# ---------------------------------------------------------------------------

async def test_duplicate_op_id_in_same_batch_is_replayed(app_client, seeded_biz):
    s = seeded_biz
    o = op("ingredients", location_id=s["acme_loc"], fields={"name": "Butter", "base_unit": "lb"})
    r = await push(app_client, s["acme"], [o, o], actor=s["alice"])
    assert r.status_code == 200, r.text
    results = r.json()["results"]
    assert results[0]["status"] == "applied"
    assert results[1]["replayed"] is True
    assert results[1] == {**results[0], "replayed": True}


async def test_replay_in_later_batch_returns_stored_result(app_client, seeded_biz):
    s = seeded_biz
    o = op("ingredients", location_id=s["acme_loc"], fields={"name": "Pepper", "base_unit": "oz"})
    r1 = await push(app_client, s["acme"], [o], actor=s["alice"])
    assert r1.status_code == 200, r1.text
    first_result = r1.json()["results"][0]
    assert first_result["status"] == "applied"

    r2 = await push(app_client, s["acme"], [o], actor=s["alice"])  # fresh batch_id
    assert r2.status_code == 200, r2.text
    second_result = r2.json()["results"][0]
    assert second_result == {**first_result, "replayed": True}


# ---------------------------------------------------------------------------
# needs_attention is never ledgered
# ---------------------------------------------------------------------------

async def test_needs_attention_not_ledgered_then_succeeds_once_parent_exists(
        app_client, seeded_biz, raw_conn):
    s = seeded_biz
    missing_ing = uuid.uuid4()
    purchase_op = op("purchases", location_id=s["acme_loc"],
                     fields={"ingredient_id": str(missing_ing)})
    r = await push(app_client, s["acme"], [purchase_op], actor=s["alice"])
    assert r.status_code == 200, r.text
    result = r.json()["results"][0]
    assert result["status"] == "needs_attention"

    cur = await raw_conn.execute(
        "SELECT count(*) FROM sync_ops WHERE op_id = %s",
        (uuid.UUID(purchase_op["op_id"]),))
    assert (await cur.fetchone())[0] == 0

    ing_op = op("ingredients", row_id=missing_ing, location_id=s["acme_loc"],
               fields={"name": "Vanilla", "base_unit": "oz"})
    r2 = await push(app_client, s["acme"], [ing_op], actor=s["alice"])
    assert r2.status_code == 200, r2.text
    assert r2.json()["results"][0]["status"] == "applied"

    # Re-push the SAME op_id, now with the full purchase payload, once the
    # ingredient it references actually exists.
    retry_op = dict(purchase_op)
    retry_op["fields"] = {
        "ingredient_id": str(missing_ing), "purchased_on": "2026-07-01",
        "qty": "5", "unit": "lb", "qty_base_units": "5.0000", "total_price": "20.00",
    }
    r3 = await push(app_client, s["acme"], [retry_op], actor=s["alice"])
    assert r3.status_code == 200, r3.text
    result3 = r3.json()["results"][0]
    assert result3["status"] == "applied"


# ---------------------------------------------------------------------------
# Role rejection alongside a same-batch success
# ---------------------------------------------------------------------------

async def test_bookkeeper_forbidden_for_recipe_but_ingredient_applies(
        app_client, seeded_biz, raw_conn):
    s = seeded_biz
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, s["acme"], "bookkeeper")
    await raw_conn.commit()

    ops = [
        op("recipes", location_id=s["acme_loc"],
           fields={"name": "Forbidden Dish", "menu_price": "12.00"}),
        op("ingredients", location_id=s["acme_loc"],
           fields={"name": "Thyme", "base_unit": "oz"}),
    ]
    r = await push(app_client, s["acme"], ops, actor=carol)
    assert r.status_code == 200, r.text
    results = r.json()["results"]
    assert results[0]["status"] == "needs_attention"
    assert results[0]["reason"] == "forbidden for this role"
    assert results[1]["status"] == "applied"


# ---------------------------------------------------------------------------
# FK-order correction of the payload
# ---------------------------------------------------------------------------

async def test_child_before_parent_in_payload_still_applies_via_table_order(
        app_client, seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Flour")
    await raw_conn.commit()

    recipe_row_id = uuid.uuid4()
    item_row_id = uuid.uuid4()
    ops = [
        op("recipe_items", row_id=item_row_id, location_id=s["acme_loc"],
           fields={"recipe_id": str(recipe_row_id), "ingredient_id": str(ing),
                   "qty_base_units": "2.0000"}),
        op("recipes", row_id=recipe_row_id, location_id=s["acme_loc"],
           fields={"name": "Bread", "menu_price": "9.99"}),
    ]
    r = await push(app_client, s["acme"], ops, actor=s["alice"])
    assert r.status_code == 200, r.text
    results = r.json()["results"]
    assert results[0]["status"] == "applied"  # recipe_items, listed first
    assert results[1]["status"] == "applied"  # recipes, listed second


# ---------------------------------------------------------------------------
# Scheduled-org freeze: 410, whole batch discarded
# ---------------------------------------------------------------------------

async def test_scheduled_org_is_410_and_nothing_applied(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() WHERE id = %s",
        (s["acme"],))
    await raw_conn.commit()

    o = op("ingredients", location_id=s["acme_loc"], fields={"name": "Ghost", "base_unit": "lb"})
    r = await push(app_client, s["acme"], [o], actor=s["alice"])
    assert r.status_code == 410

    import api.main
    assert r.json()["detail"] == api.main.ORG_SCHEDULED_MESSAGE

    cur = await raw_conn.execute(
        "SELECT count(*) FROM ingredients WHERE location_id = %s AND name = 'Ghost'",
        (s["acme_loc"],))
    assert (await cur.fetchone())[0] == 0
    cur = await raw_conn.execute(
        "SELECT count(*) FROM sync_ops WHERE op_id = %s", (uuid.UUID(o["op_id"]),))
    assert (await cur.fetchone())[0] == 0
