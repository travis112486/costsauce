# tests/test_invoices.py
"""Phase 3a invoice capture: schema shape, the live-only page unique, the
purchases link, and org isolation on the two new tables."""
import httpx
import pytest
from tests.conftest import apply_migrations
from tests.factories import (
    make_user, make_org, add_member, make_location, make_ingredient)
from api.db import pool_open, tenant_connection


def app_url(url):
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def actors(raw_conn):
    await apply_migrations(raw_conn)
    alice = await make_user(raw_conn, "alice@acme.test")     # owner
    dave = await make_user(raw_conn, "dave@acme.test")       # bookkeeper
    bob = await make_user(raw_conn, "bob@bistro.test")       # other org
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    await add_member(raw_conn, alice, acme, "owner")
    await add_member(raw_conn, dave, acme, "bookkeeper")
    await add_member(raw_conn, bob, bistro, "owner")
    loc = await make_location(raw_conn, acme, "Acme Main")
    b_loc = await make_location(raw_conn, bistro, "Bistro Main")
    ing = await make_ingredient(raw_conn, loc, "Chicken Breast")
    await raw_conn.commit()
    return dict(alice=alice, dave=dave, bob=bob, acme=acme,
                loc=loc, b_loc=b_loc, ing=ing)


@pytest.fixture
async def pool(db_url, actors):
    p = await pool_open(app_url(db_url))
    try:
        yield p
    finally:
        await p.close()


async def _mint_invoice(conn, loc):
    cur = await conn.execute(
        "INSERT INTO invoices (location_id, captured_at, client_mutated_at)"
        " VALUES (%s, now(), now()) RETURNING id", (loc,))
    return (await cur.fetchone())[0]


async def _mint_page(conn, inv, loc, page_no=1):
    cur = await conn.execute(
        "INSERT INTO invoice_pages (invoice_id, location_id, page_no,"
        " storage_path, client_mutated_at)"
        " VALUES (%s, %s, %s, 'org/inv/1.jpg', now()) RETURNING id",
        (inv, loc, page_no))
    return (await cur.fetchone())[0]


async def test_retake_reuses_page_no_after_tombstone(raw_conn, actors):
    """The unique must be LIVE-ONLY, exactly like recipe_items_live_uq: a
    full unique would make a retake impossible without renumbering pages."""
    inv = await _mint_invoice(raw_conn, actors["loc"])
    first = await _mint_page(raw_conn, inv, actors["loc"])
    await raw_conn.execute(
        "UPDATE invoice_pages SET deleted_at = now() WHERE id = %s", (first,))

    await _mint_page(raw_conn, inv, actors["loc"])  # the retake

    cur = await raw_conn.execute(
        "SELECT count(*) FROM invoice_pages"
        " WHERE invoice_id = %s AND deleted_at IS NULL", (inv,))
    assert (await cur.fetchone())[0] == 1


async def test_two_live_pages_with_the_same_page_no_are_refused(raw_conn, actors):
    inv = await _mint_invoice(raw_conn, actors["loc"])
    await _mint_page(raw_conn, inv, actors["loc"])
    with pytest.raises(Exception) as exc:
        await _mint_page(raw_conn, inv, actors["loc"])
    assert "invoice_pages_live_uq" in str(exc.value)


async def test_deleting_a_page_leaves_its_purchase(raw_conn, actors):
    """ON DELETE SET NULL, not CASCADE: a purchase records a real cost the
    business incurred, and deleting the photograph must not delete it."""
    inv = await _mint_invoice(raw_conn, actors["loc"])
    page = await _mint_page(raw_conn, inv, actors["loc"])
    cur = await raw_conn.execute(
        "INSERT INTO purchases (location_id, ingredient_id, purchased_on, qty,"
        " unit, qty_base_units, total_price, invoice_page_id)"
        " VALUES (%s, %s, '2026-01-01', 1, 'lb', 1, 5.00, %s) RETURNING id",
        (actors["loc"], actors["ing"], page))
    pur = (await cur.fetchone())[0]

    await raw_conn.execute("DELETE FROM invoice_pages WHERE id = %s", (page,))

    cur = await raw_conn.execute(
        "SELECT total_price, invoice_page_id FROM purchases WHERE id = %s", (pur,))
    row = await cur.fetchone()
    assert row[0] is not None
    assert row[1] is None


async def test_bookkeeper_can_capture_an_invoice(pool, actors):
    """Photographing a delivery is data entry, like recording a purchase --
    gating it to managers would stop the person receiving the delivery."""
    async with tenant_connection(pool, {"sub": str(actors["dave"])}) as conn:
        await conn.execute(
            "INSERT INTO invoices (location_id, captured_at, client_mutated_at)"
            " VALUES (%s, now(), now())", (actors["loc"],))


