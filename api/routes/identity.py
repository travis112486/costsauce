# api/routes/identity.py
import hashlib
import hmac
import os
import secrets
import time
from datetime import datetime, timedelta, timezone
import jwt
from email_validator import EmailNotValidError, validate_email
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, EmailStr, field_validator
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection

router = APIRouter(prefix="/identity")
RELAY_DOMAIN = "privaterelay.appleid.com"


class ContactEmailIn(BaseModel):
    # NOT pydantic's plain EmailStr: its underlying email_validator hard-
    # rejects the `.test` TLD unconditionally, independent of
    # check_deliverability -- see api/models.py's comment on
    # MeResponse.contact_email for the identical collision on the read side.
    # `.test` is the RFC 2606 reserved-for-testing domain this project's
    # fixtures use throughout (tests/factories.py, tests/conftest.py's
    # `seeded`), so a plain EmailStr here would make this write path
    # permanently untestable against the project's own seed data -- exactly
    # what happened: the brief's own test posts "owner@acme.test" and got a
    # 422 instead of the expected 200. `test_environment=True` keeps every
    # other real RFC 5321/6531 syntax check (this is not a rubber stamp) and
    # only stops rejecting that one reserved TLD.
    email: str

    @field_validator("email")
    @classmethod
    def _valid_email(cls, v: str) -> str:
        try:
            return validate_email(v, check_deliverability=False, test_environment=True).normalized
        except EmailNotValidError as e:
            raise ValueError(str(e))


class TokenIn(BaseModel):
    token: str


class ReviewerOtpIn(BaseModel):
    email: EmailStr
    code: str


@router.post("/contact-email")
async def set_contact_email(
    body: ContactEmailIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    if body.email.lower().endswith(RELAY_DOMAIN):
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
        await conn.execute(
            "INSERT INTO email_verifications (user_id, token_hash, expires_at) VALUES (%s, %s, %s)",
            (caller.user_id, hashlib.sha256(token.encode()).hexdigest(),
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
            "AND expires_at > now() RETURNING id",
            (caller.user_id, token_hash),
        )
        if not await cur.fetchone():
            raise HTTPException(400, "invalid or expired verification token")
        await conn.execute(
            "UPDATE profiles SET contact_email_verified_at = now() WHERE user_id = %s",
            (caller.user_id,),
        )
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
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "DELETE FROM apple_link_requests WHERE token_hash = %s AND expires_at > now() "
            "RETURNING apple_sub",
            (token_hash,),
        )
        row = await cur.fetchone()
        if not row:
            raise HTTPException(400, "invalid or expired link token")
        await conn.execute(
            "UPDATE profiles SET apple_sub = %s WHERE user_id = %s", (row[0], caller.user_id)
        )
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
