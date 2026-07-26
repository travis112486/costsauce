# tests/test_reviewer_otp.py
"""Reviewer OTP: a fixed-credential sign-in path for App Store review.

Endpoint already shipped in Task 7 (api/routes/identity.py::reviewer_otp,
mounted at POST /auth/reviewer-otp in api/main.py). This file is tests only.

Two deviations from the brief, both noted in task-8-report.md:

1. The brief's addresses used `attacker@evil.test`. `.test` is in
   email_validator's SPECIAL_USE_DOMAIN_NAMES, so `ReviewerOtpIn` (plain
   EmailStr -- see its comment in api/routes/identity.py) 422s on that
   address before `reviewer_otp` ever runs. That would look like a routing
   bug, not the validation rejection it actually is. Every address below
   uses a real, non-reserved domain (example.com and subdomains of it,
   matching ContactEmailIn's tests in test_identity.py).

2. The brief sets REVIEWER_* env vars via `monkeypatch` inside the test
   body, after `app_client` (and the FastAPI app it builds) already exists.
   Checked api/routes/identity.py::reviewer_otp: it calls `os.environ.get(...)`
   at request time, inside the handler body -- nothing about REVIEWER_OTP_ENABLED
   or its credentials is read or cached at app-construction time in
   api/main.py. So setting the env after app_client's setup still works,
   and precisely because of that, these tests are a genuine after-construction
   read, not a false pass. Confirmed by running them.
"""
import jwt

from tests.test_auth import ISSUER, SECRET, mint

REVIEWER_EMAIL = "reviewer@example.com"
REVIEWER_CODE = "424242"
REVIEWER_USER_ID = "00000000-0000-7000-8000-0000000000f1"


async def test_reviewer_otp_disabled_by_default(app_client):
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": "review@costsauce.com", "code": "123456"})
    assert r.status_code == 404


async def test_reviewer_otp_rejects_other_addresses(app_client, monkeypatch):
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": "attacker@evil.example.com", "code": REVIEWER_CODE})
    assert r.status_code == 403


async def test_reviewer_otp_rejects_wrong_code(app_client, monkeypatch):
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": REVIEWER_EMAIL, "code": "000000"})
    assert r.status_code == 403


async def test_reviewer_otp_correct_credentials_return_a_usable_token(app_client, monkeypatch):
    """The whole point of this endpoint: does a correct pair actually let App
    Review in? Proves the returned token is not just *a* JWT, but one
    `require_caller` accepts -- same secret/issuer/audience api/auth.py
    checks -- by using it against a real protected route (GET /me).
    """
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)
    monkeypatch.setenv("REVIEWER_USER_ID", REVIEWER_USER_ID)

    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": REVIEWER_EMAIL, "code": REVIEWER_CODE})
    assert r.status_code == 200
    token = r.json()["access_token"]

    claims = jwt.decode(token, SECRET, algorithms=["HS256"], audience="authenticated", issuer=ISSUER)
    assert claims["sub"] == REVIEWER_USER_ID

    me = await app_client.get("/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200, "reviewer_otp's own token must pass require_caller"
    assert me.json()["user_id"] == REVIEWER_USER_ID


async def test_reviewer_otp_email_match_is_case_insensitive(app_client, monkeypatch):
    """`.lower()` is applied to both sides of the email comparison -- a
    reviewer typing/autocapitalizing their email differently than the env
    var must not be locked out.
    """
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)
    monkeypatch.setenv("REVIEWER_USER_ID", REVIEWER_USER_ID)
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": REVIEWER_EMAIL.upper(), "code": REVIEWER_CODE})
    assert r.status_code == 200


async def test_reviewer_otp_refuses_when_expected_code_is_unset(app_client, monkeypatch):
    """Global constraint: comparison must not pass when the expected value is
    empty/unset. A misconfigured deployment (REVIEWER_OTP_ENABLED=1 but
    REVIEWER_CODE never set) must not become an open door for anyone who
    knows/guesses the reviewer email and submits an empty code -- `code` has
    no format validator, so "" is otherwise a syntactically valid body.
    """
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.delenv("REVIEWER_CODE", raising=False)
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": REVIEWER_EMAIL, "code": ""})
    assert r.status_code == 403
