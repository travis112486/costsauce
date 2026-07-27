# api/services/sync.py
"""Sync apply core (Phase 1c, §5). One op in, one result dict out.

Per-op SAVEPOINT so one failed op never poisons the caller's transaction
(the batch handler in Task 6 relies on this to keep going after a rejected
op). CS410 (org scheduled for deletion) is always re-raised: it is a
batch-level freeze, never a per-row `needs_attention` result -- see
`apply_op`'s docstring below for why.

Field values arrive as strings/None (the money contract -- see
api/models.py's SyncOpIn) and are bound as text params; psycopg lets
Postgres coerce them against the target column's type, exactly like every
route handler already does.
"""
import psycopg
from psycopg.errors import (
    CheckViolation, ForeignKeyViolation, InsufficientPrivilege,
    NotNullViolation, NumericValueOutOfRange, RaiseException, UniqueViolation,
)

SYNC_PAGE_CAP = 500
MAX_BATCH_OPS = 200
TABLE_ORDER = ("ingredients", "recipes", "recipe_items", "purchases")  # §5.5 FK order

INSERT_FIELDS = {
    "ingredients": {"name", "base_unit", "vendor", "category", "source", "deleted_at"},
    "recipes": {"name", "menu_price", "target_fc_pct", "deleted_at"},
    "recipe_items": {"recipe_id", "ingredient_id", "qty_base_units", "deleted_at"},
    "purchases": {"ingredient_id", "purchased_on", "recorded_at", "qty", "unit",
                  "qty_in_case", "qty_base_units", "total_price", "source", "deleted_at"},
}
UPDATE_FIELDS = {  # identity fields immutable: repointing is merge's job, never sync's
    "ingredients": {"name", "base_unit", "vendor", "category", "deleted_at"},
    "recipes": {"name", "menu_price", "target_fc_pct", "deleted_at"},
    "recipe_items": {"qty_base_units", "deleted_at"},
    "purchases": {"purchased_on", "recorded_at", "qty", "unit", "qty_in_case",
                  "qty_base_units", "total_price", "deleted_at"},
}

# Parent tables each syncable table's INSERT must check for liveness at
# op.location_id before writing (spec line 416 -- the 1b route-only
# invariant "no FK to a tombstoned row", enforced here on the sync path too,
# since a tombstoned parent still satisfies the FK constraint itself).
_PARENT_CHECKS = {
    "purchases": (("ingredient_id", "ingredients", "ingredient"),),
    "recipe_items": (
        ("recipe_id", "recipes", "recipe"),
        ("ingredient_id", "ingredients", "ingredient"),
    ),
}

_REASONS = [
    (UniqueViolation, "duplicate"),
    (ForeignKeyViolation, "missing parent row"),
    (InsufficientPrivilege, "forbidden for this role"),
    ((CheckViolation, NotNullViolation, NumericValueOutOfRange), "invalid value"),
]


def _reason(exc):
    state = getattr(exc, "sqlstate", None)
    if state == "CS425":
        return "client_mutated_at too far in the future"
    if state == "CS423":
        return "tombstone is monotonic"
    for types, label in _REASONS:
        if isinstance(exc, types):
            return label
    return "rejected by database"


async def apply_op(conn, org_id, op):
    """Apply one SyncOpIn under a SAVEPOINT and return a result dict.

    {"status": "applied", "row_id": "<uuid str>"}
    {"status": "stale", "reason": "older" | "deleted"}
    {"status": "needs_attention", "reason": "<short human string>"}

    CS410 (deletion freeze) is deliberately NOT turned into a per-row
    result: the batch handler must see it as a real exception so it can
    abort the whole push, not silently record one op as needs_attention
    while the org is mid-deletion.
    """
    await conn.execute("SAVEPOINT sync_op")
    try:
        result = await _apply(conn, org_id, op)
    except psycopg.Error as exc:
        if getattr(exc, "sqlstate", None) == "CS410":
            raise  # deletion freeze is batch-level, never a per-row result
        await conn.execute("ROLLBACK TO SAVEPOINT sync_op")
        result = {"status": "needs_attention", "reason": _reason(exc)}
    else:
        await conn.execute("RELEASE SAVEPOINT sync_op")
    return result


async def _apply(conn, org_id, op):
    table = op.table  # validated against the Literal in SyncOpIn -- safe to interpolate

    cur = await conn.execute(
        "SELECT 1 FROM locations WHERE id = %s AND org_id = %s",
        (op.location_id, org_id))
    if await cur.fetchone() is None:
        return {"status": "needs_attention",
                "reason": "location is not in this organization"}

    cur = await conn.execute(
        f"SELECT client_mutated_at, deleted_at, location_id FROM {table} WHERE id = %s",
        (op.row_id,))
    row = await cur.fetchone()

    if row is not None:
        return await _apply_update(conn, table, op, row)
    return await _apply_insert(conn, table, op)


