# api/routes/members.py
import hashlib
import os
import secrets
import uuid
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


async def _require_owner(conn, user_id: str, org_id: uuid.UUID):
    cur = await conn.execute(
        "SELECT 1 FROM memberships WHERE org_id = %s AND user_id = %s AND role = 'owner'",
        (org_id, user_id),
    )
    if not await cur.fetchone():
        raise HTTPException(403, "owner role required")


async def _lock_org(conn, org_id: uuid.UUID) -> None:
    """Serialize every owner-count-sensitive decision for one org.

    Critical-2 fix (Task 9 review round 1): `_owner_count` alone is an
    unlocked `SELECT count(*)`. Under READ COMMITTED, two concurrent
    transactions each removing/demoting a DIFFERENT owner row of the SAME
    org neither sees the other's uncommitted change, both read the same
    stale higher count, both pass their own last-owner check, both commit --
    zero owners survive. This is textbook write skew; a plain re-check
    (even inside a trigger) does not fix it without an actual lock, because
    the same READ COMMITTED visibility rules apply there too.

    Round 1 used `SELECT 1 FROM organizations WHERE id = %s FOR UPDATE` --
    review round 2 found this looked correct here (this role, `authenticated`,
    genuinely has both the grant and a matching RLS policy on organizations)
    but was silently broken in migration 0006's accept_invite_tx, which runs
    as `invite_definer`: Postgres requires an UPDATE policy (not just SELECT)
    to satisfy `FOR UPDATE`, `invite_definer` only had a SELECT policy, RLS
    filtered the row out, and the lock was never taken -- `FOR UPDATE` fails
    OPEN, not closed. Switched to `pg_advisory_xact_lock`, which is NOT
    subject to RLS at all (no policy/grant to ever get out of sync again),
    used with the IDENTICAL key derivation in the SQL function -- row locks
    and advisory locks are two independent locking systems that do not
    interact, so all four call sites (this file's create_invite max_members
    check, change_role, remove_member, and 0006's accept_invite_tx) MUST use
    the same lock to actually serialize against each other.

    A concurrent second transaction touching the same org blocks here until
    the first commits (xact-scoped: released automatically at
    COMMIT/ROLLBACK), then reads counts fresh against the now-committed
    state -- closing the race for any pair of these four operations on one
    org, without affecting concurrency across different orgs at all.

    Round 3 found a THIRD way this can fail: `hashtextextended` hashes
    whatever TEXT it is given, and a `uuid` compared/cast in a WHERE clause
    is normalized by Postgres, but a hash of the raw client-supplied string
    is not -- "0198f1a2-...", "0198F1A2-...", the same value with no
    hyphens, and the same value wrapped in braces all hash to FOUR DIFFERENT
    keys, even though every one of them resolves to the identical `uuid` row
    everywhere else in this file. Before this fix, `org_id` arrived here as
    whatever string FastAPI pulled off the URL path, unvalidated. Reproduced
    live: a SINGLE owner, one JWT, no second actor -- two concurrent
    `DELETE .../members/<id>` requests for the SAME org, one spelled
    lowercase and one spelled uppercase in the URL, BOTH succeeded, final
    owner count 0. Round 1's row lock never had this problem (`WHERE id =
    %s` against a `uuid` column coerces every spelling to the same value);
    switching to an advisory lock on raw text is what introduced it.

    Fixed at the boundary, not here: every route in this file now types its
    `org_id`/`user_id` path parameters as `uuid.UUID` (see create_invite,
    change_role, remove_member below), so FastAPI/Pydantic parses and
    normalizes every valid spelling to the same object before any handler
    runs -- `str(uuid.UUID(...))` is always canonical lowercase-hyphenated
    form, so whatever reaches this function (and therefore whatever
    `hashtextextended` hashes) is already uniform, regardless of how the
    caller originally spelled it in the URL. This also means a malformed id
    in the URL now 422s automatically instead of reaching Postgres and
    500ing.
    """
    await conn.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(%s::text, 0))", (org_id,)
    )


async def _owner_count(conn, org_id: uuid.UUID) -> int:
    cur = await conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'", (org_id,)
    )
    (n,) = await cur.fetchone()
    return n


async def _check_member_limit(conn, org_id: uuid.UUID) -> None:
    """Refuse to create another invite if doing so would exceed the org's
    plan's max_members.

    PLAN_LIMITS is the single source of the numbers -- nothing here
    hardcodes starter/growth/pro limits. The count is memberships PLUS
    pending (unaccepted, unexpired) invites: counting accepted members
    alone would let an owner fire off ten invites in one sitting and blow
    straight past the limit the moment they are all accepted.

    Important-4 fix: this used to be an unlocked read, so N concurrent
    POST /invites at count == limit-1 could all read the same pre-insert
    count and all pass. `_lock_org` closes it the same way as Critical-2.
    """
    await _lock_org(conn, org_id)
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
    org_id: uuid.UUID, body: InviteIn, request: Request,
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
    response = {"invite_id": str(invite_id)}
    # Review round 2, Important-3 (second half): the raw token in this
    # response is the ONLY channel by which a token reaches anyone but the
    # requesting owner today (no mailer exists until Phase 3). Gated behind
    # an explicit env flag the same way reviewer_otp is gated
    # (api/routes/identity.py) -- read at REQUEST time, not at import time,
    # so tests can monkeypatch it per-session (see tests/conftest.py's
    # app_client fixture) while a real deployment defaults to OFF and never
    # leaks it. Until Phase 3 wires actual delivery, this means invite
    # acceptance depends on a token that isn't mailed to anyone -- that is
    # the correct, honest state: the flow is incomplete until delivery
    # exists, and it must fail closed (no token echoed) rather than be
    # permissive in the meantime.
    if os.environ.get("RETURN_INVITE_TOKEN_ENABLED") == "1":
        response["token"] = token
    return response


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
    # by an unguessable token hash whose caller-derived email must match,
    # writing only the caller's own membership -- the function derives the
    # caller's user_id itself (public.current_user_id(), same GUC
    # tenant_connection sets), it is not passed in as an argument.
    token_hash = hashlib.sha256(body.token.encode()).hexdigest()
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "SELECT status, out_org_id, out_role FROM accept_invite_tx(%s)",
            (token_hash,),
        )
        status, org_id, role = await cur.fetchone()
    if status == "invalid":
        raise HTTPException(400, "invalid, expired, or already-used invite")
    if status == "last_owner_conflict":
        raise HTTPException(409, "cannot demote the last owner")
    return {"org_id": str(org_id), "role": role}


@router.patch("/orgs/{org_id}/members/{user_id}")
async def change_role(
    org_id: uuid.UUID, user_id: uuid.UUID, body: RoleIn, request: Request,
    caller: CallerIdentity = Depends(require_caller),
):
    if body.role not in ROLES:
        raise HTTPException(422, "unknown role")
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        await _lock_org(conn, org_id)
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
    org_id: uuid.UUID, user_id: uuid.UUID, request: Request,
    caller: CallerIdentity = Depends(require_caller),
):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        await _lock_org(conn, org_id)
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
