# api/routes/locations.py
"""GET /orgs/{org_id}/locations (discovery) and PATCH /locations/{id}
(settings — name/target_fc_pct/drift_threshold_pct, the legacy /api/settings
equivalent now that settings live as columns on `locations`, Phase 1a)."""
import uuid
from fastapi import APIRouter, Depends, HTTPException, Request
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.models import LocationPatch

router = APIRouter()


async def _require_member_org(conn, org_id):
    """Same 404-for-unknown-and-non-member pattern as
    api/routes/sync.py::_require_member_org: RLS hides the row for both
    cases alike, and a zero-location org is a legitimate member state, so an
    empty list can't be trusted to mean "not a member"."""
    cur = await conn.execute("SELECT 1 FROM organizations WHERE id = %s", (org_id,))
    if await cur.fetchone() is None:
        raise HTTPException(404, "organization not found")


@router.get("/orgs/{org_id}/locations")
async def list_locations(org_id: uuid.UUID, request: Request,
                         caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_member_org(conn, org_id)
        cur = await conn.execute(
            "SELECT id::text, name, target_fc_pct::text, drift_threshold_pct::text"
            " FROM locations WHERE org_id = %s ORDER BY name, id", (org_id,))
        rows = await cur.fetchall()
    return [dict(id=r[0], name=r[1], target_fc_pct=r[2], drift_threshold_pct=r[3])
            for r in rows]


@router.patch("/locations/{location_id}")
async def update_location(location_id: uuid.UUID, body: LocationPatch,
                          request: Request,
                          caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        # Same membership-join role check as merge_ingredients
        # (api/routes/ingredients.py:157-163): RLS makes unknown/cross-org
        # locations invisible to this join, so it also carries the 404.
        cur = await conn.execute(
            "SELECT m.role FROM memberships m"
            " JOIN locations l ON l.org_id = m.org_id"
            " WHERE l.id = %s AND m.user_id = %s", (location_id, caller.user_id))
        row = await cur.fetchone()
        if row is None:
            raise HTTPException(404, "location not found")
        if row[0] not in ("owner", "manager"):
            raise HTTPException(403, "updating location settings requires owner or manager")
        fields = body.model_dump(exclude_unset=True)
        sets = ", ".join(f"{k} = %s" for k in fields)
        cur = await conn.execute(
            f"UPDATE locations SET {sets} WHERE id = %s"
            " RETURNING id::text, name, target_fc_pct::text, drift_threshold_pct::text",
            (*fields.values(), location_id))
        row = await cur.fetchone()
    return dict(id=row[0], name=row[1], target_fc_pct=row[2], drift_threshold_pct=row[3])
