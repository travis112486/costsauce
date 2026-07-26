# tests/test_identity.py
import hashlib
from datetime import datetime, timedelta, timezone

from tests.test_auth import mint


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
    r = await app_client.post("/identity/contact-email",
                              json={"email": "owner@acme.test"}, headers=hdr)
    assert r.status_code == 200
    # Judgement call (see task-7-report.md): the brief's response was
    # `{"verification_sent": True}`, but nothing in this phase sends mail --
    # that's Phase 3. Claiming a verification email went out when it did not
    # is dishonest, so the response must say `False` until delivery is wired
    # up. Flip this to True (or a richer status) only alongside the change
    # that actually dispatches mail.
    assert r.json() == {"verification_sent": False}
    me = await app_client.get("/me", headers=hdr)
    assert me.json()["contact_email"] == "owner@acme.test"
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


async def test_apple_link_confirm_cannot_complete_cross_account_link(app_client, raw_conn, seeded):
    """Pins a genuine defect found while implementing this task -- see
    task-7-report.md, "apple_sub coherence" -- rather than papering over it.

    The feature's entire point (per this task's docstrings and the global
    constraints) is cross-account: a brand-new, membership-less Apple `sub`
    requests a link, and a DIFFERENT, existing account confirms it after a
    magic-link round trip. But migration 0004's `apple_link_self` RLS policy
    is `USING (apple_sub = current_jwt_sub())` -- every operation on
    `apple_link_requests`, including this DELETE, is restricted to rows whose
    `apple_sub` equals the CALLER'S OWN sub. Since `apple_link_request`
    inserts the requesting (new, Apple) session's own `caller.user_id` as
    `apple_sub`, a *different* confirming account can never see that row:
    RLS silently returns zero rows, and `apple_link_confirm` reports "invalid
    or expired link token" for a token that is, in fact, perfectly valid.

    Task 5's own regression suite already proves the underlying mechanism --
    tests/test_rls_policies.py::test_update_or_delete_of_another_tenants_row_touches_nothing
    includes `DELETE FROM apple_link_requests WHERE apple_sub = %s (BOB,)` run
    as ALICE, asserting `rowcount == 0` -- this test just shows the same gap
    from the HTTP surface, where it manifests as the cross-account linking
    feature being permanently unreachable.

    Fixing this needs a schema/RLS change (migration 0004), which is out of
    Task 7's scope (api/routes/identity.py, api/main.py, tests/test_identity.py
    only). This test pins the CURRENT behaviour so nobody assumes cross-account
    confirm works; if it starts passing a differently-shaped assertion, that
    means the RLS gap was fixed and this test should be rewritten to assert
    success instead.
    """
    apple_sub = "00000000-0000-7000-8000-0000000000cc"
    await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, 'relay2@privaterelay.appleid.com')",
        (apple_sub,),
    )
    token = "a-known-plaintext-token-for-testing-only"
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    await raw_conn.execute(
        "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at) VALUES (%s, %s, %s)",
        (apple_sub, token_hash, datetime.now(timezone.utc) + timedelta(minutes=30)),
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
    # only case the current RLS policy actually permits.
    r2 = await app_client.post(
        "/identity/apple/link-confirm",
        json={"token": token},
        headers={"Authorization": f"Bearer {mint(apple_sub)}"},
    )
    assert r2.status_code == 200
    assert r2.json() == {"linked": True}
