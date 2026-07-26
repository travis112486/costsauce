# api/routes/members.py
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, EmailStr
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.models import PLAN_LIMITS

router = APIRouter()
ROLES = ("owner", "manager", "bookkeeper")


class InviteIn(BaseModel):
    email: EmailStr
    role: str


class AcceptIn(BaseModel):
    token: str


class RoleIn(BaseModel):
    role: str


async def _require_owner(conn, user_id: str, org_id: str):
    cur = await conn.execute(
        "SELECT 1 FROM memberships WHERE org_id = %s AND user_id = %s AND role = 'owner'",
        (org_id, user_id),
    )
    if not await cur.fetchone():
        raise HTTPException(403, "owner role required")


async def _owner_count(conn, org_id: str) -> int:
    cur = await conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'", (org_id,)
    )
    (n,) = await cur.fetchone()
    return n


async def _check_member_limit(conn, org_id: str) -> None:
    """Refuse to create another invite if doing so would exceed the org's
    plan's max_members.

    PLAN_LIMITS is the single source of the numbers -- nothing here
    hardcodes starter/growth/pro limits. The count is memberships PLUS
    pending (unaccepted, unexpired) invites: counting accepted members
    alone would let an owner fire off ten invites in one sitting and blow
    straight past the limit the moment they are all accepted.
    """
    cur = await conn.execute("SELECT plan FROM organizations WHERE id = %s", (org_id,))
    row = await cur.fetchone()
    if not row:
        raise HTTPException(403, "owner role required")
    (plan,) = row
    limit = PLAN_LIMITS[plan]["max_members"]
    if limit is None:
        return
    cur = await conn.execute(
        "SELECT "
        "(SELECT count(*) FROM memberships WHERE org_id = %s) + "
        "(SELECT count(*) FROM invites "
        " WHERE org_id = %s AND accepted_at IS NULL AND expires_at > now())",
        (org_id, org_id),
    )
    (current_count,) = await cur.fetchone()
    if current_count >= limit:
        raise HTTPException(
            402,
            f"The {plan} plan allows up to {limit} member(s) (counting pending "
            f"invites); this organization already has {current_count}. "
            "Upgrade the plan to invite more members.",
        )


@router.post("/orgs/{org_id}/invites")
async def create_invite(
    org_id: str, body: InviteIn, request: Request,
    caller: CallerIdentity = Depends(require_caller),
):
    if body.role not in ROLES:
        raise HTTPException(422, "unknown role")
    token = secrets.token_urlsafe(32)
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        await _check_member_limit(conn, org_id)
        cur = await conn.execute(
            "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
            (org_id, body.email, body.role, hashlib.sha256(token.encode()).hexdigest(),
             caller.user_id, datetime.now(timezone.utc) + timedelta(days=7)),
        )
        (invite_id,) = await cur.fetchone()
    return {"invite_id": str(invite_id), "token": token}


@router.post("/invites/accept")
async def accept_invite(
    body: AcceptIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    # The invitee has no membership yet, so RLS cannot see the invite row
    # (owner-only `invite_all`). This IS the one deliberate elevated path in
    # the phase -- but "elevated" is implemented as a narrow SECURITY DEFINER
    # SQL function (migration 0006's accept_invite_tx, owned by a dedicated
    # NOLOGIN role), not as a bare pool.connection(). That literal approach
    # was tried first and does not work: app.state.pool authenticates as
    # app_user, which is NOINHERIT and holds no grants of its own -- every
    # relevant GRANT targets `authenticated`, reachable only via the
    # `SET ROLE` tenant_connection performs. A raw connection that skips
    # tenant_connection therefore cannot even see the tables (confirmed:
    # every query fails with `relation "invites" does not exist`), so this
    # goes through tenant_connection like everything else and lets the one
    # narrow SQL function do the bypassing. It is still one row, found only
    # by an unguessable token hash, writing only the caller's own membership.
    token_hash = hashlib.sha256(body.token.encode()).hexdigest()
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "SELECT status, out_org_id, out_role FROM accept_invite_tx(%s, %s)",
            (token_hash, caller.user_id),
        )
        status, org_id, role = await cur.fetchone()
    if status == "invalid":
        raise HTTPException(400, "invalid, expired, or already-used invite")
    if status == "last_owner_conflict":
        raise HTTPException(409, "cannot demote the last owner")
    return {"org_id": str(org_id), "role": role}


@router.patch("/orgs/{org_id}/members/{user_id}")
async def change_role(
    org_id: str, user_id: str, body: RoleIn, request: Request,
    caller: CallerIdentity = Depends(require_caller),
):
    if body.role not in ROLES:
        raise HTTPException(422, "unknown role")
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        if body.role != "owner" and await _owner_count(conn, org_id) == 1:
            cur = await conn.execute(
                "SELECT 1 FROM memberships WHERE org_id = %s AND user_id = %s AND role = 'owner'",
                (org_id, user_id),
            )
            if await cur.fetchone():
                raise HTTPException(409, "cannot demote the last owner")
        cur = await conn.execute(
            "UPDATE memberships SET role = %s WHERE org_id = %s AND user_id = %s",
            (body.role, org_id, user_id),
        )
        # Self-review finding: without this check, changing the role of a
        # user_id that is not actually a member of this org silently updates
        # zero rows and still reports 200 {"role": ...} -- a false success
        # (the same class of defect Task 7 review caught in
        # set_contact_email). remove_member already guards this via its own
        # SELECT; change_role needs the same guarantee.
        if cur.rowcount != 1:
            raise HTTPException(404, "member not found")
    return {"role": body.role}


@router.delete("/orgs/{org_id}/members/{user_id}")
async def remove_member(
    org_id: str, user_id: str, request: Request,
    caller: CallerIdentity = Depends(require_caller),
):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        cur = await conn.execute(
            "SELECT role FROM memberships WHERE org_id = %s AND user_id = %s", (org_id, user_id)
        )
        row = await cur.fetchone()
        if not row:
            raise HTTPException(404, "member not found")
        if row[0] == "owner" and await _owner_count(conn, org_id) == 1:
            raise HTTPException(409, "cannot remove the last owner; delete the organization instead")
        await conn.execute(
            "DELETE FROM memberships WHERE org_id = %s AND user_id = %s", (org_id, user_id)
        )
    return {"removed": True}
