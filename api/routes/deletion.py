# api/routes/deletion.py
"""Account deletion, organization deletion, and the org data export.

App Store guideline 5.1.1(v) makes in-app account deletion mandatory. Getting
it wrong in the other direction -- destroying data that should have survived,
or reporting success while the data is still there -- is unrecoverable for the
user, so every path here is written to fail loudly rather than quietly.

Two operations, deliberately asymmetric:

  DELETE /me                      immediate. Memberships + profile + the
                                  caller's own single-use tokens. Refused if
                                  the caller is the sole owner of an org that
                                  is not itself already scheduled for
                                  deletion.
  POST   /orgs/{id}/deletion      owner-only, 30-day grace. Stripe
                                  cancellation happens IMMEDIATELY on confirm.
  DELETE /orgs/{id}/deletion      owner-only, cancels -- strictly inside the
                                  window.
  GET    /orgs/{id}/export        owner-only zip of the org's data.

WHAT DELETE /me DOES NOT DO, stated plainly: it does not remove the
`auth.users` row. It cannot. Migration 0003 deliberately grants nothing on
`auth.users` (a `GRANT SELECT` there was measured to leak every tenant's user
list), and on Supabase that table is owned by `supabase_auth_admin`, so a
migration running as `postgres` cannot grant itself access either -- the
statement would fail at deploy time. Removing the identity itself requires
Supabase's Admin API (`auth.admin.deleteUser`) from the service role, which is
an HTTP call from a privileged context that does not exist in this phase.
Until it does, a "deleted" user can still obtain a JWT and will see an empty
account. That is a real gap against 5.1.1(v) and is carried to Task 12.
"""
import logging
import os
import uuid
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Request, Response

from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.routes import members
from api.services.apple import revoke_apple_token
from api.services.billing import BillingError, cancel_subscription
from api.services.export import ExportError, build_export

log = logging.getLogger(__name__)
router = APIRouter()

GRACE_DAYS = 30
GRACE = timedelta(days=GRACE_DAYS)

# How many times `_lock_caller_orgs` will re-read and re-lock before giving up.
# It converges on the first retry in every realistic case; the cap only exists
# so a pathological loop cannot spin forever holding locks.
_LOCK_ATTEMPTS = 5


# ---------------------------------------------------------------------------
# DELETE /me
# ---------------------------------------------------------------------------
async def _caller_org_ids(conn, user_id: str) -> list[uuid.UUID]:
    cur = await conn.execute(
        "SELECT org_id FROM memberships WHERE user_id = %s ORDER BY org_id", (user_id,)
    )
    return [r[0] for r in await cur.fetchall()]


async def _lock_caller_orgs(conn, user_id: str) -> list[uuid.UUID]:
    """Take the org advisory lock on every org the caller belongs to.

    Uses `api.routes.members._lock_org` rather than re-deriving the key.
    Correction 2 of this task's brief exists because Task 9 needed three
    rounds to get four call sites to agree on
    `hashtextextended(org_id::text, 0)`; calling the same function is the
    only way to guarantee a fifth one cannot drift. Passing a `uuid.UUID`
    (never a raw path string) is the third round's fix -- `_lock_org`'s
    docstring has the reproduction.

    Locks are taken in ORDER BY org_id, matching `purge_scheduled_orgs`, so
    two callers deleting their accounts out of overlapping org sets -- or a
    caller racing the purge -- can never deadlock.

    Read-then-lock has a gap: a membership committed between the read and
    the lock would be deleted below without its org ever having been locked,
    which is exactly how an org loses its last owner. So the set is re-read
    AFTER locking and the whole thing repeats until two consecutive reads
    agree. Reaching that fixed point is what makes the owner counts below
    trustworthy.
    """
    locked: list[uuid.UUID] = []
    for _ in range(_LOCK_ATTEMPTS):
        fresh = await _caller_org_ids(conn, user_id)
        if fresh == locked:
            return locked
        locked = fresh
        for org_id in locked:
            await members._lock_org(conn, org_id)
    raise HTTPException(
        409,
        "your organization memberships are changing concurrently; retry the "
        "account deletion",
    )


