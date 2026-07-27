"""DB-aware costing: ONE query per concern, the kernel does all math.

The SQL here never computes a statistic — it selects the exact candidate row
set (per-ingredient latest row + everything inside the anchored 90-day
window) and hands it to api.kernel. One authoritative math implementation,
one round trip (the demo did ~1700 per dashboard load — spec §10)."""
from decimal import Decimal, ROUND_HALF_UP
from api import kernel

DRIFT_CANDIDATES_SQL = """
WITH ranked AS (
  SELECT p.ingredient_id, p.unit_price, p.purchased_on, p.recorded_at, p.id,
         row_number() OVER (
           PARTITION BY p.ingredient_id
           ORDER BY p.purchased_on DESC, p.recorded_at DESC, p.id DESC
         ) AS rn,
         max(p.purchased_on) OVER (PARTITION BY p.ingredient_id) AS latest_on
    FROM purchases p
   WHERE p.location_id = %s AND p.deleted_at IS NULL
)
SELECT ingredient_id::text, unit_price, purchased_on, recorded_at, id::text
  FROM ranked
 WHERE rn = 1 OR purchased_on >= latest_on - 90
"""


async def location_drift(conn, location_id) -> dict:
    """ingredient_id (str) -> kernel.DriftResult for every ingredient at the
    location with at least one live purchase. The SQL pre-filter is a
    semantics-preserving superset: the kernel re-sorts and re-selects, so the
    rows[1:]-positional baseline stays kernel-owned (and golden-vectored)."""
    cur = await conn.execute(DRIFT_CANDIDATES_SQL, (location_id,))
    by_ing = {}
    for ing_id, unit_price, purchased_on, recorded_at, pid in await cur.fetchall():
        by_ing.setdefault(ing_id, []).append(kernel.PurchaseRow(
            purchased_on=purchased_on,
            recorded_at=kernel.canonical_recorded_at(recorded_at),
            id=pid, unit_price=unit_price))
    return {ing_id: kernel.drift(rows) for ing_id, rows in by_ing.items()}


def _money(d):
    return None if d is None else str(d)


async def cost_recipes(conn, location_id, drift_map) -> list[dict]:
    """All live recipes at the location, costed, one items query.
    Completeness contract (spec §10.1): LEFT JOIN, per-item is_resolvable;
    any unresolvable item nulls fc_pct/status/suggested_price."""
    cur = await conn.execute(
        "SELECT id::text, name, menu_price, target_fc_pct FROM recipes"
        " WHERE location_id = %s AND deleted_at IS NULL ORDER BY name, id",
        (location_id,))
    recipes = await cur.fetchall()
    cur = await conn.execute(
        """SELECT ri.recipe_id::text, ri.id::text, ri.qty_base_units,
                  ri.ingredient_id::text, i.name, i.base_unit,
                  (i.id IS NOT NULL AND i.deleted_at IS NULL) AS ingredient_live
             FROM recipe_items ri
             LEFT JOIN ingredients i ON i.id = ri.ingredient_id
            WHERE ri.location_id = %s AND ri.deleted_at IS NULL
            ORDER BY i.name, ri.id""", (location_id,))
    items_by_recipe = {}
    for row in await cur.fetchall():
        items_by_recipe.setdefault(row[0], []).append(row)

    out = []
    for rid, name, menu_price, target in recipes:
        plate = Decimal("0")
        items, complete = [], True
        for (_r, item_id, qty, ing_id, ing_name, base_unit,
             ing_live) in items_by_recipe.get(rid, []):
            d = drift_map.get(ing_id)
            resolvable = bool(ing_live) and d is not None
            cost = None
            if resolvable:
                cost = (Decimal(qty) * d.latest_price).quantize(
                    Decimal("0.01"), rounding=ROUND_HALF_UP)
                plate += cost
            else:
                complete = False
            items.append(dict(
                id=item_id, ingredient_id=ing_id, name=ing_name,
                base_unit=base_unit, qty_base_units=str(qty),
                unit_price=_money(d.latest_price) if resolvable else None,
                cost=_money(cost), is_resolvable=resolvable))
        plate_cents = int(plate * 100)
        menu_cents = int(Decimal(menu_price) * 100)
        target_bp = int(Decimal(target) * 100)
        if complete:
            fc, status = kernel.fc_status(plate_cents, menu_cents, target_bp)
            sugg = kernel.suggested_price_cents(plate_cents, target_bp)
            fc_out, status_out = str(fc), status
            sugg_out = f"{sugg // 100}.{sugg % 100:02d}"
        else:
            fc_out = status_out = sugg_out = None   # never reprice a partial
        out.append(dict(
            recipe_id=rid, name=name, menu_price=str(menu_price),
            target_fc_pct=str(target),
            plate_cost=str(plate.quantize(Decimal("0.01"),
                                           rounding=ROUND_HALF_UP)),
            fc_pct=fc_out, status=status_out, suggested_price=sugg_out,
            complete=complete, items=items))
    return out
