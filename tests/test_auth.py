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
    """Plan comes from organizations.plan, never from the token."""
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']))}"})
    assert r.json()["entitlement"]["plan"] == "starter"
    assert r.json()["entitlement"]["max_locations"] == 1