async def _sole_owner_blocking_orgs(conn, user_id: str) -> list[str]:
    """Orgs this deletion must not be allowed to orphan.

    An org the caller is the ONLY owner of blocks the deletion -- unless it
    is already scheduled for deletion itself, in which case there is nothing
    left to orphan and blocking would trap a user who has already asked to
    leave behind a 30-day wall. A 30-day block is a deactivation, not a
    deletion, and would fail 5.1.1(v) for exactly the user who most needs it.

    THE CASCADE TRAP: `memberships` cascades from BOTH `auth.users` and
    `organizations` (0002), so deleting either parent row strips memberships
    with no lock and no owner-count guard at all -- bypassing every
    protection Task 9 built. This function is the guard on the only cascade
    parent this endpoint could ever reach, and it is deliberately evaluated
    only AFTER `_lock_caller_orgs` has reached its fixed point: unlocked,
    two owners of one org each see a count of 2 (neither sees the other's
    uncommitted DELETE under READ COMMITTED), both conclude they are not the
    last owner, and both commit. Textbook write skew, zero owners, an org
    nobody can ever administer or delete again.
    """
    cur = await conn.execute(
        "SELECT m.org_id::text FROM memberships m "
        "JOIN organizations o ON o.id = m.org_id "
        "WHERE m.user_id = %s AND m.role = 'owner' "
        "  AND o.deletion_scheduled_at IS NULL "
        "  AND (SELECT count(*) FROM memberships x "
        "        WHERE x.org_id = m.org_id AND x.role = 'owner') = 1 "
        "ORDER BY m.org_id",
        (user_id,),
    )
    return [r[0] for r in await cur.fetchall()]


async def _purge_caller_rows(conn, user_id: str, orgs: list[uuid.UUID]) -> int:
    """Remove everything this connection is actually able to remove.

    Scoped to `orgs` -- the set `_lock_caller_orgs` locked and reached a
    fixed point on -- so this can never delete a membership whose org was
    not locked and owner-counted, no matter what committed in between. The
    rowcount is checked against that same set: `memberships` is under FORCE
    RLS and, before migration 0007's `membership_self_leave`, a non-owner
    deleting their own row matched ZERO rows while the handler cheerfully
    returned 200. Never report a deletion that did not happen.
    """
    cur = await conn.execute(
        "DELETE FROM memberships WHERE user_id = %s AND org_id = ANY(%s)",
        (user_id, orgs),
    )
    removed = cur.rowcount
    if removed != len(orgs):
        raise HTTPException(
            500,
            f"expected to remove {len(orgs)} membership(s) but removed {removed}; "
            "refusing to report a deletion that did not happen",
        )
    # Single-use tokens the caller owns. Both cascade from `auth.users`,
    # which this endpoint cannot delete, so without this they outlive the
    # profile they belong to.
    await conn.execute("DELETE FROM email_verifications WHERE user_id = %s", (user_id,))
    await conn.execute(
        "DELETE FROM apple_link_requests WHERE apple_sub = %s", (user_id,)
    )
    await conn.execute("DELETE FROM profiles WHERE user_id = %s", (user_id,))
    return removed


async def _revoke_apple(apple_sub: str | None) -> bool | None:
    """Apple requires SIWA token revocation on account deletion.

    NON-BLOCKING by decision (Task 10's recommendation, ratified in this
    task's corrections): a user who asked to be deleted must not be trapped
    because Apple's endpoint is down. Every failure is logged and returned as
    `False` so the response can say so; nothing here can abort the deletion.

    Dormant today. Apple linking is descoped to Phase 2a, so
    `profiles.apple_sub` is always NULL and this returns None without
    touching the network. It is also NOT yet correct for production: the
    refresh token is per-user and is read here from `APPLE_REFRESH_TOKEN`
    (the plan's own placeholder) because no column stores it. Phase 2a must
    add `profiles.apple_refresh_token` and read it from the row, not the
    environment.
    """
    if not apple_sub:
        return None
    refresh_token = os.environ.get("APPLE_REFRESH_TOKEN")
    client_id = os.environ.get("APPLE_CLIENT_ID")
    client_secret = os.environ.get("APPLE_CLIENT_SECRET")
    if not (refresh_token and client_id and client_secret):
        log.error(
            "apple_sub is set for a deleting account but Apple revocation is not "
            "configured; the Apple token was NOT revoked"
        )
        return False
    try:
        await revoke_apple_token(
            refresh_token, client_id=client_id, client_secret=client_secret
        )
        return True
    except Exception:
        # Deliberately total, not just AppleRevokeError: a timeout, a DNS
        # failure or a TLS error out of httpx must be exactly as non-blocking
        # as a 4xx from Apple. Nothing a third party does may strand a user
        # inside their own deletion.
        log.exception("Apple token revocation failed; continuing with the deletion")
        return False