async def _apply_update(conn, table, op, row):
    row_cm, row_deleted_at, row_location_id = row
    if row_location_id != op.location_id:
        return {"status": "needs_attention",
                "reason": "row belongs to a different location"}
    if row_deleted_at is not None:
        return {"status": "stale", "reason": "deleted"}
    if op.client_mutated_at < row_cm:
        return {"status": "stale", "reason": "older"}

    unknown = set(op.fields) - UPDATE_FIELDS[table]
    if unknown:
        return {"status": "needs_attention",
                "reason": f"unknown or immutable field: {sorted(unknown)[0]}"}

    if table == "ingredients" and op.fields.get("deleted_at") is not None:
        # spec line 416: the ingredient in-use guard is otherwise route-only
        # (DELETE /locations/{id}/ingredients/{id}, api/routes/ingredients.py)
        # -- a sync tombstone op must not be able to bypass it. Same
        # location-scoped live-recipe-line count the route runs.
        cur = await conn.execute(
            "SELECT count(*) FROM recipe_items"
            " WHERE ingredient_id = %s AND location_id = %s AND deleted_at IS NULL",
            (op.row_id, op.location_id))
        (in_use,) = await cur.fetchone()
        if in_use:
            return {"status": "needs_attention",
                    "reason": "ingredient is used by live recipe lines; "
                              "remove or merge it first"}

    sets = [f"{k} = %s" for k in op.fields]
    sets.append("client_mutated_at = %s")
    values = list(op.fields.values()) + [op.client_mutated_at, op.row_id]
    await conn.execute(f"UPDATE {table} SET {', '.join(sets)} WHERE id = %s", values)
    return {"status": "applied", "row_id": str(op.row_id)}


_PULL = {
    "ingredients": (
        "SELECT 'ingredients' AS tbl, t.server_seq AS seq, jsonb_build_object("
        "'id', t.id::text, 'location_id', t.location_id::text, 'name', t.name,"
        " 'base_unit', t.base_unit, 'vendor', t.vendor, 'category', t.category,"
        " 'source', t.source, 'client_mutated_at', t.client_mutated_at::text,"
        " 'server_seq', t.server_seq, 'updated_at', t.updated_at::text,"
        " 'deleted_at', t.deleted_at::text, 'created_at', t.created_at::text) AS row"
        " FROM ingredients t JOIN locations l ON l.id = t.location_id"
        " WHERE l.org_id = %(org)s AND t.server_seq > %(since)s"),
    "recipes": (
        "SELECT 'recipes', t.server_seq, jsonb_build_object("
        "'id', t.id::text, 'location_id', t.location_id::text, 'name', t.name,"
        " 'menu_price', t.menu_price::text, 'target_fc_pct', t.target_fc_pct::text,"
        " 'client_mutated_at', t.client_mutated_at::text, 'server_seq', t.server_seq,"
        " 'updated_at', t.updated_at::text, 'deleted_at', t.deleted_at::text,"
        " 'created_at', t.created_at::text)"
        " FROM recipes t JOIN locations l ON l.id = t.location_id"
        " WHERE l.org_id = %(org)s AND t.server_seq > %(since)s"),
    "recipe_items": (
        "SELECT 'recipe_items', t.server_seq, jsonb_build_object("
        "'id', t.id::text, 'location_id', t.location_id::text,"
        " 'recipe_id', t.recipe_id::text, 'ingredient_id', t.ingredient_id::text,"
        " 'qty_base_units', t.qty_base_units::text,"
        " 'client_mutated_at', t.client_mutated_at::text, 'server_seq', t.server_seq,"
        " 'updated_at', t.updated_at::text, 'deleted_at', t.deleted_at::text,"
        " 'created_at', t.created_at::text)"
        " FROM recipe_items t JOIN locations l ON l.id = t.location_id"
        " WHERE l.org_id = %(org)s AND t.server_seq > %(since)s"),
    "purchases": (
        "SELECT 'purchases', t.server_seq, jsonb_build_object("
        "'id', t.id::text, 'location_id', t.location_id::text,"
        " 'ingredient_id', t.ingredient_id::text, 'purchased_on', t.purchased_on::text,"
        " 'recorded_at', t.recorded_at::text, 'qty', t.qty::text, 'unit', t.unit,"
        " 'qty_in_case', t.qty_in_case::text, 'qty_base_units', t.qty_base_units::text,"
        " 'total_price', t.total_price::text, 'unit_price', t.unit_price::text,"
        " 'source', t.source, 'client_mutated_at', t.client_mutated_at::text,"
        " 'server_seq', t.server_seq, 'updated_at', t.updated_at::text,"
        " 'deleted_at', t.deleted_at::text, 'created_at', t.created_at::text)"
        " FROM purchases t JOIN locations l ON l.id = t.location_id"
        " WHERE l.org_id = %(org)s AND t.server_seq > %(since)s"),
}
_PULL_SQL = " UNION ALL ".join(_PULL[t] for t in TABLE_ORDER) + \
    " ORDER BY 2 LIMIT %(lim)s"


