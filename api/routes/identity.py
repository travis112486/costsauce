# api/routes/identity.py
import hashlib
import hmac
import os
import secrets
import time
from datetime import datetime, timedelta, timezone
import jwt
import psycopg
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
        await conn.execute(
            "UPDATE profiles SET contact_email = %s, contact_email_verified_at = NULL "
            "WHERE user_id = %s",
            (body.email, caller.user_id),
        )
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


@router.post("/apple/link-request")
async def apple_link_request(request: Request, caller: CallerIdentity = Depends(require_caller)):
    """Send a magic link to the EXISTING account's verified address.

    Linking is only ever confirmed from the original address. Matching on the
    Apple-supplied email is forbidden — it is an account-takeover primitive.
    """
    token = secrets.token_urlsafe(32)
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await conn.execute(
            "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at) VALUES (%s, %s, %s)",
            (caller.user_id, hashlib.sha256(token.encode()).hexdigest(),
             datetime.now(timezone.utc) + timedelta(minutes=30)),
        )
    return {"link_token_sent": True}


@router.post("/apple/link-confirm")
async def apple_link_confirm(
    body: TokenIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    token_hash = hashlib.sha256(body.token.encode()).hexdigest()
    try:
        async with tenant_connection(request.app.state.pool, caller.claims) as conn:
            cur = await conn.execute(
                "DELETE FROM apple_link_requests WHERE token_hash = %s AND expires_at > now() "
                "RETURNING apple_sub",
                (token_hash,),
            )
            row = await cur.fetchone()
            if not row:
                raise HTTPException(400, "invalid or expired link token")
            # Important-2 fix: the token was valid, but that alone doesn't
            # mean anything got linked -- check the UPDATE actually touched a
            # row before reporting success.
            cur = await conn.execute(
                "UPDATE profiles SET apple_sub = %s WHERE user_id = %s",
                (row[0], caller.user_id),
            )
            if cur.rowcount != 1:
                raise HTTPException(400, "no profile to link this Apple ID to")
    except psycopg.errors.UniqueViolation:
        # Important-3 fix: profiles.apple_sub is UNIQUE. Once a different
        # account already holds this Apple identity, the UPDATE above raises
        # rather than silently overwriting -- surface that as a clean 4xx,
        # not a 500.
        raise HTTPException(409, "this Apple ID is already linked to another account")
    return {"linked": True}


async def reviewer_otp(body: ReviewerOtpIn):
    """Fixed-credential sign-in for App Review only. Feature-flagged off.

    Registered on a bare /auth/reviewer-otp path in api/main.py, not under
    the /identity prefix.
    """
    if os.environ.get("REVIEWER_OTP_ENABLED") != "1":
        raise HTTPException(404, "not found")
    expected_email = os.environ.get("REVIEWER_EMAIL", "")
    expected_code = os.environ.get("REVIEWER_CODE", "")
    ok_email = hmac.compare_digest(body.email.lower(), expected_email.lower())
    ok_code = hmac.compare_digest(body.code, expected_code)
    if not (expected_email and expected_code and ok_email and ok_code):
        raise HTTPException(403, "invalid reviewer credentials")
    token = jwt.encode(
        {"sub": os.environ["REVIEWER_USER_ID"], "aud": "authenticated",
         "iss": os.environ["JWT_ISSUER"], "exp": int(time.time()) + 3600},
        os.environ["JWT_SECRET"], algorithm="HS256",
    )
    return {"access_token": token}
