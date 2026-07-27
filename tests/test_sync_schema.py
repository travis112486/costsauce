# tests/test_sync_schema.py
"""Migration 0014: the three-timestamp split and the stamp trigger.

Catalog + behavior checks run through raw_conn (owner). RLS is NOT under test
here — the trigger is SECURITY DEFINER and fires identically on every path;
tenancy for the sync endpoints lands in test_sync_ops_rls.py and
test_rls_cross_org.py.
"""
import pytest
import psycopg
from tests.conftest import apply_migrations
from tests.factories import make_user, make_org, add_member, make_location, make_ingredient

SYNCABLE = ("ingredients", "purchases", "recipes", "recipe_items")


@pytest.fixture
async def synced(raw_conn):
    await apply_migrations(raw_conn)  # all, incl. 0014
    alice = await make_user(raw_conn, "alice@acme.test")
    acme = await make_org(raw_conn, "Acme Diner")
    await add_member(raw_conn, alice, acme, "owner")
    loc = await make_location(raw_conn, acme, "Acme Main")
    await raw_conn.commit()
    return dict(alice=alice, acme=acme, loc=loc)


async def _counter(conn, org):
    cur = await conn.execute(
        "SELECT sync_counter FROM organizations WHERE id = %s", (org,))
    (n,) = await cur.fetchone()
    return n


async def test_sync_columns_exist_not_null(raw_conn):
    await apply_migrations(raw_conn)
    for table in SYNCABLE:
        cur = await raw_conn.execute(
            "SELECT column_name, is_nullable FROM information_schema.columns"
            " WHERE table_schema = 'public' AND table_name = %s"
            "   AND column_name IN ('client_mutated_at','server_seq','updated_at')",
            (table,))
        cols = {r[0]: r[1] for r in await cur.fetchall()}
        assert set(cols) == {"client_mutated_at", "server_seq", "updated_at"}, table
        assert all(v == "NO" for v in cols.values()), (table, cols)


async def test_backfill_is_dense_per_org_and_counter_matches(raw_conn):
    """0013's sample-org seed rows get seqs 1..N with sync_counter == N."""
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute("""
        SELECT s.org_id, array_agg(s.server_seq ORDER BY s.server_seq)
        FROM (
          SELECT l.org_id, t.server_seq FROM ingredients t JOIN locations l ON l.id = t.location_id
          UNION ALL SELECT l.org_id, t.server_seq FROM purchases t JOIN locations l ON l.id = t.location_id
          UNION ALL SELECT l.org_id, t.server_seq FROM recipes t JOIN locations l ON l.id = t.location_id
          UNION ALL SELECT l.org_id, t.server_seq FROM recipe_items t JOIN locations l ON l.id = t.location_id
        ) s GROUP BY s.org_id""")
    rows = await cur.fetchall()
    assert rows, "the 0013 sample org should have produced syncable rows"
    for org_id, seqs in rows:
        assert seqs == list(range(1, len(seqs) + 1)), (org_id, seqs)
        assert await _counter(raw_conn, org_id) == len(seqs)


async def test_insert_and_update_allocate_fresh_seqs(synced, raw_conn):
    s = synced
    ing = await make_ingredient(raw_conn, s["loc"], "Flour")
    cur = await raw_conn.execute(
        "SELECT server_seq, updated_at, client_mutated_at FROM ingredients WHERE id = %s", (ing,))
    seq1, upd1, cm1 = await cur.fetchone()
    assert seq1 == await _counter(raw_conn, s["acme"]) == 1
    await raw_conn.execute(
        "UPDATE ingredients SET name = 'Bread Flour' WHERE id = %s", (ing,))
    cur = await raw_conn.execute(
        "SELECT server_seq, updated_at, client_mutated_at FROM ingredients WHERE id = %s", (ing,))
    seq2, upd2, cm2 = await cur.fetchone()
    assert seq2 == 2 and seq2 > seq1, "an update must move the row past any cursor"
    assert upd2 >= upd1
    assert cm2 == cm1, "the trigger must NEVER touch client_mutated_at (device clock only)"
    await raw_conn.commit()


async def test_tombstone_is_monotonic(synced, raw_conn):
    s = synced
    ing = await make_ingredient(raw_conn, s["loc"], "Salt")
    await raw_conn.execute(
        "UPDATE ingredients SET deleted_at = now() WHERE id = %s", (ing,))
    await raw_conn.commit()
    with pytest.raises(psycopg.Error) as exc:
        await raw_conn.execute(
            "UPDATE ingredients SET deleted_at = NULL WHERE id = %s", (ing,))
    assert exc.value.sqlstate == "CS423"
    await raw_conn.rollback()
    with pytest.raises(psycopg.Error) as exc:
        await raw_conn.execute(
            "UPDATE ingredients SET deleted_at = now() + interval '1 hour'"
            " WHERE id = %s", (ing,))
    assert exc.value.sqlstate == "CS423"
    await raw_conn.rollback()


