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


async def test_link_confirm_requires_valid_token(app_client, seeded):
    r = await app_client.post(
        "/identity/apple/link-confirm",
        json={"token": "not-a-real-token"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 400


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
# Review fix (Important-6): apple/link-request had zero test coverage.
# ---------------------------------------------------------------------------
async def test_apple_link_request_creates_a_pending_row(app_client, raw_conn, seeded):
    hdr = {"Authorization": f"Bearer {mint(str(seeded['bob']))}"}
    r = await app_client.post("/identity/apple/link-request", headers=hdr)
    assert r.status_code == 200
    assert r.json() == {"link_token_sent": True}

    cur = await raw_conn.execute(
        "SELECT apple_sub, expires_at > now() FROM apple_link_requests WHERE apple_sub = %s",
        (str(seeded["bob"]),),
    )
    row = await cur.fetchone()
    assert row is not None, "no pending row was created for the requesting caller"
    assert row[0] == str(seeded["bob"])
    assert row[1] is True, "expires_at must be in the future"


# ---------------------------------------------------------------------------
# Review fix (Important-2): apple_link_confirm must not report success when
# nothing was actually linked.
# ---------------------------------------------------------------------------
async def test_apple_link_confirm_reports_failure_when_nothing_to_link(app_client, raw_conn, seeded):
    """A valid, unexpired token whose caller has no `profiles` row must not
    return {"linked": True} -- there is nothing to link it to."""
    new_sub = "00000000-0000-7000-8000-0000000000dd"
    await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, 'relay3@privaterelay.appleid.com')",
        (new_sub,),
    )
    # Deliberately no profiles row for new_sub.
    token = "no-profile-to-link-token"
    await raw_conn.execute(
        "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at) VALUES (%s, %s, %s)",
        (new_sub, _hash(token), datetime.now(timezone.utc) + timedelta(minutes=30)),
    )
    await raw_conn.commit()

    r = await app_client.post(
        "/identity/apple/link-confirm", json={"token": token},
        headers={"Authorization": f"Bearer {mint(new_sub)}"},
    )
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# Review fix (Important-3): a UNIQUE collision on profiles.apple_sub must
# surface as a clean 4xx, not an unhandled 500.
# ---------------------------------------------------------------------------
async def test_apple_link_confirm_returns_409_not_500_on_already_linked_apple_id(
    app_client, raw_conn, seeded
):
    """`profiles.apple_sub` is UNIQUE. Plants the "already linked elsewhere"
    precondition directly via raw_conn -- the legitimate cross-account path
    to reach this state is currently blocked by the RLS defect tracked
    separately (see task-7-report.md, "apple_sub coherence" / Finding 4,
    left untouched this round per the coordinator) -- but the constraint and
    this error-handling path are both real regardless of how the precondition
    arises, and become the primary failure mode once that RLS gap is fixed.
    """
    colliding_value = str(seeded["alice"])
    await raw_conn.execute(
        "UPDATE profiles SET apple_sub = %s WHERE user_id = %s",
        (colliding_value, seeded["bob"]),
    )
    token = "collision-token"
    await raw_conn.execute(
        "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at) VALUES (%s, %s, %s)",
        (colliding_value, _hash(token), datetime.now(timezone.utc) + timedelta(minutes=30)),
    )
    await raw_conn.commit()

    r = await app_client.post(
        "/identity/apple/link-confirm", json={"token": token},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 409
    assert "already linked" in r.json()["detail"].lower()
    cur = await raw_conn.execute(
        "SELECT apple_sub FROM profiles WHERE user_id = %s", (seeded["bob"],)
    )
    assert (await cur.fetchone())[0] == colliding_value, "Bob's existing link must be untouched"


# ---------------------------------------------------------------------------
# Known limitation, not a Task 7 fix this round -- see task-7-report.md,
# "apple_sub coherence" (Finding 4, explicitly deferred to the human partner
# as a scope decision). Migration 0004's `apple_link_self` RLS policy
# restricts `apple_link_requests` to rows whose `apple_sub` equals the
# CALLER'S OWN sub, so a *different*, existing account can never see a row
# created by a brand-new Apple session -- making the feature's actual
# purpose (cross-account linking) structurally unreachable. Task 5's own
# regression suite already proves the underlying mechanism
# (tests/test_rls_policies.py::test_update_or_delete_of_another_tenants_row_touches_nothing);
# this test shows the same gap from the HTTP surface, and additionally
# confirms (Important-2 fix) that the one case RLS *does* allow --
# self-referential confirm -- genuinely writes profiles.apple_sub rather
# than just returning a 200 with nothing changed.
# ---------------------------------------------------------------------------
async def test_apple_link_confirm_cannot_complete_cross_account_link(app_client, raw_conn, seeded):
    apple_sub = "00000000-0000-7000-8000-0000000000cc"
    await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, 'relay2@privaterelay.appleid.com')",
        (apple_sub,),
    )
    # Gives the fabricated Apple session a profiles row, so the one path RLS
    # currently allows (self-referential confirm) can genuinely succeed
    # rather than being masked by the Important-2 "no profile to link" guard.
    await raw_conn.execute(
        "INSERT INTO profiles (user_id, contact_email) VALUES (%s, 'relay2@privaterelay.appleid.com')",
        (apple_sub,),
    )
    token = "a-known-plaintext-token-for-testing-only"
    await raw_conn.execute(
        "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at) VALUES (%s, %s, %s)",
        (apple_sub, _hash(token), datetime.now(timezone.utc) + timedelta(minutes=30)),
    )
    await raw_conn.commit()

    # Alice -- an existing, different account -- tries to confirm the link
    # with the real token. This is the product's actual flow, and it fails.
    r = await app_client.post(
        "/identity/apple/link-confirm",
        json={"token": token},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 400, (
        "cross-account confirm succeeded -- if migration 0004's RLS was "
        "fixed, rewrite this test to assert success and profiles.apple_sub"
    )

    # The row is untouched -- RLS filtered it out of the DELETE entirely, it
    # was not consumed -- so the *same* Apple session can still confirm its
    # own (self-referential, and thus product-useless) request. This is the
    # only case the current RLS policy actually permits, and it must
    # genuinely write profiles.apple_sub, not just return 200.
    r2 = await app_client.post(
        "/identity/apple/link-confirm",
        json={"token": token},
        headers={"Authorization": f"Bearer {mint(apple_sub)}"},
    )
    assert r2.status_code == 200
    assert r2.json() == {"linked": True}
    cur = await raw_conn.execute("SELECT apple_sub FROM profiles WHERE user_id = %s", (apple_sub,))
    row = await cur.fetchone()
    assert row is not None and row[0] == apple_sub, \
        "the 200 response must correspond to an actual write, not a no-op"
