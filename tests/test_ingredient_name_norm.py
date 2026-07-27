# tests/test_ingredient_name_norm.py
"""Task 11: migration 0015's SQL mirror of api.kernel.normalize_name, and the
partial unique index that closes 1b's create_ingredient TOCTOU (two
concurrent creates can both pass the app-side scan; the DB constraint makes
the second one lose at commit)."""
import json
import pathlib

import psycopg
import pytest

from api.kernel import normalize_name
from tests.factories import make_ingredient, make_location
from tests.test_auth import mint
from tests.test_ingredients_routes import auth

GOLDEN_VECTORS = pathlib.Path(__file__).parent.parent / "shared" / "golden-vectors.json"

EDGE_CASES = [
    "Chicken Breasts",
    "  GRASS-fed   Beef  ",
    "Swiss",
    "Eggs",
    "óil",
    "s",
    "ss",
    "bass",
    "XS",
    "a1-2 sauce!!",
    "",
]


def _collect_names(obj, out):
    """Every string value under a "name" key anywhere in the golden-vectors
    tree -- the brief calls for "every ingredient name in
    shared/golden-vectors.json"; the file carries no dedicated ingredient-name
    section, so its `name` fields (scenario labels for the other kernel
    functions) are the closest thing to a name battery it offers, and feeding
    them through normalize_ingredient_name costs nothing -- they're just more
    input diversity for the equivalence property."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "name" and isinstance(v, str):
                out.append(v)
            else:
                _collect_names(v, out)
    elif isinstance(obj, list):
        for item in obj:
            _collect_names(item, out)


def _battery():
    data = json.loads(GOLDEN_VECTORS.read_text())
    names = []
    _collect_names(data, names)
    names.extend(EDGE_CASES)
    # de-dupe, keep order, for a readable failure if one entry mismatches
    seen = set()
    out = []
    for n in names:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out


async def test_normalize_equivalence_battery(raw_conn):
    """SQL normalize_ingredient_name must match api.kernel.normalize_name
    byte-for-byte on every name in the battery."""
    from tests.conftest import apply_migrations
    await apply_migrations(raw_conn)
    for name in _battery():
        cur = await raw_conn.execute(
            "SELECT normalize_ingredient_name(%s)", (name,))
        (sql_result,) = await cur.fetchone()
        assert sql_result == normalize_name(name), f"mismatch for {name!r}"


async def test_toctou_second_insert_same_location_fails(seeded_biz, raw_conn):
    """Two concurrent-equivalent inserts of names that normalize the same, at
    the same location: the second loses at commit."""
    s = seeded_biz
    await raw_conn.execute(
        "INSERT INTO ingredients (location_id, name, base_unit)"
        " VALUES (%s, %s, 'lb')", (s["acme_loc"], "Chicken Breast"))
    await raw_conn.commit()
    with pytest.raises(psycopg.errors.UniqueViolation):
        await raw_conn.execute(
            "INSERT INTO ingredients (location_id, name, base_unit)"
            " VALUES (%s, %s, 'lb')", (s["acme_loc"], "chicken breasts"))
        await raw_conn.commit()


async def test_toctou_different_location_same_norm_name_ok(seeded_biz, raw_conn):
    s = seeded_biz
    other_loc = await make_location(raw_conn, s["acme"], "Acme Second")
    await raw_conn.execute(
        "INSERT INTO ingredients (location_id, name, base_unit)"
        " VALUES (%s, %s, 'lb')", (s["acme_loc"], "Chicken Breast"))
    await raw_conn.execute(
        "INSERT INTO ingredients (location_id, name, base_unit)"
        " VALUES (%s, %s, 'lb')", (other_loc, "chicken breasts"))
    await raw_conn.commit()  # no error: different locations don't collide


async def test_toctou_reusing_tombstoned_name_ok(seeded_biz, raw_conn):
    s = seeded_biz
    ing = await make_ingredient(raw_conn, s["acme_loc"], "Chicken Breast")
    await raw_conn.execute(
        "UPDATE ingredients SET deleted_at = now() WHERE id = %s", (ing,))
    await raw_conn.execute(
        "INSERT INTO ingredients (location_id, name, base_unit)"
        " VALUES (%s, %s, 'lb')", (s["acme_loc"], "chicken breasts"))
    await raw_conn.commit()  # no error: the live partial index ignores tombstones


async def test_route_pre_scan_still_reports_named_matches(app_client, seeded_biz):
    """The common case (app-side scan finds the collision before the INSERT
    is even attempted) keeps its friendly 409 shape."""
    s = seeded_biz
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/ingredients",
        json={"name": "Chicken Breast", "base_unit": "lb"},
        headers=auth(s["alice"]))
    assert r.status_code == 201, r.text
    r2 = await app_client.post(
        f"/locations/{s['acme_loc']}/ingredients",
        json={"name": "chicken breasts", "base_unit": "lb"},
        headers=auth(s["alice"]))
    assert r2.status_code == 409
    assert r2.json()["detail"]["detail"] == "duplicate"
    assert r2.json()["detail"]["matches"][0]["name"] == "Chicken Breast"


async def test_pre_scan_catches_normalized_collision_seeded_off_route(
        app_client, seeded_biz, raw_conn):
    """Per the brief: a true race (insert landing between the route's scan
    and its own INSERT) can't be reproduced in-process on a single
    connection. This is the brief's prescribed stand-in: seed a normalized-
    colliding row via the factory (bypassing the route's scan at seed time)
    with a raw form that differs from the POSTed name ("Chicken  Breast" vs
    "chicken breasts"), then POST the collision and assert 409, not 500.

    Fix (review round 1, Important-1): this test's 409 comes from the
    pre-scan, NOT the except-branch -- create_ingredient's own live-candidate
    scan runs at request time and finds the seeded row (both use the
    identical normalize_name, so anything the scan misses the index would
    also miss). It is kept, correctly named now, as coverage for "pre-scan
    still works when the collision was seeded outside the route." The
    except-branch itself is covered by
    test_race_loser_409_comes_from_except_branch below, which forces
    execution past the scan deterministically via monkeypatch."""
    s = seeded_biz
    await make_ingredient(raw_conn, s["acme_loc"], "Chicken  Breast")
    await raw_conn.commit()
    r = await app_client.post(
        f"/locations/{s['acme_loc']}/ingredients",
        json={"name": "chicken breasts", "base_unit": "lb"},
        headers=auth(s["alice"]))
    assert r.status_code == 409
    assert r.json()["detail"]["detail"] == "duplicate"


async def test_race_loser_409_comes_from_except_branch(
        app_client, seeded_biz, raw_conn, monkeypatch):
    """Fix (review round 1, Important-1): deterministically exercises the new
    except-UniqueViolation branch in create_ingredient, rather than relying
    on the pre-scan to (mis-)report the same 409 shape.

    Seeds a normalized-colliding row via the factory, then monkeypatches
    `api.routes.ingredients._candidates` to return an empty list -- standing
    in for "another create landed in the TOCTOU window after our scan ran"
    without needing real concurrency. With the scan blinded, the route
    proceeds straight to the INSERT, which the migration 0015 partial unique
    index rejects; the except-branch must turn that UniqueViolation into the
    friendly 409 shape rather than an unhandled 500."""
    import api.routes.ingredients as ingredients_route
    s = seeded_biz
    await make_ingredient(raw_conn, s["acme_loc"], "Chicken  Breast")
    await raw_conn.commit()

    async def _no_candidates(conn, location_id):
        return []

    monkeypatch.setattr(ingredients_route, "_candidates", _no_candidates)

    r = await app_client.post(
        f"/locations/{s['acme_loc']}/ingredients",
        json={"name": "chicken breasts", "base_unit": "lb"},
        headers=auth(s["alice"]))
    assert r.status_code == 409
    assert r.json()["detail"] == {"detail": "duplicate", "matches": []}
