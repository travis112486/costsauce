import uuid
from fastapi import APIRouter, Depends, HTTPException, Request
from psycopg.errors import UniqueViolation
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.models import RecipeIn
from api.routes.ingredients import _require_location
from api.services import costing

router = APIRouter()


async def _costed_one(conn, location_id, recipe_id):
    drift_map = await costing.location_drift(conn, location_id)
    for payload in await costing.cost_recipes(conn, location_id, drift_map):
        if payload["recipe_id"] == str(recipe_id):
            return payload
    raise HTTPException(404, "recipe not found")


async def _insert_item(conn, location_id, recipe_id, item):
    cur = await conn.execute(
        "SELECT 1 FROM ingredients WHERE id = %s AND location_id = %s",
        (item.ingredient_id, location_id))
    if await cur.fetchone() is None:
        raise HTTPException(404, f"ingredient {item.ingredient_id} not found")
    try:
        await conn.execute(
            "INSERT INTO recipe_items (location_id, recipe_id, ingredient_id,"
            " qty_base_units) VALUES (%s, %s, %s, %s)",
            (location_id, recipe_id, item.ingredient_id, item.qty_base_units))
    except UniqueViolation:
        raise HTTPException(
            409, f"ingredient {item.ingredient_id} already has a live line "
                 "in this recipe — send its item id to update it")


@router.post("/locations/{location_id}/recipes", status_code=201)
async def create_recipe(location_id: uuid.UUID, body: RecipeIn, request: Request,
                        caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            "INSERT INTO recipes (location_id, name, menu_price, target_fc_pct)"
            " VALUES (%s, %s, %s, %s) RETURNING id",
            (location_id, body.name.strip(), body.menu_price, body.target_fc_pct))
        (rid,) = await cur.fetchone()
        for item in body.items:
            if item.id is not None:
                raise HTTPException(422, "items on create must not carry ids")
            await _insert_item(conn, location_id, rid, item)
        return await _costed_one(conn, location_id, rid)


@router.get("/locations/{location_id}/recipes")
async def list_recipes(location_id: uuid.UUID, request: Request,
                       caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        drift_map = await costing.location_drift(conn, location_id)
        return await costing.cost_recipes(conn, location_id, drift_map)


@router.get("/locations/{location_id}/recipes/{recipe_id}")
async def get_recipe(location_id: uuid.UUID, recipe_id: uuid.UUID,
                     request: Request,
                     caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        return await _costed_one(conn, location_id, recipe_id)


@router.put("/locations/{location_id}/recipes/{recipe_id}")
async def update_recipe(location_id: uuid.UUID, recipe_id: uuid.UUID,
                        body: RecipeIn, request: Request,
                        caller: CallerIdentity = Depends(require_caller)):
    """Spec §5.4: upsert diff. Update-in-place by item id, insert new lines,
    tombstone lines missing from the payload. NEVER delete-and-reinsert --
    that is the double-plate-cost bug under Phase 1c sync. Updates run
    before inserts so 'swap the id off a line and re-add the ingredient'
    conflicts loudly instead of racing the partial unique index."""
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            "UPDATE recipes SET name = %s, menu_price = %s, target_fc_pct = %s"
            " WHERE id = %s AND location_id = %s AND deleted_at IS NULL",
            (body.name.strip(), body.menu_price, body.target_fc_pct,
             recipe_id, location_id))
        if cur.rowcount != 1:
            raise HTTPException(404, "recipe not found")
        cur = await conn.execute(
            "SELECT id FROM recipe_items"
            " WHERE recipe_id = %s AND deleted_at IS NULL", (recipe_id,))
        live_ids = {row[0] for row in await cur.fetchall()}
        sent_ids = set()
        for item in body.items:
            if item.id is not None:
                if item.id not in live_ids:
                    raise HTTPException(
                        404, f"item {item.id} is not a live line of this recipe")
                sent_ids.add(item.id)
                await conn.execute(
                    "UPDATE recipe_items SET qty_base_units = %s WHERE id = %s",
                    (item.qty_base_units, item.id))
        for item in body.items:
            if item.id is None:
                await _insert_item(conn, location_id, recipe_id, item)
        removed = live_ids - sent_ids
        if removed:
            await conn.execute(
                "UPDATE recipe_items SET deleted_at = now() WHERE id = ANY(%s)",
                (list(removed),))
        return await _costed_one(conn, location_id, recipe_id)


@router.delete("/locations/{location_id}/recipes/{recipe_id}", status_code=204)
async def delete_recipe(location_id: uuid.UUID, recipe_id: uuid.UUID,
                        request: Request,
                        caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            "UPDATE recipes SET deleted_at = now()"
            " WHERE id = %s AND location_id = %s AND deleted_at IS NULL",
            (recipe_id, location_id))
        if cur.rowcount != 1:
            raise HTTPException(404, "recipe not found")
        await conn.execute(
            "UPDATE recipe_items SET deleted_at = now()"
            " WHERE recipe_id = %s AND deleted_at IS NULL", (recipe_id,))
