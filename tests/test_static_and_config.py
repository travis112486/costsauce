"""Tests for static file serving and /config bootstrap endpoint."""
from tests.test_auth import mint


def auth(user_id):
    return {"Authorization": f"Bearer {mint(sub=str(user_id))}"}


async def test_config_endpoint_returns_nulls_when_env_unset(app_client):
    """GET /config returns nulls for SUPABASE_* when env vars unset.

    app_client fixture does not set SUPABASE_URL/SUPABASE_ANON_KEY, so they
    should be null in the response.
    """
    r = await app_client.get("/config")
    assert r.status_code == 200
    data = r.json()
    assert data["supabase_url"] is None
    assert data["supabase_anon_key"] is None


async def test_root_redirects_to_app(app_client):
    """GET / redirects to /app/."""
    r = await app_client.get("/", follow_redirects=False)
    assert r.status_code in [302, 307]
    assert r.headers["location"] == "/app/"


async def test_app_index_returns_html(app_client):
    """GET /app/ returns 200 with text/html containing id=\"app\"."""
    r = await app_client.get("/app/")
    assert r.status_code == 200
    assert "text/html" in r.headers.get("content-type", "")
    assert 'id="app"' in r.text


async def test_shared_kernel_js_accessible(app_client):
    """GET /shared/kernel.js returns 200 with export keyword."""
    r = await app_client.get("/shared/kernel.js")
    assert r.status_code == 200
    assert "export" in r.text


async def test_existing_auth_route_still_works(app_client, seeded_biz):
    """Spot-check that an existing authenticated route works (no shadowing)."""
    s = seeded_biz
    r = await app_client.get(
        f"/locations/{s['acme_loc']}/ingredients",
        headers=auth(s["alice"])
    )
    assert r.status_code == 200
    # Should be an empty list since no ingredients are set up
    assert r.json() == []