async def pull(conn, org_id, since, limit=None):
    """Global cursor pull across all four syncable tables (§5, Task 7).

    `since` is the caller's last-seen server_seq; rows are ordered by
    server_seq ACROSS tables (column 2 of the UNION ALL, not per-table), so
    a client walking pages in order sees a single monotonic timeline.
    Tombstones are included -- a pulled row with deleted_at set IS the
    delete, there is no separate deletion feed. Fetches `cap + 1` rows to
    learn whether more remain without a second round trip; `page` is the
    cap-sized slice actually returned. `limit` is caller-overridable (the
    page-cap test uses it / monkeypatches SYNC_PAGE_CAP) but the route
    itself always passes none, so the effective cap is the module constant
    resolved at call time -- monkeypatching SYNC_PAGE_CAP after import still
    works because this reads the name from the module's own globals, not a
    captured default.
    """
    cap = limit if limit is not None else SYNC_PAGE_CAP
    cur = await conn.execute(
        _PULL_SQL, {"org": org_id, "since": since, "lim": cap + 1})
    rows = await cur.fetchall()
    page = rows[:cap]
    changes = [{"table": tbl, "row": payload} for tbl, _seq, payload in page]
    return {"changes": changes,
            "cursor": page[-1][1] if page else since,
            "has_more": len(rows) > cap}


async def _apply_insert(conn, table, op):
    unknown = set(op.fields) - INSERT_FIELDS[table]
    if unknown:
        return {"status": "needs_attention",
                "reason": f"unknown field: {sorted(unknown)[0]}"}

    for field_name, parent_table, label in _PARENT_CHECKS.get(table, ()):
        parent_id = op.fields.get(field_name)
        if parent_id is None:
            continue
        cur = await conn.execute(
            f"SELECT 1 FROM {parent_table} WHERE id = %s AND location_id = %s"
            " AND deleted_at IS NULL",
            (parent_id, op.location_id))
        if await cur.fetchone() is None:
            return {"status": "needs_attention",
                    "reason": f"referenced {label} is not live"}

    # Task 5: recipe_items uses ON CONFLICT upsert for canonical (recipe_id,
    # ingredient_id) rows; other tables use plain INSERT.
    if table == "recipe_items":
        fields = op.fields
        cur = await conn.execute(
            "INSERT INTO recipe_items (id, location_id, recipe_id, ingredient_id,"
            " qty_base_units, deleted_at, client_mutated_at)"
            " VALUES (%s, %s, %s, %s, %s, %s, %s)"
            " ON CONFLICT (recipe_id, ingredient_id) WHERE deleted_at IS NULL"
            " DO UPDATE SET qty_base_units = EXCLUDED.qty_base_units,"
            "               deleted_at = EXCLUDED.deleted_at,"
            "               client_mutated_at = EXCLUDED.client_mutated_at"
            " WHERE recipe_items.client_mutated_at <= EXCLUDED.client_mutated_at"
            " RETURNING id",
            (op.row_id, op.location_id, fields.get("recipe_id"),
             fields.get("ingredient_id"), fields.get("qty_base_units"),
             fields.get("deleted_at"), op.client_mutated_at))
        row = await cur.fetchone()
        if row is None:
            # conflict arbitration ran and the existing line's clock was newer
            cur = await conn.execute(
                "SELECT id FROM recipe_items WHERE recipe_id = %s AND ingredient_id = %s"
                " AND deleted_at IS NULL",
                (fields.get("recipe_id"), fields.get("ingredient_id")))
            (canonical,) = await cur.fetchone()
            return {"status": "stale", "reason": "older", "row_id": str(canonical)}
        return {"status": "applied", "row_id": str(row[0])}
    else:
        # Plain INSERT for other tables
        cols = ["id", "location_id", "client_mutated_at"] + list(op.fields.keys())
        placeholders = ", ".join(["%s"] * len(cols))
        values = [op.row_id, op.location_id, op.client_mutated_at] + list(op.fields.values())
        await conn.execute(
            f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({placeholders})", values)
        return {"status": "applied", "row_id": str(op.row_id)}