@router.delete("/me")
async def delete_account(request: Request, caller: CallerIdentity = Depends(require_caller)):
    """Remove the caller's memberships and profile.

    If they are the last owner of a live organization, refuse and route them
    to organization deletion rather than orphaning it.
    """
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "SELECT apple_sub FROM profiles WHERE user_id = %s", (caller.user_id,)
        )
        row = await cur.fetchone()
        apple_sub = row[0] if row else None

        orgs = await _lock_caller_orgs(conn, caller.user_id)
        blocking = await _sole_owner_blocking_orgs(conn, caller.user_id)
        if blocking:
            raise HTTPException(
                409,
                detail={
                    "detail": "You are the last owner of an organization. Delete the "
                              "organization, or transfer ownership first.",
                    "orgs_requiring_deletion": blocking,
                },
            )
        removed = await _purge_caller_rows(conn, caller.user_id, orgs)

    # After the commit: a third-party call must not be able to roll back a
    # deletion the user already asked for and the database already performed.
    apple_revoked = await _revoke_apple(apple_sub)
    return {
        "deleted": "membership",
        "memberships_removed": removed,
        "apple_revoked": apple_revoked,
        "identity_removed": False,
        "detail": "Memberships and profile removed. The sign-in identity itself is "
                  "removed by the account-purge job.",
    }


