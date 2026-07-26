# tests/test_auth.py
import time
import jwt

SECRET = "test-jwt-secret"
ISSUER = "https://khohfrfqzbieaiikqlsa.supabase.co/auth/v1"


def mint(sub: str, *, aud="authenticated", iss=ISSUER, exp_delta=3600, secret=SECRET):
    return jwt.encode(
        {"sub": sub, "aud": aud, "iss": iss, "exp": int(time.time()) + exp_delta},
        secret, algorithm="HS256",
    )


async def test_missing_token_is_401(app_client):
    r = await app_client.get("/me")
    assert r.status_code == 401


async def test_expired_token_is_401(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']), exp_delta=-10)}"})
    assert r.status_code == 401
    assert "expired" in r.json()["detail"].lower()


async def test_wrong_audience_is_401(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']), aud='anon')}"})
    assert r.status_code == 401


async def test_wrong_issuer_is_401(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']), iss='https://evil.test')}"})
    assert r.status_code == 401


async def test_token_signed_with_wrong_key_is_401(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']), secret='not-the-secret')}"})
    assert r.status_code == 401


async def test_me_returns_only_callers_memberships(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']))}"})
    assert r.status_code == 200
    org_ids = {m["org_id"] for m in r.json()["memberships"]}
    assert org_ids == {str(seeded["acme"])}
    assert str(seeded["bistro"]) not in org_ids


async def test_entitlement_is_server_derived_not_client_supplied(app_client, seeded):
    """Plan comes from organizations.plan, never from the token.

    Mints a token that smuggles a `plan` claim (and a bogus `max_locations`)
    Supabase would never issue, to prove the response ignores both -- the
    per-membership entitlement must still reflect Acme's real, DB-held plan.
    """
    token = jwt.encode(
        {"sub": str(seeded["alice"]), "aud": "authenticated", "iss": ISSUER,
         "exp": int(time.time()) + 3600, "plan": "pro", "max_locations": 999},
        SECRET, algorithm="HS256",
    )
    r = await app_client.get("/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    memberships = r.json()["memberships"]
    assert len(memberships) == 1
    assert memberships[0]["org_id"] == str(seeded["acme"])
    assert memberships[0]["entitlement"]["plan"] == "starter"
    assert memberships[0]["entitlement"]["max_locations"] == 1


async def test_multi_org_membership_reports_its_own_entitlement(app_client, raw_conn, seeded):
    """A caller in two orgs on different plans must see each org's own plan
    and limits on its own membership -- not one plan applied to both, and
    not one picked arbitrarily (the bookkeeper-channel case: an accountant
    who manages several restaurants on different plans)."""
    from tests.factories import add_member
    await add_member(raw_conn, seeded["alice"], seeded["bistro"], "bookkeeper")
    await raw_conn.execute(
        "UPDATE organizations SET plan = 'pro' WHERE id = %s", (seeded["bistro"],)
    )
    await raw_conn.commit()

    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']))}"})
    assert r.status_code == 200
    by_org = {m["org_id"]: m for m in r.json()["memberships"]}
    assert set(by_org) == {str(seeded["acme"]), str(seeded["bistro"])}

    acme = by_org[str(seeded["acme"])]
    assert acme["role"] == "owner"
    assert acme["entitlement"]["plan"] == "starter"
    assert acme["entitlement"]["max_locations"] == 1
    assert acme["entitlement"]["max_members"] == 1

    bistro = by_org[str(seeded["bistro"])]
    assert bistro["role"] == "bookkeeper"
    assert bistro["entitlement"]["plan"] == "pro"
    assert bistro["entitlement"]["max_locations"] == 3
    assert bistro["entitlement"]["max_members"] == 10
