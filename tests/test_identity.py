# tests/test_identity.py
import hashlib
from datetime import datetime, timedelta, timezone

from tests.test_auth import mint


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def test_apple_signin_with_no_membership_does_not_autocreate_org(app_client, raw_conn, seeded):
    """A brand-new Apple sub must land in a linking flow, not a fresh org."""
    new_sub = "00000000-0000-7000-8000-0000000000aa"
    await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, 'relay@privaterelay.appleid.com')",
        (new_sub,),
    )
    await raw_conn.commit()
    cur = await raw_conn.execute("SELECT count(*) FROM organizations")
    (before,) = await cur.fetchone()
    r = await app_client.get("/me", headers={"Authorization": f"Bearer {mint(new_sub)}"})
    assert r.status_code == 200
    assert r.json()["memberships"] == []
    cur = await raw_conn.execute("SELECT count(*) FROM organizations")
    (after,) = await cur.fetchone()
    assert after == before, "Apple sign-in must not auto-create an organization"


async def test_linking_by_matching_email_is_refused(app_client, raw_conn, seeded):
    """Explicitly assert the account-takeover primitive is absent."""
    attacker = "00000000-0000-7000-8000-0000000000bb"
    await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, 'alice@acme.test')", (attacker,)
    )
    await raw_conn.commit()
    r = await app_client.get("/me", headers={"Authorization": f"Bearer {mint(attacker)}"})
    assert r.json()["memberships"] == [], "linked on email — account takeover"


async def test_contact_email_starts_unverified(app_client, seeded):
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    # Review fix (Important-5): a real, non-reserved domain, not `.test` --
    # ContactEmailIn is plain EmailStr again (matching ReviewerOtpIn), so the
    # fix for testability lives in this literal, not in the production
    # validator. See api/routes/identity.py's comment on ContactEmailIn.
    r = await app_client.post("/identity/contact-email",
                              json={"email": "owner@acme.example.com"}, headers=hdr)
    assert r.status_code == 200
    # Judgement call (see task-7-report.md): the brief's response was
    # `{"verification_sent": True}`, but nothing in this phase sends mail --
    # that's Phase 3. Claiming a verification email went out when it did not
    # is dishonest, so the response must say `False` until delivery is wired
    # up. Flip this to True (or a richer status) only alongside the change
    # that actually dispatches mail.
    assert r.json() == {"verification_sent": False}
    me = await app_client.get("/me", headers=hdr)
    assert me.json()["contact_email"] == "owner@acme.example.com"
    assert me.json()["contact_email_verified"] is False


