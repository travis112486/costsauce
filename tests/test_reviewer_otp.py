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
import pytest

import api.routes.identity as identity_module
from tests.test_auth import ISSUER, SECRET, mint

REVIEWER_EMAIL = "reviewer@example.com"
REVIEWER_CODE = "424242"
REVIEWER_USER_ID = "00000000-0000-7000-8000-0000000000f1"


@pytest.fixture(autouse=True)
def _reset_reviewer_otp_throttle(monkeypatch):
    """Security fix (rate limiting): the throttle counters are in-process
    module state, not a DB row, so they persist across `app_client`'s fresh
    per-test FastAPI app unless explicitly cleared. `monkeypatch` is already
    function-scoped for every env var this file sets; resetting the throttle
    state through it the same way keeps isolation uniform -- nothing any
    test here does can leak into the next one, regardless of run order.
    """
    monkeypatch.setattr(identity_module, "_reviewer_otp_ip_window", {})
    monkeypatch.setattr(identity_module, "_reviewer_otp_global_failures", 0)


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


async def test_reviewer_otp_refuses_when_expected_email_is_unset(app_client, monkeypatch):
    """Minor left open by the Task 8 review: the REVIEWER_EMAIL-unset arm of
    the same fail-closed guard was only argued (EmailStr blocks `email: ""`,
    so `ok_email` can never be true against an empty expected value), never
    exercised. A misconfigured deployment (REVIEWER_OTP_ENABLED=1 but
    REVIEWER_EMAIL never set) must not become an open door for anyone who
    knows/guesses the reviewer code.
    """
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.delenv("REVIEWER_EMAIL", raising=False)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": "anyone@example.com", "code": REVIEWER_CODE})
    assert r.status_code == 403


async def test_reviewer_otp_throttles_repeated_wrong_codes_per_ip(app_client, monkeypatch):
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)

    for _ in range(identity_module._REVIEWER_OTP_IP_MAX_ATTEMPTS):
        r = await app_client.post("/auth/reviewer-otp",
                                  json={"email": REVIEWER_EMAIL, "code": "000000"})
        assert r.status_code == 403

    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": REVIEWER_EMAIL, "code": "000000"})
    assert r.status_code == 429
    assert "Retry-After" in r.headers


async def test_reviewer_otp_does_not_throttle_a_correct_code(app_client, monkeypatch):
    """Do not throttle successes, only failures -- a reviewer retrying a
    correct code (e.g. after a flaky network call) must never be locked out
    by their own prior successes."""
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)
    monkeypatch.setenv("REVIEWER_USER_ID", REVIEWER_USER_ID)

    for _ in range(identity_module._REVIEWER_OTP_IP_MAX_ATTEMPTS + 2):
        r = await app_client.post("/auth/reviewer-otp",
                                  json={"email": REVIEWER_EMAIL, "code": REVIEWER_CODE})
        assert r.status_code == 200


async def test_reviewer_otp_disabled_flag_beats_active_throttle(app_client, monkeypatch):
    """A throttled response must never reveal the endpoint exists when the
    flag is off -- the disabled check runs first, unchanged."""
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)
    for _ in range(identity_module._REVIEWER_OTP_IP_MAX_ATTEMPTS):
        await app_client.post("/auth/reviewer-otp",
                              json={"email": REVIEWER_EMAIL, "code": "000000"})
    # Confirm it is actually throttled first, so the next assertion proves
    # the disabled check pre-empts it rather than the throttle never firing.
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": REVIEWER_EMAIL, "code": "000000"})
    assert r.status_code == 429

    monkeypatch.delenv("REVIEWER_OTP_ENABLED", raising=False)
    r2 = await app_client.post("/auth/reviewer-otp",
                               json={"email": REVIEWER_EMAIL, "code": "000000"})
    assert r2.status_code == 404


async def test_reviewer_otp_global_ceiling_disables_endpoint_across_ips(app_client, monkeypatch):
    """A few dozen total failed attempts disables the endpoint regardless of
    source IP -- IP rotation must not defeat the backstop. Failures are
    simulated across many distinct IPs (bypassing the HTTP layer, which
    cannot vary the test client's real transport IP per request) so the
    per-IP cap never trips, isolating the global ceiling specifically.
    """
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", REVIEWER_EMAIL)
    monkeypatch.setenv("REVIEWER_CODE", REVIEWER_CODE)

    for i in range(identity_module._REVIEWER_OTP_GLOBAL_FAILURE_CEILING):
        identity_module._reviewer_otp_record_failure(f"203.0.113.{i % 254 + 1}")

    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": REVIEWER_EMAIL, "code": REVIEWER_CODE})
    assert r.status_code == 429
    assert "Retry-After" in r.headers