async def test_cross_org_sees_no_invoices(pool, actors, raw_conn):
    inv = await _mint_invoice(raw_conn, actors["loc"])
    await _mint_page(raw_conn, inv, actors["loc"])
    await raw_conn.commit()
    async with tenant_connection(pool, {"sub": str(actors["bob"])}) as conn:
        for t in ("invoices", "invoice_pages"):
            cur = await conn.execute(f"SELECT count(*) FROM {t}")
            assert (await cur.fetchone())[0] == 0, f"{t} leaked cross-org"


async def test_cross_org_invoice_insert_blocked_by_with_check(pool, actors):
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(actors["bob"])}) as conn:
            await conn.execute(
                "INSERT INTO invoices (location_id, captured_at, client_mutated_at)"
                " VALUES (%s, now(), now())", (actors["loc"],))
    assert "row-level security" in str(exc.value).lower()


# --- The upload-URL and confirm endpoints ------------------------------
# These use app_client/seeded_biz/auth like every other route test, rather
# than the RLS fixtures above: they exercise the HTTP surface, not policies.

from tests.test_ingredients_routes import auth  # noqa: E402


async def _mint_invoice_for(raw_conn, loc):
    inv = await _mint_invoice(raw_conn, loc)
    await raw_conn.commit()
    return inv


async def test_upload_url_path_is_org_invoice_page_jpg(
        app_client, seeded_biz, raw_conn, monkeypatch):
    """The key the client will independently derive. Both sides must agree
    byte for byte or uploads land where nothing reads them."""
    import api.routes.invoices as mod
    monkeypatch.setattr(
        mod, "sign_put",
        lambda path: _fake_sign(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])

    r = await app_client.post(
        f"/invoices/{inv}/pages/2/upload-url", headers=auth(s["alice"]))

    assert r.status_code == 200, r.text
    assert r.json()["storage_path"] == f"{s['acme']}/{inv}/2.jpg"


async def _fake_sign(path):
    return f"https://storage.test/put/{path}", "2026-08-03T12:00:00+00:00"


async def test_upload_url_404s_for_another_orgs_invoice(
        app_client, seeded_biz, raw_conn, monkeypatch):
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_put", lambda path: _fake_sign(path))
    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])

    r = await app_client.post(
        f"/invoices/{inv}/pages/1/upload-url", headers=auth(s["bob"]))

    assert r.status_code == 404


async def test_confirm_records_sha_and_dimensions(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    inv = await _mint_invoice(raw_conn, s["acme_loc"])
    page = await _mint_page(raw_conn, inv, s["acme_loc"])
    await raw_conn.commit()

    r = await app_client.post(
        f"/invoices/{inv}/pages/1/confirm",
        json={"sha256": "a" * 64, "width": 1700, "height": 2200},
        headers=auth(s["alice"]))

    assert r.status_code == 204, r.text
    cur = await raw_conn.execute(
        "SELECT sha256, width, height FROM invoice_pages WHERE id = %s", (page,))
    assert await cur.fetchone() == ("a" * 64, 1700, 2200)


async def test_confirm_404s_for_a_page_that_does_not_exist(
        app_client, seeded_biz, raw_conn):
    """Confirm exists precisely so the server records that bytes arrived; a
    confirm for a page it has never seen must not silently succeed."""
    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])

    r = await app_client.post(
        f"/invoices/{inv}/pages/9/confirm",
        json={"sha256": "b" * 64, "width": 10, "height": 10},
        headers=auth(s["alice"]))

    assert r.status_code == 404


async def _fake_sign_get(path):
    return f"https://storage.test/get/{path}", "2026-08-03T12:00:00+00:00"


async def _confirm(raw_conn, inv, loc, page_no=1):
    """A page WITH bytes: sha256 set is what makes it downloadable."""
    page = await _mint_page(raw_conn, inv, loc, page_no)
    await raw_conn.execute(
        "UPDATE invoice_pages SET sha256 = %s, width = 1694, height = 2200"
        " WHERE id = %s", ("a" * 64, page))
    await raw_conn.commit()
    return page


async def test_download_url_signs_the_same_key_the_upload_wrote(
        app_client, seeded_biz, raw_conn, monkeypatch):
    """Download must resolve against the key upload derived, or it 404s in
    the bucket while both endpoints look correct in isolation."""
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_get", lambda path: _fake_sign_get(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])
    await _confirm(raw_conn, inv, s["acme_loc"], 2)

    r = await app_client.post(
        f"/invoices/{inv}/pages/2/download-url", headers=auth(s["alice"]))

    assert r.status_code == 200, r.text
    assert r.json()["url"].endswith(f"{s['acme']}/{inv}/2.jpg")
    assert r.json()["expires_at"]


