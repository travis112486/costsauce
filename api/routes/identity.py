# api/routes/identity.py
#
# NOTHING IN PHASE 1a CREATES A `profiles` ROW. Read this before concluding
# that contact-email verification is broken -- the symptom shows up here, but
# the cause is upstream and is a scope gap, not a defect in this file.
#
# There is no signup endpoint, no organization-creation endpoint, and no
# trigger on `auth.users` anywhere in this repository. The only
# `INSERT INTO profiles` outside `tests/factories.py` is none; the only
# `INSERT INTO organizations` is migration 0009's sample org. Migration 0004
# states the intent -- "orgs are created out of band (signup, sample
# seeding)" -- and the signup half of that sentence was never built.
#
# The consequence chain, because it terminates a long way from its cause:
#
#   1. A new `auth.users` row has no `profiles` row.
#   2. `set_contact_email` below therefore 404s ("no profile exists for this
#      account yet") -- see its own Important-2 comment, which describes this
#      state as a brand-new Apple sign-in that hasn't onboarded. There is no
#      onboarding.
#   3. `profiles.contact_email_verified_at` therefore stays NULL forever.
#   4. `accept_invite_tx` (migration 0006) reads the caller's contact_email
#      only `WHERE contact_email_verified_at IS NOT NULL`, and folds the
#      email match into the UPDATE that consumes the token -- so the caller
#      matches nothing and every invite comes back `invalid`.
#   5. Invite acceptance is therefore unreachable for any account this
#      deployment can create today, even though issuing invites works.
#
# Spec §16 names both "verified contact email" and "full multi-user roles and
# invites (D7)" as Phase 1a deliverables. Both are built and individually
# tested; what is missing is account provisioning upstream of them. Until
# something creates profiles (Phase 2a's iOS onboarding, a signup route, or a
# Supabase auth hook), every account must be provisioned by hand --
# docs/runbooks/phase-1a-deploy.md §10 and §11 carry the operator procedure,
# including for the App Review reviewer account.
#
# Apple account linking (POST /identity/apple/link-request and
# /apple/link-confirm) is DESCOPED to Phase 2a -- Travis's call, Task 7
# review. The flow is unreachable until the iOS client exists (it needs a
# user who already has a magic-link account to separately sign in with
# Apple), and it was broken three independent ways rather than one. Shipping
# half-working auth endpoints is worse than shipping none: it invites exactly
# the "just link on matching email" shortcut these constraints forbid.
# `apple_link_requests` (migration 0002) and `profiles.apple_sub` stay --
# Phase 2a builds on them. Migration 0004's `apple_link_self` RLS policy is
# left in place too, dormant, with no endpoint reaching it.
#
# Whoever picks this up in Phase 2a needs all three of the following --
# don't rediscover them, they're pinned in Task 7's report
# (.superpowers/sdd/2026-07-25-phase-1a-tenancy-identity-deletion/task-7-report.md,
# "apple_sub coherence"):
#
#   1. A target-account column on `apple_link_requests`. The removed
#      `apple_link_request` had no way to say which EXISTING account a new
#      Apple session wants to connect to -- nothing to send the magic link
#      to. Without this column, cross-account confirm has no destination.
#   2. A SECURITY DEFINER lookup keyed on `token_hash` alone, mirroring the
#      sanctioned `accept_invite` pattern (Task 9) -- token possession is the
#      real authorization proof here, same as an invite. Migration 0004's
#      `apple_link_self` policy (`apple_sub = current_jwt_sub()`) restricts
#      every operation on `apple_link_requests` to rows the CALLER ITSELF
#      created, so a different, existing account can never see or delete a
#      row a brand-new Apple session created -- RLS silently returns zero
#      rows for a token that is, in fact, perfectly valid. Confirmed
#      empirically (Task 7); this is what made the removed endpoints
#      structurally unreachable for their actual purpose.
#   3. Identity resolution that actually consults `apple_sub`. `/me` (and
#      every RLS policy) resolves the caller only via
#      `profiles WHERE user_id = <jwt sub>` -- so even a `profiles.apple_sub`
#      set correctly today grants nothing: a later Apple sign-in still
#      authenticates as its own separate `auth.users` row with its own,
#      still-empty memberships. Linking has to change what a subsequent
#      Apple-sourced JWT resolves to, not just record a pointer nobody reads.
import hashlib
import hmac
import os
import secrets
import time
from datetime import datetime, timedelta, timezone
import jwt
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, EmailStr
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection

