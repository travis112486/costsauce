# api/routes/me.py
from fastapi import APIRouter, Depends, Request
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.models import EntitlementOut, MeResponse, MembershipOut, PLAN_LIMITS

router = APIRouter()


@router.get("/me", response_model=MeResponse)
async def me(request: Request, caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "SELECT contact_email, contact_email_verified_at IS NOT NULL, apple_sub IS NOT NULL "
            "FROM profiles WHERE user_id = %s",
            (caller.user_id,),
        )
        row = await cur.fetchone()
        contact_email, verified, apple_linked = row if row else (None, False, False)

        cur = await conn.execute(
            "SELECT o.id::text, o.name, m.role, o.plan "
            "FROM memberships m JOIN organizations o ON o.id = m.org_id "
            "WHERE m.user_id = %s ORDER BY o.name",
            (caller.user_id,),
        )
        rows = await cur.fetchall()

    memberships = [MembershipOut(org_id=r[0], org_name=r[1], role=r[2]) for r in rows]
    plan = rows[0][3] if rows else "starter"
    return MeResponse(
        user_id=caller.user_id,
        contact_email=contact_email,
        contact_email_verified=bool(verified),
        apple_linked=bool(apple_linked),
        memberships=memberships,
        entitlement=EntitlementOut(plan=plan, **PLAN_LIMITS[plan]),
    )
