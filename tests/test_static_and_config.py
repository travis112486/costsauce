"""Tests for static file serving and /config bootstrap endpoint."""
from httpx import AsyncClient, ASGITransport
from tests.test_auth import mint


def auth(user_id):
    return {"Authorization": f"Bearer {mint(sub=str(user_id))}"}


async def test_config_with_env_vars_returns_values(monkeypatch, _roles_bootstrapped, db_url):
    """GET /config with SUPABASE_* env vars set returns both values.

    Proves request-time env reading by monkeypatching env vars before app
    creation, building a fresh app instance, and verifying /config returns
    the set values. Follows the conftest app_client pattern.
    """
    monkeypatch.setenv("JWT_SECRET", "test-jwt-secret")
    monkeypatch.setenv("JWT_ISSUER", "https://khohfrfqzbieaiikqlsa.supabase.co/auth/v1")
    monkeypatch.setenv("DATABASE_URL", db_url.replace("postgres:postgres", "app_user:app_pw"))
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_ANON_KEY", "test-anon-key-123")
    monkeypatch.setenv("RETURN_INVITE_TOKEN_ENABLED", "1")

    from api.main import create_app
    app = create_app()
    async with app.router.lifespan_context(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
            r = await c.get("/config")

    assert r.status_code == 200
    data = r.json()
    assert data["supabase_url"] == "https://example.supabase.co"
    assert data["supabase_anon_key"] == "test-anon-key-123"


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
