# api/routes/ingredients.py
import uuid
from fastapi import APIRouter, Depends, HTTPException, Request
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.kernel import match_ingredient, normalize_name
from api.models import IngredientIn

router = APIRouter()


async def _require_location(conn, location_id):
    cur = await conn.execute("SELECT 1 FROM locations WHERE id = %s", (location_id,))
    if await cur.fetchone() is None:
        # RLS hides other orgs' locations, so unknown and cross-org are the
        # same 404 — deliberately not distinguishable.
        raise HTTPException(404, "location not found")


async def _candidates(conn, location_id):
    """Org-scoped, deterministically ordered (created_at, id): first-match-
    wins is part of the kernel contract."""
    cur = await conn.execute(
        "SELECT id::text, name FROM ingredients"
        " WHERE location_id = %s AND deleted_at IS NULL"
        " ORDER BY created_at, id", (location_id,))
    return await cur.fetchall()


@router.get("/locations/{location_id}/ingredients")
async def list_ingredients(location_id: uuid.UUID, request: Request,
                           caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            """SELECT i.id::text, i.name, i.base_unit, i.vendor, i.category,
                      count(p.id) AS purchase_count,
                      (SELECT p2.unit_price::text FROM purchases p2
                        WHERE p2.ingredient_id = i.id AND p2.deleted_at IS NULL
                        ORDER BY p2.purchased_on DESC, p2.recorded_at DESC,
                                 p2.id DESC
                        LIMIT 1) AS latest_price
                 FROM ingredients i
                 LEFT JOIN purchases p
                   ON p.ingredient_id = i.id AND p.deleted_at IS NULL
                WHERE i.location_id = %s AND i.deleted_at IS NULL
                GROUP BY i.id, i.name, i.base_unit, i.vendor, i.category
                ORDER BY i.name, i.id""", (location_id,))
        rows = await cur.fetchall()
    return [dict(id=r[0], name=r[1], base_unit=r[2], vendor=r[3], category=r[4],
                 purchase_count=r[5], latest_price=r[6]) for r in rows]


@router.get("/locations/{location_id}/ingredients/match")
async def match(location_id: uuid.UUID, name: str, request: Request,
                caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cands = await _candidates(conn, location_id)
    hit = match_ingredient(name, cands)
    norm = normalize_name(name)
    near = [dict(id=c[0], name=c[1]) for c in cands
            if norm and (norm in normalize_name(c[1])
                         or normalize_name(c[1]) in norm)][:3]
    return {"match": dict(id=hit[0], name=hit[1], type=hit[2]) if hit else None,
            "near_matches": near}


@router.post("/locations/{location_id}/ingredients", status_code=201)
async def create_ingredient(location_id: uuid.UUID, body: IngredientIn,
                            request: Request,
                            caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cands = await _candidates(conn, location_id)
        norm = normalize_name(body.name)
        if not norm:
            raise HTTPException(400, "name normalizes to nothing")
        exact = [c for c in cands if normalize_name(c[1]) == norm]
        if exact:
            raise HTTPException(
                409, detail={"detail": "duplicate",
                             "matches": [dict(id=c[0], name=c[1]) for c in exact]})
        cur = await conn.execute(
            "INSERT INTO ingredients (location_id, name, base_unit, vendor, category)"
            " VALUES (%s, %s, %s, %s, %s) RETURNING id::text",
            (location_id, body.name.strip(), body.base_unit, body.vendor,
             body.category))
        (iid,) = await cur.fetchone()
    return dict(id=iid, name=body.name.strip(), base_unit=body.base_unit,
                vendor=body.vendor, category=body.category)


@router.delete("/locations/{location_id}/ingredients/{ingredient_id}",
               status_code=204)
async def tombstone_ingredient(location_id: uuid.UUID, ingredient_id: uuid.UUID,
                               request: Request,
                               caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            "SELECT count(*) FROM recipe_items"
            " WHERE ingredient_id = %s AND deleted_at IS NULL", (ingredient_id,))
        (in_use,) = await cur.fetchone()
        if in_use:
            raise HTTPException(
                409, f"ingredient is used by {in_use} live recipe line(s); "
                     "remove or merge it first")
        cur = await conn.execute(
            "UPDATE ingredients SET deleted_at = now()"
            " WHERE id = %s AND location_id = %s AND deleted_at IS NULL",
            (ingredient_id, location_id))
        if cur.rowcount != 1:
            raise HTTPException(404, "ingredient not found")


@router.get("/locations/{location_id}/ingredients/{ingredient_id}/history")
async def history(location_id: uuid.UUID, ingredient_id: uuid.UUID,
                  request: Request,
                  caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            "SELECT id::text, purchased_on::text, qty_base_units::text,"
            "       total_price::text, unit_price::text, source"
            "  FROM purchases"
            " WHERE ingredient_id = %s AND location_id = %s AND deleted_at IS NULL"
            " ORDER BY purchased_on DESC, recorded_at DESC, id DESC",
            (ingredient_id, location_id))
        rows = await cur.fetchall()
    return {"purchases": [dict(id=r[0], purchased_on=r[1], qty_base_units=r[2],
                               total_price=r[3], unit_price=r[4], source=r[5])
                          for r in rows]}
