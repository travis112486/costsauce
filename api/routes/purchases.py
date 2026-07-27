import uuid
from fastapi import APIRouter, Depends, HTTPException, Request
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.kernel import KernelError, normalize_purchase
from api.models import PurchaseIn
from api.routes.ingredients import _require_location

router = APIRouter()


@router.post("/locations/{location_id}/purchases", status_code=201)
async def create_purchase(location_id: uuid.UUID, body: PurchaseIn,
                          request: Request,
                          caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            "SELECT base_unit FROM ingredients"
            " WHERE id = %s AND location_id = %s AND deleted_at IS NULL",
            (body.ingredient_id, location_id))
        row = await cur.fetchone()
        if row is None:
            raise HTTPException(404, "ingredient not found")
        (base_unit,) = row
        try:
            qty_base = normalize_purchase(
                base_unit, body.qty, body.unit, body.total_price,
                body.qty_in_case)
        except KernelError as e:
            raise HTTPException(400, str(e))
        cur = await conn.execute(
            "INSERT INTO purchases (location_id, ingredient_id, purchased_on,"
            " qty, unit, qty_in_case, qty_base_units, total_price)"
            " VALUES (%s, %s, %s, %s, %s, %s, %s, %s)"
            " RETURNING id::text, purchased_on::text, qty_base_units::text,"
            "           total_price::text, unit_price::text",
            (location_id, body.ingredient_id, body.purchased_on, body.qty,
             body.unit.strip().lower(), body.qty_in_case, qty_base,
             body.total_price))
        r = await cur.fetchone()
    return dict(id=r[0], purchased_on=r[1], qty_base_units=r[2],
                total_price=r[3], unit_price=r[4])


@router.delete("/locations/{location_id}/purchases/{purchase_id}", status_code=204)
async def tombstone_purchase(location_id: uuid.UUID, purchase_id: uuid.UUID,
                             request: Request,
                             caller: CallerIdentity = Depends(require_caller)):
    """Spec §13: DELETE /purchases/{id} exists so bad data is fixable
    in-product (B1's recovery gap). Tombstone, never a row DELETE."""
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            "UPDATE purchases SET deleted_at = now(), client_mutated_at = now()"
            " WHERE id = %s AND location_id = %s AND deleted_at IS NULL",
            (purchase_id, location_id))
        if cur.rowcount != 1:
            raise HTTPException(404, "purchase not found")
