import uuid
from decimal import Decimal
from fractions import Fraction
from fastapi import APIRouter, Depends, HTTPException, Request
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.kernel import round_half_away
from api.services import costing

router = APIRouter()


@router.get("/locations/{location_id}/dashboard")
async def dashboard(location_id: uuid.UUID, request: Request,
                    caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "SELECT name, drift_threshold_pct FROM locations WHERE id = %s",
            (location_id,))
        loc = await cur.fetchone()
        if loc is None:
            raise HTTPException(404, "location not found")
        loc_name, threshold = loc
        drift_map = await costing.location_drift(conn, location_id)
        cur = await conn.execute(
            "SELECT id::text, name, vendor, category FROM ingredients"
            " WHERE location_id = %s AND deleted_at IS NULL ORDER BY name, id",
            (location_id,))
        ingredients = await cur.fetchall()
        menu_items = await costing.cost_recipes(conn, location_id, drift_map)

    movers = []
    for iid, name, vendor, category in ingredients:
        d = drift_map.get(iid)
        if d is None or d.drift_pct is None:      # no purchases / below floor
            continue
        movers.append(dict(
            ingredient_id=iid, name=name, vendor=vendor, category=category,
            latest_price=str(d.latest_price), trailing_avg=str(d.trailing_avg),
            drift_pct=str(d.drift_pct), baseline_n=d.baseline_n,
            direction="up" if d.drift_pct > 0 else "down"))
    # legacy sort, made deterministic: |drift| desc, then name, then id
    movers.sort(key=lambda m: (-abs(Decimal(m["drift_pct"])),
                               m["name"], m["ingredient_id"]))
    alerts = [m for m in movers if abs(Decimal(m["drift_pct"])) >= threshold]

    complete_items = [m for m in menu_items if m["complete"]]
    if complete_items:
        avg = Fraction(sum(Fraction(m["fc_pct"]) for m in complete_items),
                       len(complete_items))
        avg_fc = str(round_half_away(avg, 1))
    else:
        avg_fc = None
    return dict(
        location=dict(id=str(location_id), name=loc_name,
                      drift_threshold_pct=str(threshold)),
        alerts=alerts, top_movers=movers[:5], menu_items=menu_items,
        summary=dict(
            total_alerts=len(alerts), avg_fc_pct=avg_fc,
            danger_count=sum(1 for m in complete_items if m["status"] == "danger"),
            watch_count=sum(1 for m in complete_items if m["status"] == "watch"),
            ok_count=sum(1 for m in complete_items if m["status"] == "ok"),
            incomplete_count=sum(1 for m in menu_items if not m["complete"]),
            drift_threshold_pct=str(threshold)))