router = APIRouter(prefix="/identity")
RELAY_DOMAIN = "privaterelay.appleid.com"


class ContactEmailIn(BaseModel):
    # Review fix (Important-5): plain EmailStr, matching ReviewerOtpIn below --
    # same file, same request-validation role, one answer. The earlier
    # revision special-cased pydantic's email_validator (test_environment=True)
    # to accept the `.test` TLD this project's fixtures use, but that taught
    # production code about tests and left it permanently accepting an
    # undeliverable digest destination. The fix belongs in the test data, not
    # here: tests/test_identity.py uses a real, non-reserved domain
    # (acme.example.com) for anything posted to this field.
    email: EmailStr


class TokenIn(BaseModel):
    token: str


class ReviewerOtpIn(BaseModel):
    # Plain EmailStr, deliberately: it rejects `.test` addresses (see
    # ContactEmailIn's comment above). Task 8's own tests need a real,
    # non-reserved domain (e.g. reviewer@example.com) for this field, or
    # they'll 422 before reviewer_otp ever runs -- that's this validator
    # doing its job, not a routing bug.
    email: EmailStr
    code: str


@router.post("/contact-email")
async def set_contact_email(
    body: ContactEmailIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    # Minor fix: compare against "@" + RELAY_DOMAIN, not a bare suffix match --
    # `endswith(RELAY_DOMAIN)` alone would also reject a real address like
    # "a@notprivaterelay.appleid.com".
    if body.email.lower().endswith("@" + RELAY_DOMAIN):
        raise HTTPException(
            422,
            "An Apple private relay address cannot receive the weekly drift digest. "
            "Enter an address you check directly.",
        )
    token = secrets.token_urlsafe(32)
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "UPDATE profiles SET contact_email = %s, contact_email_verified_at = NULL "
            "WHERE user_id = %s",
            (body.email, caller.user_id),
        )
        # Important-2 fix (round 3): this UPDATE previously went unchecked,
        # so a caller with no `profiles` row yet (e.g. a brand-new Apple
        # sign-in that hasn't onboarded -- see
        # test_apple_signin_with_no_membership_does_not_autocreate_org for
        # exactly this state) got a silent no-op reported as 200 success:
        # nothing was persisted, and no verification token could ever match a
        # profile that doesn't exist. There is no profile to update, which is
        # a 404 (the resource this call targets doesn't exist), not a 409
        # (nothing here conflicts with existing state).
        if cur.rowcount != 1:
            raise HTTPException(404, "no profile exists for this account yet")
        # Important-1 fix: bind the token to the exact address it was issued
        # for. Without this, a stale, still-unexpired token from an earlier
        # call here could later verify whatever address happens to be on the
        # profile *now* -- including one a different party set afterwards
        # that this token's original recipient never consented to.
        await conn.execute(
            "INSERT INTO email_verifications (user_id, email, token_hash, expires_at) "
            "VALUES (%s, %s, %s, %s)",
            (caller.user_id, body.email, hashlib.sha256(token.encode()).hexdigest(),
             datetime.now(timezone.utc) + timedelta(hours=24)),
        )
    # Phase 3 wires actual mail delivery. Nothing sends this token anywhere
    # yet, so claiming `verification_sent: True` here would be a lie -- the
    # response must reflect what actually happened, not what the eventual
    # feature is supposed to do. Flip this only alongside the change that
    # actually dispatches mail.
    return {"verification_sent": False}


@router.post("/contact-email/verify")
async def verify_contact_email(
    body: TokenIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    token_hash = hashlib.sha256(body.token.encode()).hexdigest()
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "DELETE FROM email_verifications WHERE user_id = %s AND token_hash = %s "
            "AND expires_at > now() RETURNING email",
            (caller.user_id, token_hash),
        )
        row = await cur.fetchone()
        if not row:
            raise HTTPException(400, "invalid or expired verification token")
        # The token is single-use and is consumed either way (deleted above).
        # It only flips the verified flag if the address it was issued for is
        # STILL the profile's current contact_email -- a token minted for an
        # earlier address must not silently validate whatever address a
        # later call replaced it with.
        cur = await conn.execute(
            "UPDATE profiles SET contact_email_verified_at = now() "
            "WHERE user_id = %s AND contact_email = %s RETURNING user_id",
            (caller.user_id, row[0]),
        )
        if not await cur.fetchone():
            raise HTTPException(400, "invalid or expired verification token")
    return {"verified": True}


