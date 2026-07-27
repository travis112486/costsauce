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
    """Remove everything this connection is able to remove, and refuse the
    whole deletion if that is not exactly the set that was locked.

    The DELETE is unscoped so nothing can be left behind, and its RETURNING
    set is then compared against `orgs` -- what `_lock_caller_orgs` actually
    locked and owner-counted. Both halves are load-bearing, and each closes a
    defect the other version had:

    * SCOPED (`org_id = ANY(orgs)`) -- review round 1, Critical-1. A
      membership committed AFTER the fixed point falls outside the scope, so
      `DELETE /me` returned 200 with a LIVE membership surviving in another
      tenant's org and no `profiles` row: `GET /me` renders a null
      contact_email and that org's `members.csv` exports a NULL address.
    * UNSCOPED WITH NO COMPARISON -- review round 2, Critical. The opposite
      failure, and worse. Such a DELETE removes memberships in orgs this
      transaction never locked or owner-counted, re-opening the zero-owner
      write skew Task 9 needed three rounds to close. Reproduced: Alice is
      offered a SECOND-owner seat in Bistro; her `DELETE /me` fixes its point
      at {Acme}; she accepts the Bistro owner invite in an independent
      transaction; Bistro's original owner Bob then locks Bistro, counts two
      owners and leaves; Alice's unscoped DELETE removes her Bistro owner row
      without ever holding Bistro's lock. Final state: Bistro with zero
      members, zero owners and `deletion_scheduled_at` NULL -- invisible to
      every tenant under RLS, administrable by nobody, and never enumerated
      by `purge_scheduled_orgs`. Both callers got 200.

    So an org in the RETURNING set that is not in `orgs` is not an error to
    tolerate, it is proof the caller's membership set moved under us: raise
    409 and let the whole transaction roll back, deleting nothing. This is
    the same contract `_lock_caller_orgs` already uses when its fixed point
    will not converge, and it converges for the same reason -- the retry's
    fixed point includes the new org, so the second attempt locks and
    owner-counts every one of them before deciding anything.

    The surviving-rows check is the last statement before COMMIT and is NOT
    vacuous under RLS. `membership_select` (0004) admits rows whose org is in
    `current_user_memberships()` -- which is derived from the very rows being
    checked for. A survivor is committed and was not deleted here, so the
    re-evaluation sees it and the policy admits it; if none survived the count
    is zero and RLS agrees. Either way the answer is the true one.

    A missing org (locked, but not deleted) is a different animal: it means
    the DELETE could not touch a row this connection had every right to
    remove, which before migration 0007's `membership_self_leave` was exactly
    what happened to every non-owner -- zero rows matched, 200 returned. That
    is a schema/policy fault, not a race, so it is a 500.
    """
    cur = await conn.execute(
        "DELETE FROM memberships WHERE user_id = %s RETURNING org_id", (user_id,)
    )
    deleted_orgs = {r[0] for r in await cur.fetchall()}
    locked_orgs = set(orgs)

    unlocked = deleted_orgs - locked_orgs
    if unlocked:
        raise HTTPException(
            409,
            "your organization memberships are changing concurrently; retry the "
            "account deletion",
        )
    missing = locked_orgs - deleted_orgs
    if missing:
        raise HTTPException(
            500,
            f"{len(missing)} membership(s) could not be removed; refusing to report "
            "a deletion that did not happen",
        )

    # Single-use tokens the caller owns. Both cascade from `auth.users`,
    # which this endpoint cannot delete, so without this they outlive the
    # profile they belong to.
    await conn.execute("DELETE FROM email_verifications WHERE user_id = %s", (user_id,))
    await conn.execute(
        "DELETE FROM apple_link_requests WHERE apple_sub = %s", (user_id,)
    )
    await conn.execute("DELETE FROM profiles WHERE user_id = %s", (user_id,))
    # The tombstone, written in the SAME transaction as the profile delete.
    #
    # Review round 1, Critical-2. This endpoint cannot remove the `auth.users`
    # row (see the module docstring), so the identity survives and something
    # privileged has to finish the job later. Once `profiles` is gone, the ONLY
    # surviving record of the account is that same `auth.users` row -- which no
    # code on the request path can read (0003 grants nothing on it, and on
    # Supabase it is owned by supabase_auth_admin). Without this row, every
    # account deleted before Task 12 lands would be permanently unenumerable,
    # and therefore permanently unpurgeable.
    #
    # `ON CONFLICT DO NOTHING` keeps DELETE /me idempotent for a retrying
    # client. The row's FK cascades from `auth.users`, so it disappears by
    # itself the moment the identity is actually removed -- the table is
    # exactly "identities still awaiting purge", with no second job to keep it
    # tidy.
    await conn.execute(
        "INSERT INTO deleted_accounts (user_id) VALUES (%s) ON CONFLICT DO NOTHING",
        (user_id,),
    )

    # LAST statement before COMMIT, deliberately. Anything committed by another
    # transaction after this point survives, and nothing in this function can
    # change that -- closing it needs a lock keyed on the USER that
    # `accept_invite_tx` also takes, which means changing migration 0006.
    # Keeping this check here shrinks the window to the COMMIT itself rather
    # than the four statements above plus COMMIT (measured at ~6 ms in review,
    # not the "one statement" my round-1 report claimed).
    cur = await conn.execute(
        "SELECT count(*) FROM memberships WHERE user_id = %s", (user_id,)
    )
    (survivors,) = await cur.fetchone()
    if survivors:
        raise HTTPException(
            409,
            "a membership was created while your account was being deleted; retry "
            "the account deletion",
        )
    return len(deleted_orgs)


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
        # Authorize BEFORE locking. Review round 1, Important-3: an earlier
        # version locked first, on the theory that a cancel could otherwise
        # pass its owner check against a membership a concurrent DELETE /me
        # was about to remove and leave an unscheduled, zero-member org. That
        # orphan does not reproduce -- `org_update` (0004) re-evaluates
        # `current_user_memberships()` against the UPDATE's own snapshot, sees
        # the committed membership delete, and filters the row out, which the
        # rowcount check below turns into a refusal. RLS had already closed it.
        #
        # The ordering was not free: locking first lets ANY authenticated
        # caller take and hold the advisory lock on an arbitrary org id --
        # one they have no relationship with, whose existence RLS otherwise
        # hides -- just by POSTing here, serializing every owner-count
        # operation on that org. A non-member must not be able to reach a lock
        # at all, so the owner check comes first.
        await members._require_owner(conn, caller.user_id, org_id)
        await members._lock_org(conn, org_id)
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
                # Review round 2, Minor: this was a 500. Under the org lock a
                # concurrent schedule is impossible, so zero rows here means
                # `org_update` (0004) filtered the row out -- the caller stopped
                # being an owner between `_require_owner` above and this
                # statement, which is precisely what happens when their own
                # `DELETE /me` commits while this request waits on the lock.
                # That is a lost race, not a server fault, and the retry gets
                # the definitive answer (403) from `_require_owner`.
                raise HTTPException(
                    409,
                    "the organization changed while the deletion was being "
                    "scheduled; retry",
                )
            scheduled_at = updated[0]

    warnings: list[str] = []
    billing_cancelled = billing_cancelled_at is not None

    # Review round 1, Important-4: this used to be gated on
    # `not already_scheduled`, so a confirm that failed to cancel billing was
    # unrecoverable through the API -- the retry took the already-scheduled
    # branch, never re-attempted, and returned `billing_cancelled: false` with
    # an EMPTY `warnings` list, quietly downgrading a live discrepancy to
    # silence. The gate is now the durable record itself: as long as
    # `billing_cancelled_at` is NULL there is cancellation still owed, so every
    # confirm re-attempts it and every response carries the warning until it is
    # settled. Re-attempting is safe -- cancelling an already-cancelled
    # subscription lists nothing to cancel.
    if not billing_cancelled:
        # Side effects run AFTER the schedule commits, never before. A
        # cancellation issued for a transaction that then rolled back would
        # stop a live customer's billing for an org that was never scheduled --
        # user-visible harm, and the wrong direction to fail in. The reverse
        # gap (scheduled, billing not yet recorded) is the safe one and is now
        # self-healing: it is exactly the state this block re-enters.
        try:
            # Blocking Stripe HTTP calls: `cancel_subscription` runs its
            # synchronous stripe-python work on a worker thread (see
            # api/services/billing.py) instead of stalling the event loop for
            # the length of a third-party round trip. Deliberately NOT inside
            # the transaction above -- that would hold the org advisory lock
            # across a third-party round trip.
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
                "the organization is still scheduled for deletion. Confirming the "
                "deletion again re-attempts the cancellation."
            )

    if billing_cancelled and billing_cancelled_at is None:
        async with tenant_connection(request.app.state.pool, caller.claims) as conn:
            # `coalesce` makes this idempotent, and RETURNING reports what the
            # row actually holds afterwards rather than what we assumed.
            # Review round 2, Minor: without a rowcount check a zero-row match
            # (org gone, or ownership lost while Stripe was being called) left
            # the response saying `billing_cancelled: true` over a NULL column
            # -- a discrepancy that only Task 12's alert would ever notice.
            cur = await conn.execute(
                "UPDATE organizations "
                "   SET billing_cancelled_at = coalesce(billing_cancelled_at, now()) "
                " WHERE id = %s RETURNING billing_cancelled_at",
                (org_id,),
            )
            recorded = await cur.fetchone()
        if recorded is None:
            # The cancellation DID happen at Stripe, so saying otherwise would
            # be a lie in the other direction. Report it truthfully and say the
            # record is missing; the next confirm settles it, because that path
            # is gated on `billing_cancelled_at IS NULL`.
            log.error(
                "billing cancellation for org %s succeeded but could not be "
                "recorded; billing_cancelled_at is still NULL",
                org_id,
            )
            warnings.append(
                "The subscription was cancelled but this could not be recorded; "
                "confirming the deletion again will settle it."
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
        # Authorize, then lock -- see the note in schedule_org_deletion. The
        # rowcount check on the UPDATE below is what actually makes a cancel
        # racing an ex-owner's account deletion safe: `org_update`'s USING
        # clause is re-evaluated on that statement's own snapshot, so a caller
        # whose membership has just been deleted matches zero rows here.
        await members._require_owner(conn, caller.user_id, org_id)
        await members._lock_org(conn, org_id)
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