# ---------------------------------------------------------------------------
# POST /orgs/{org_id}/deletion
# ---------------------------------------------------------------------------
@router.post("/orgs/{org_id}/deletion")
async def schedule_org_deletion(
    org_id: uuid.UUID, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        # Lock BEFORE the owner check, not after. The check has to be inside
        # the lock or a cancel can pass its own owner check against a
        # membership that a concurrent DELETE /me is about to remove, block,
        # and then un-schedule an org that no longer has any owner at all.
        # The cost is that a non-owner can briefly hold an advisory lock on
        # an org id they already know; the transaction is three statements
        # long, so there is nothing to stretch.
        await members._lock_org(conn, org_id)
        await members._require_owner(conn, caller.user_id, org_id)
        cur = await conn.execute(
            "SELECT deletion_scheduled_at, stripe_customer_id, billing_cancelled_at "
            "FROM organizations WHERE id = %s",
            (org_id,),
        )
        row = await cur.fetchone()
        if row is None:
            raise HTTPException(404, "organization not found")
        scheduled_at, customer_id, billing_cancelled_at = row
        already_scheduled = scheduled_at is not None
        if not already_scheduled:
            # `WHERE ... IS NULL` as well as the lock: re-confirming must not
            # refresh the timestamp. Refreshing it would silently restart the
            # 30 days, so a device retrying a request it never saw the
            # response to could keep a doomed org alive indefinitely.
            cur = await conn.execute(
                "UPDATE organizations SET deletion_scheduled_at = now() "
                "WHERE id = %s AND deletion_scheduled_at IS NULL "
                "RETURNING deletion_scheduled_at",
                (org_id,),
            )
            updated = await cur.fetchone()
            if updated is None:
                raise HTTPException(500, "could not schedule the deletion")
            scheduled_at = updated[0]

    warnings: list[str] = []
    billing_cancelled = billing_cancelled_at is not None
    if not already_scheduled:
        # Side effects run AFTER the commit, and only on the transition. A
        # cancellation issued for a transaction that then rolled back would
        # stop a live customer's billing for an org that was never scheduled.
        try:
            # Blocking Stripe HTTP calls: `cancel_subscription` now runs its
            # synchronous stripe-python work on a worker thread (see
            # api/services/billing.py) instead of stalling the event loop for
            # the length of a third-party round trip.
            await cancel_subscription(customer_id)
            billing_cancelled = True
        except BillingError:
            log.exception(
                "billing cancellation FAILED for org %s during deletion; the "
                "deletion stands but the subscription may still be live",
                org_id,
            )
            warnings.append(
                "Subscription cancellation failed and must be completed manually; "
                "the organization is still scheduled for deletion."
            )

    if billing_cancelled and billing_cancelled_at is None:
        async with tenant_connection(request.app.state.pool, caller.claims) as conn:
            await conn.execute(
                "UPDATE organizations SET billing_cancelled_at = now() "
                "WHERE id = %s AND billing_cancelled_at IS NULL",
                (org_id,),
            )

    return {
        "scheduled": True,
        "scheduled_at": scheduled_at.isoformat(),
        "purge_after_days": GRACE_DAYS,
        "billing_cancelled": billing_cancelled,
        "warnings": warnings,
    }


# ---------------------------------------------------------------------------
# DELETE /orgs/{org_id}/deletion
# ---------------------------------------------------------------------------
@router.delete("/orgs/{org_id}/deletion")
async def cancel_org_deletion(
    org_id: uuid.UUID, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await members._lock_org(conn, org_id)
        await members._require_owner(conn, caller.user_id, org_id)
        cur = await conn.execute(
            "SELECT deletion_scheduled_at, "
            "       deletion_scheduled_at > now() - %s::interval "
            "FROM organizations WHERE id = %s",
            (GRACE, org_id),
        )
        row = await cur.fetchone()
        if row is None:
            raise HTTPException(404, "organization not found")
        scheduled_at, within_window = row
        if scheduled_at is None:
            raise HTTPException(404, "this organization is not scheduled for deletion")
        if not within_window:
            # The window has elapsed; the only reason this org still exists is
            # that the purge job has not run yet. Cancelling in that gap
            # resurrects a deletion that was already final -- and the Stripe
            # subscription cancelled 30 days ago does not come back with it.
            raise HTTPException(
                410,
                f"the {GRACE_DAYS}-day grace window has elapsed; this deletion can "
                "no longer be cancelled",
            )
        cur = await conn.execute(
            "UPDATE organizations "
            "   SET deletion_scheduled_at = NULL, billing_cancelled_at = NULL "
            " WHERE id = %s AND deletion_scheduled_at IS NOT NULL",
            (org_id,),
        )
        if cur.rowcount != 1:
            raise HTTPException(409, "the deletion could not be cancelled; retry")
    return {
        "cancelled": True,
        "subscription_restored": False,
        "detail": "The organization is no longer scheduled for deletion. Any "
                  "subscription cancelled when the deletion was confirmed was NOT "
                  "restored and must be re-created.",
    }


# ---------------------------------------------------------------------------
# GET /orgs/{org_id}/export
# ---------------------------------------------------------------------------
@router.get("/orgs/{org_id}/export")
async def export_org(
    org_id: uuid.UUID, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    """The user's last copy of their data before an irreversible purge.

    Owner-only, and that is a correctness requirement rather than mere
    caution: `invites` is owner-scoped under RLS (0004's `invite_all`), so
    running `build_export` on a manager's or bookkeeper's
    `tenant_connection` silently produces a zip whose `invites.csv` contains
    only its header -- an export that looks complete, is not, and is handed
    over immediately before the data it omits is destroyed forever.

    Nothing is persisted to disk. `build_export` returns bytes and they are
    streamed straight into this response, so there is no half-written export
    file for a user to mistake for their last copy. Reads are also never
    blocked by the deletion guard, so this stays available for the whole
    grace window.
    """
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await members._require_owner(conn, caller.user_id, org_id)
        try:
            blob = await build_export(conn, org_id)
        except ExportError as exc:
            log.exception("export failed for org %s", org_id)
            raise HTTPException(500, f"could not build a complete export: {exc}")
    return Response(
        blob,
        media_type="application/zip",
        headers={
            "Content-Disposition": f'attachment; filename="costsauce-export-{org_id}.zip"',
            "X-Content-Type-Options": "nosniff",
        },
    )