async def test_relay_address_is_rejected_as_contact_email(app_client, seeded):
    """The digest must never be sent to a relay address."""
    r = await app_client.post(
        "/identity/contact-email",
        json={"email": "abc123@privaterelay.appleid.com"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 422
    assert "relay" in str(r.json()).lower()


# ---------------------------------------------------------------------------
# Review fix (Important-1): a stale-but-unexpired verification token must not
# validate whatever address is currently on the profile if that address
# changed after the token was issued.
# ---------------------------------------------------------------------------
async def test_stale_verification_token_does_not_validate_a_different_address(
    app_client, raw_conn, seeded
):
    """Reproduces the reviewer's exact attack, now expected to fail closed.

    Alice's first `set_contact_email` call would have minted a token for her
    own address; we plant that token directly (its plaintext is never
    returned by the API, by design -- see task-7-report.md) so we can present
    it later. She then sets her contact email to a different address via the
    real endpoint (simulating "attacker changes the address after the first
    token was issued"). Presenting the stale, first token must NOT verify the
    new address.
    """
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    stale_token = "alices-first-token-for-her-own-address"
    await raw_conn.execute(
        "INSERT INTO email_verifications (user_id, email, token_hash, expires_at) "
        "VALUES (%s, %s, %s, %s)",
        (seeded["alice"], "alice-controls-this@acme.example.com", _hash(stale_token),
         datetime.now(timezone.utc) + timedelta(hours=24)),
    )
    await raw_conn.commit()

    r = await app_client.post("/identity/contact-email",
                              json={"email": "victim@example.org"}, headers=hdr)
    assert r.status_code == 200

    r2 = await app_client.post(
        "/identity/contact-email/verify", json={"token": stale_token}, headers=hdr
    )
    assert r2.status_code == 400, "a token minted for a different address must not verify this one"

    me = await app_client.get("/me", headers=hdr)
    assert me.json()["contact_email"] == "victim@example.org"
    assert me.json()["contact_email_verified"] is False, \
        "an address nobody consented to must not end up flagged verified"


async def test_contact_email_verify_happy_path(app_client, raw_conn, seeded):
    """Review fix (Important-6): this endpoint had zero test coverage."""
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    token = "alices-real-verification-token"
    # seeded alice's profile.contact_email is "alice@acme.test" (tests/factories.py).
    await raw_conn.execute(
        "INSERT INTO email_verifications (user_id, email, token_hash, expires_at) "
        "VALUES (%s, %s, %s, %s)",
        (seeded["alice"], "alice@acme.test", _hash(token),
         datetime.now(timezone.utc) + timedelta(hours=24)),
    )
    await raw_conn.commit()

    r = await app_client.post(
        "/identity/contact-email/verify", json={"token": token}, headers=hdr
    )
    assert r.status_code == 200
    assert r.json() == {"verified": True}
    me = await app_client.get("/me", headers=hdr)
    assert me.json()["contact_email_verified"] is True


async def test_contact_email_verify_rejects_another_users_token(app_client, raw_conn, seeded):
    token = "bobs-verification-token"
    await raw_conn.execute(
        "INSERT INTO email_verifications (user_id, email, token_hash, expires_at) "
        "VALUES (%s, %s, %s, %s)",
        (seeded["bob"], "bob@bistro.test", _hash(token),
         datetime.now(timezone.utc) + timedelta(hours=24)),
    )
    await raw_conn.commit()

    r = await app_client.post(
        "/identity/contact-email/verify", json={"token": token},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 400
    cur = await raw_conn.execute(
        "SELECT count(*) FROM email_verifications WHERE token_hash = %s", (_hash(token),)
    )
    assert (await cur.fetchone())[0] == 1, "Bob's row must be untouched by Alice's attempt"


async def test_contact_email_verify_token_is_single_use(app_client, raw_conn, seeded):
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    token = "alices-single-use-token"
    await raw_conn.execute(
        "INSERT INTO email_verifications (user_id, email, token_hash, expires_at) "
        "VALUES (%s, %s, %s, %s)",
        (seeded["alice"], "alice@acme.test", _hash(token),
         datetime.now(timezone.utc) + timedelta(hours=24)),
    )
    await raw_conn.commit()

    r1 = await app_client.post("/identity/contact-email/verify", json={"token": token}, headers=hdr)
    assert r1.status_code == 200
    r2 = await app_client.post("/identity/contact-email/verify", json={"token": token}, headers=hdr)
    assert r2.status_code == 400, "a consumed token must not verify again"


# ---------------------------------------------------------------------------
# Apple account linking (POST /identity/apple/link-request and
# /apple/link-confirm) is DESCOPED to Phase 2a -- Travis's call, Task 7
# review. The tests that exercised those two endpoints (including the one
# proving the account-takeover primitive is absent, and the one pinning the
# cross-account RLS defect below) are removed along with the endpoints. The
# knowledge is NOT discarded -- it lives in api/routes/identity.py's
# module-level comment and in task-7-report.md ("apple_sub coherence"):
#
#   Migration 0004's `apple_link_self` RLS policy restricts
#   `apple_link_requests` to rows whose `apple_sub` equals the CALLER'S OWN
#   sub (`USING (apple_sub = current_jwt_sub())`, a FOR ALL policy). Since
#   `apple_link_request` inserted the requesting session's own `caller.user_id`
#   as `apple_sub`, a *different*, existing account could never see or delete
#   a row a brand-new Apple session created -- RLS silently returned zero
#   rows for a token that was, in fact, perfectly valid, making cross-account
#   confirm (the feature's entire purpose) structurally unreachable. Confirmed
#   empirically in Task 7, and the underlying mechanism is independently
#   pinned by tests/test_rls_policies.py::test_update_or_delete_of_another_tenants_row_touches_nothing.
#
# When Phase 2a rebuilds these endpoints (target-account column, a
# SECURITY DEFINER token_hash lookup, and identity resolution that consults
# apple_sub -- see identity.py's comment for all three), re-add tests
# covering: happy-path link-request, happy-path cross-account confirm asserting
# profiles.apple_sub actually changed, cross-user token rejection, invalid/
# expired token rejection, no-profile-to-link-to, and the UNIQUE collision on
# profiles.apple_sub surfacing as a 409 rather than a 500 -- all of which
# existed here before this descope and were removed with the endpoints.
# ---------------------------------------------------------------------------