async def test_download_url_409s_for_a_page_whose_bytes_never_confirmed(
        app_client, seeded_biz, raw_conn, monkeypatch):
    """Not 404: the row exists and is legitimately ours. 409 says the page
    is not in a state that has bytes, which is the truth and is actionable."""
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_get", lambda path: _fake_sign_get(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])
    await _mint_page(raw_conn, inv, s["acme_loc"], 1)   # no sha256
    await raw_conn.commit()

    r = await app_client.post(
        f"/invoices/{inv}/pages/1/download-url", headers=auth(s["alice"]))

    assert r.status_code == 409, r.text


async def test_download_url_404s_for_another_orgs_invoice(
        app_client, seeded_biz, raw_conn, monkeypatch):
    """404, never 403: distinguishing 'absent' from 'not yours' would leak
    the existence of another org's invoice."""
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_get", lambda path: _fake_sign_get(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])
    await _confirm(raw_conn, inv, s["acme_loc"], 1)

    r = await app_client.post(
        f"/invoices/{inv}/pages/1/download-url", headers=auth(s["bob"]))

    assert r.status_code == 404, r.text


async def test_download_url_404s_for_a_page_that_does_not_exist(
        app_client, seeded_biz, raw_conn, monkeypatch):
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_get", lambda path: _fake_sign_get(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])

    r = await app_client.post(
        f"/invoices/{inv}/pages/7/download-url", headers=auth(s["alice"]))

    assert r.status_code == 404, r.text


# --- sign_get itself ---------------------------------------------------
# Every route test above monkeypatches `sign_get` away, which is right for
# them -- they are about the route's status codes, not about Supabase. The
# consequence is that the function's own body, including the response key it
# reads, had no coverage at all. These two drive it directly over an httpx
# MockTransport so the storage contract is pinned somewhere.

def _storage_answers(monkeypatch, payload, status=200):
    """Point `sign_get` at a MockTransport speaking Supabase's shape."""
    import api.routes.invoices as mod
    monkeypatch.setenv("SUPABASE_URL", "https://storage.test/")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key")

    def handler(request):
        # The download signing endpoint, NOT the upload one. Signing the
        # wrong path would still return a URL and still fail in the bucket.
        assert request.url.path == (
            "/storage/v1/object/sign/invoices/org/inv/1.jpg"), request.url
        return httpx.Response(status, json=payload)

    # Bind the real class before patching -- `mod.httpx` IS the httpx module,
    # so a lambda that calls `httpx.AsyncClient` would call itself.
    real_client_cls = httpx.AsyncClient
    monkeypatch.setattr(
        mod.httpx, "AsyncClient",
        lambda *a, **kw: real_client_cls(transport=httpx.MockTransport(handler)))


async def test_sign_get_reads_the_signed_url_key_the_download_endpoint_sends(
        monkeypatch):
    """Spec §2.3's gotcha, finally pinned.

    Supabase's DOWNLOAD signing endpoint returns its path under `signedURL`;
    the UPLOAD one returns `url`. `sign_put` reads `url`, so a `sign_get`
    written by copying it raises KeyError against real Supabase while passing
    against any stub that happens to answer `url`. This test fails if the
    reader is ever "simplified" back to the upload spelling.
    """
    import api.routes.invoices as mod
    _storage_answers(
        monkeypatch,
        {"signedURL": "/object/sign/invoices/org/inv/1.jpg?token=t"})

    url, expires_at = await mod.sign_get("org/inv/1.jpg")

    assert url == ("https://storage.test/storage/v1"
                   "/object/sign/invoices/org/inv/1.jpg?token=t")
    assert expires_at


async def test_sign_get_502s_when_storage_answers_with_neither_url_key(
        monkeypatch):
    """A 200 whose body has neither key is storage changing its contract.

    That must surface as this function's own 502 -- the same idiom it already
    uses for a non-200 -- and not as a KeyError that FastAPI renders as an
    opaque 500 with a traceback in the logs and nothing useful to the client.
    """
    import api.routes.invoices as mod
    from fastapi import HTTPException
    _storage_answers(monkeypatch, {"unexpected": "shape"})

    with pytest.raises(HTTPException) as excinfo:
        await mod.sign_get("org/inv/1.jpg")

    assert excinfo.value.status_code == 502
