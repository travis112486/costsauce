# tests/test_invoices.py
"""Phase 3a invoice capture: schema shape, the live-only page unique, the
purchases link, and org isolation on the two new tables."""
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