async def test_future_client_clock_rejected(synced, raw_conn):
    s = synced
    with pytest.raises(psycopg.Error) as exc:
        await raw_conn.execute(
            "INSERT INTO ingredients (location_id, name, base_unit, client_mutated_at)"
            " VALUES (%s, 'Pepper', 'oz', now() + interval '10 minutes')", (s["loc"],))
    assert exc.value.sqlstate == "CS425"
    await raw_conn.rollback()
    await raw_conn.execute(
        "INSERT INTO ingredients (location_id, name, base_unit, client_mutated_at)"
        " VALUES (%s, 'Pepper', 'oz', now() + interval '1 minute')", (s["loc"],))
    await raw_conn.commit()


async def test_scheduled_org_write_never_bumps_counter(synced, raw_conn):
    """*_reject_scheduled must fire BEFORE *_sync_stamp (alphabetical:
    'r' < 's'), so a frozen org's counter cannot creep."""
    s = synced
    await make_ingredient(raw_conn, s["loc"], "Sugar")
    await raw_conn.commit()
    before = await _counter(raw_conn, s["acme"])
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() WHERE id = %s",
        (s["acme"],))
    with pytest.raises(Exception) as exc:
        await make_ingredient(raw_conn, s["loc"], "Cinnamon")
    assert getattr(exc.value, "sqlstate", None) == "CS410"
    await raw_conn.rollback()
    assert await _counter(raw_conn, s["acme"]) == before


async def test_trigger_names_order_reject_before_stamp(raw_conn):
    await apply_migrations(raw_conn)
    for table in SYNCABLE:
        cur = await raw_conn.execute(
            "SELECT tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid"
            " WHERE c.relname = %s AND NOT t.tgisinternal ORDER BY tgname", (table,))
        names = [r[0] for r in await cur.fetchall()]
        assert f"{table}_reject_scheduled" in names and f"{table}_sync_stamp" in names
        assert names.index(f"{table}_reject_scheduled") < names.index(f"{table}_sync_stamp")


async def test_route_updates_advance_client_mutated_at(app_client, seeded_biz, raw_conn):
    """Route UPDATEs must stamp client_mutated_at = now() to ensure LWW
    works: a web edit beats an older offline device edit."""
    from tests.factories import make_recipe
    from tests.test_ingredients_routes import auth
    s = seeded_biz
    # Create a recipe via POST — INSERT will set client_mutated_at via DEFAULT
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/recipes",
        json={"name": "Chicken Piccata", "menu_price": "18.99", "target_fc_pct": "35.00",
              "items": []},
        headers=auth(s["alice"]))
    assert r.status_code == 201, r.text
    recipe_id = r.json()["recipe_id"]
    await raw_conn.commit()
    # Read initial client_mutated_at
    cur = await raw_conn.execute(
        "SELECT client_mutated_at FROM recipes WHERE id = %s", (recipe_id,))
    (cm1,) = await cur.fetchone()
    # PUT a rename — UPDATE must stamp client_mutated_at = now()
    r = await app_client.put(
        f"/locations/{s['acme_loc']}/recipes/{recipe_id}",
        json={"name": "Chicken Piccata Lemon", "menu_price": "19.99", "target_fc_pct": "35.00",
              "items": []},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    await raw_conn.commit()
    # Read updated client_mutated_at
    cur = await raw_conn.execute(
        "SELECT client_mutated_at FROM recipes WHERE id = %s", (recipe_id,))
    (cm2,) = await cur.fetchone()
    # Verify it advanced (now() moves per statement in PostgreSQL)
    assert cm2 > cm1, f"client_mutated_at must advance on route UPDATE: {cm1} -> {cm2}"


async def test_sync_definer_is_inert(raw_conn):
    """Same hygiene bar rls_definer is held to in test_rls_policies.py."""
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT rolcanlogin, rolbypassrls, rolsuper FROM pg_roles"
        " WHERE rolname = 'sync_definer'")
    row = await cur.fetchone()
    assert row == (False, False, False)
    cur = await raw_conn.execute(
        "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid"
        " WHERE r.rolname = 'sync_definer'")
    (members,) = await cur.fetchone()
    assert members == 0, "the GRANT ... TO CURRENT_USER bracket must be closed"
