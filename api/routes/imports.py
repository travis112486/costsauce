# api/routes/imports.py
"""POST /locations/{id}/purchases/import -- CSV purchase import (Phase 1d
Task 2), web-only replacement for the legacy `POST /api/purchases/import`
(product/app.py:673-733). Response shape, required-column set, and the
"CSV missing required column(s): ..." wording are kept legacy-compatible;
everything else (org scoping, the kernel's normalize_purchase, string
money, per-row SAVEPOINT isolation) is new to this phase.

Whole request is ONE tenant_connection transaction. Each data row runs
under its own SAVEPOINT (api/services/sync.py::apply_op's pattern) so one
bad row (a bad date, a kernel rejection) cannot poison rows around it --
the transaction stays usable for the next row instead of aborting.
"""
import csv
import io
import uuid
from decimal import Decimal, InvalidOperation

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from psycopg.errors import UniqueViolation

from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.kernel import match_ingredient, normalize_purchase
from api.routes.ingredients import _candidates, _require_location

router = APIRouter()

REQUIRED_COLUMNS = ["item", "vendor", "date", "qty", "unit", "total"]


@router.post("/locations/{location_id}/purchases/import")
async def import_purchases(location_id: uuid.UUID, request: Request,
                           file: UploadFile | None = File(None),
                           csv_text: str | None = Form(None),
                           caller: CallerIdentity = Depends(require_caller)):
    if file is not None:
        # utf-8-sig: Excel's "CSV UTF-8" export prepends a BOM. Plain "utf-8"
        # leaves it attached to the first header ("﻿item"), which then
        # fails the required-column check even though "item" is right there.
        content = (await file.read()).decode("utf-8-sig", errors="ignore")
    elif csv_text:
        content = csv_text.lstrip("﻿")
    else:
        raise HTTPException(422, "provide a file or csv_text")

    reader = csv.DictReader(io.StringIO(content.strip()))
    fieldmap = {(f or "").strip().lower(): f for f in (reader.fieldnames or [])}
    missing = [c for c in REQUIRED_COLUMNS if c not in fieldmap]
    if missing:
        raise HTTPException(
            400, f"CSV missing required column(s): {', '.join(missing)}")

    created = matched = rows_processed = 0
    errors: list[dict] = []

    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        # Org-scoped candidate list, extended in-memory as new rows create
        # ingredients -- so two CSV rows sharing a new (normalized) name
        # match each other within this same request instead of racing the
        # DB's unique index (migration 0015).
        cands = list(await _candidates(conn, location_id))

        for row in reader:
            # reader.line_num, not enumerate(start=2): DictReader silently
            # skips blank physical lines, so a plain counter drifts off the
            # "row = physical line, header = 1" contract the moment a CSV
            # has a blank line in it. line_num already counts every
            # physical line the underlying csv.reader has consumed,
            # blank ones included.
            i = reader.line_num
            rows_processed += 1
            await conn.execute("SAVEPOINT import_row")
            try:
                is_new, ingredient_id, ingredient_name = await _import_row(
                    conn, location_id, row, fieldmap, cands)
            except Exception as e:  # noqa: BLE001 -- per-row import errors are
                                     # reported, not fatal (legacy parity)
                await conn.execute("ROLLBACK TO SAVEPOINT import_row")
                errors.append({"row": i, "error": str(e)})
            else:
                await conn.execute("RELEASE SAVEPOINT import_row")
                if is_new:
                    created += 1
                    cands.append((ingredient_id, ingredient_name))
                else:
                    matched += 1

    return {"rows_processed": rows_processed, "created": created,
            "matched": matched, "errors": errors}


async def _import_row(conn, location_id, row, fieldmap, cands):
    """Process one CSV data row inside the caller's SAVEPOINT.

    Returns (is_new, ingredient_id, ingredient_name) on success; raises on
    any failure (bad qty/total, unknown unit, kernel rejection, bad date --
    the last surfaces as a psycopg error from the INSERT below).
    """
    item = (row.get(fieldmap["item"]) or "").strip()
    vendor = (row.get(fieldmap["vendor"]) or "").strip()
    purchased_on = (row.get(fieldmap["date"]) or "").strip()
    unit = (row.get(fieldmap["unit"]) or "").strip().lower()
    if not item:
        raise ValueError("missing item name")
    qty_raw = (row.get(fieldmap["qty"]) or "").strip()
    total_raw = (row.get(fieldmap["total"]) or "").strip()
    try:
        qty = Decimal(qty_raw)
        total_price = Decimal(total_raw)
    except InvalidOperation as e:
        raise ValueError(
            f"invalid qty or total: {qty_raw!r}/{total_raw!r}") from e

    is_new = False
    hit = match_ingredient(item, cands)
    if hit is not None:
        ingredient_id, ingredient_name, _ = hit
    else:
        base_unit = "each" if unit in ("each", "case") else "lb"
        await conn.execute("SAVEPOINT import_ingredient")
        try:
            cur = await conn.execute(
                "INSERT INTO ingredients"
                " (location_id, name, base_unit, vendor, category, source)"
                " VALUES (%s, %s, %s, %s, %s, %s) RETURNING id::text, name",
                (location_id, item, base_unit, vendor or None, "Imported",
                 "import"))
        except UniqueViolation:
            # Race loser: another writer created a normalized-equal name
            # between our _candidates snapshot and this INSERT (migration
            # 0015's partial unique index). Adopt the winner instead of
            # failing the row.
            await conn.execute("ROLLBACK TO SAVEPOINT import_ingredient")
            winner = match_ingredient(item, await _candidates(conn, location_id))
            if winner is None:
                raise
            ingredient_id, ingredient_name, _ = winner
        else:
            await conn.execute("RELEASE SAVEPOINT import_ingredient")
            ingredient_id, ingredient_name = await cur.fetchone()
            is_new = True

    cur = await conn.execute(
        "SELECT base_unit FROM ingredients WHERE id = %s", (ingredient_id,))
    (ing_base_unit,) = await cur.fetchone()
    qty_base = normalize_purchase(ing_base_unit, qty, unit, total_price)

    await conn.execute(
        "INSERT INTO purchases (location_id, ingredient_id, purchased_on,"
        " qty, unit, qty_base_units, total_price, source)"
        " VALUES (%s, %s, %s, %s, %s, %s, %s, 'import')",
        (location_id, ingredient_id, purchased_on, qty, unit, qty_base,
         total_price))
    return is_new, ingredient_id, ingredient_name