# --- reviewer_otp throttling ------------------------------------------------
# Security fix: this endpoint accepted unlimited POSTs with no backoff. The
# flag is not hypothetical -- it WILL be set during App Store review, which
# runs for days, and a short numeric code with no throttle falls in minutes.
# In-process state, deliberately: this is one short-lived, deliberately
# narrow path (App Review only), not general-purpose rate-limiting
# middleware, and a dependency is not warranted for it.
#
# Two independent guards, both counting FAILURES ONLY -- a correct code must
# never cost a reviewer their own budget, and one caller's mistakes must not
# spend another caller's:
#   1. Per-IP fixed window: a small cap of wrong attempts per source IP per
#      window, then 429 + Retry-After until the window rolls over.
#   2. Global failure ceiling: since IP rotation defeats guard 1, a few dozen
#      total failed attempts across the whole process disables the endpoint
#      (429) until restart -- App Review signs in a handful of times; well
#      past that is an attack, not an operational hiccup.
# Neither guard runs before the disabled check: a throttled response must
# never reveal the endpoint exists when REVIEWER_OTP_ENABLED is off.
_REVIEWER_OTP_IP_WINDOW_SECONDS = 60
_REVIEWER_OTP_IP_MAX_ATTEMPTS = 5
_REVIEWER_OTP_GLOBAL_FAILURE_CEILING = 30

_reviewer_otp_ip_window: dict[str, tuple[float, int]] = {}
_reviewer_otp_global_failures = 0


def _reviewer_otp_client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _reviewer_otp_ip_retry_after(ip: str) -> int | None:
    """Seconds to wait if `ip` is currently over its window cap, else None.

    Read-only: does not record anything, so a legitimate call under the cap
    is never charged just for being checked.
    """
    window_start, count = _reviewer_otp_ip_window.get(ip, (0.0, 0))
    elapsed = time.time() - window_start
    if elapsed >= _REVIEWER_OTP_IP_WINDOW_SECONDS:
        return None
    if count >= _REVIEWER_OTP_IP_MAX_ATTEMPTS:
        return max(1, int(_REVIEWER_OTP_IP_WINDOW_SECONDS - elapsed))
    return None


def _reviewer_otp_record_failure(ip: str) -> None:
    """Called once per rejected attempt only -- never for a success."""
    global _reviewer_otp_global_failures
    _reviewer_otp_global_failures += 1
    now = time.time()
    window_start, count = _reviewer_otp_ip_window.get(ip, (now, 0))
    if now - window_start >= _REVIEWER_OTP_IP_WINDOW_SECONDS:
        window_start, count = now, 0
    _reviewer_otp_ip_window[ip] = (window_start, count + 1)


async def reviewer_otp(body: ReviewerOtpIn, request: Request):
    """Fixed-credential sign-in for App Review only. Feature-flagged off.

    Registered on a bare /auth/reviewer-otp path in api/main.py, not under
    the /identity prefix.
    """
    if os.environ.get("REVIEWER_OTP_ENABLED") != "1":
        raise HTTPException(404, "not found")

    if _reviewer_otp_global_failures >= _REVIEWER_OTP_GLOBAL_FAILURE_CEILING:
        raise HTTPException(
            429,
            "reviewer sign-in is temporarily disabled after repeated failures",
            headers={"Retry-After": str(_REVIEWER_OTP_IP_WINDOW_SECONDS)},
        )

    ip = _reviewer_otp_client_ip(request)
    retry_after = _reviewer_otp_ip_retry_after(ip)
    if retry_after is not None:
        raise HTTPException(
            429, "too many attempts, try again later",
            headers={"Retry-After": str(retry_after)},
        )

    expected_email = os.environ.get("REVIEWER_EMAIL", "")
    expected_code = os.environ.get("REVIEWER_CODE", "")
    ok_email = hmac.compare_digest(body.email.lower(), expected_email.lower())
    ok_code = hmac.compare_digest(body.code, expected_code)
    if not (expected_email and expected_code and ok_email and ok_code):
        _reviewer_otp_record_failure(ip)
        raise HTTPException(403, "invalid reviewer credentials")
    token = jwt.encode(
        {"sub": os.environ["REVIEWER_USER_ID"], "aud": "authenticated",
         "iss": os.environ["JWT_ISSUER"], "exp": int(time.time()) + 3600},
        os.environ["JWT_SECRET"], algorithm="HS256",
    )
    return {"access_token": token}
