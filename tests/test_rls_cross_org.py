# tests/test_rls_cross_org.py
"""The cross-org isolation gate.

A tenancy leak is the one failure mode in this system that is silent:
everything works, and one restaurant's supplier pricing is visible to
another. Every assertion below goes through `tenant_connection` -- the real
app_user -> `SET LOCAL ROLE authenticated` checkout path -- never through the
`raw_conn` owner fixture, which owns every table and would skip the policies
being tested. The two exceptions are the fixture, which seeds as the owner on
purpose, and the catalog assertion at the bottom, which reads pg_class.

Running this file alone must answer "is tenancy intact?" -- so it covers all
seven tenant tables, not the three the task brief named. A hole in
`invite_all` used to sail through every assertion here.

The brief specified seven assertions; they are all still here, widened:

    read locations / organizations  -> test_org_a_cannot_read_org_b_rows
    write into org B                -> test_org_a_cannot_write_into_org_b
    update org B's row by id        -> test_org_a_cannot_update_org_b_row_by_id
    delete org B's row              -> test_org_a_cannot_delete_org_b_row
    escalate via membership insert  -> kept standalone, see its docstring
    unauthenticated sees nothing    -> test_unauthenticated_claims_see_nothing
"""
import uuid

import pytest
from tests.conftest import apply_migrations, TENANT_TABLES
from tests.factories import (
    make_user, make_org, add_member, make_location,
    make_ingredient, make_purchase, make_recipe, add_recipe_item)
from api.db import pool_open, tenant_connection


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def two_orgs(raw_conn):
    """Two orgs, one owner each, and one row per tenant table per org.

    Seeded through `raw_conn`, which is the owner and bypasses RLS. Nothing
    below reads it back through that connection.
    """
    await apply_migrations(raw_conn)
    alice = await make_user(raw_conn, "alice@acme.test")
    bob = await make_user(raw_conn, "bob@bistro.test")
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    alice_m = await add_member(raw_conn, alice, acme, "owner")
    bob_m = await add_member(raw_conn, bob, bistro, "owner")
    acme_loc = await make_location(raw_conn, acme, "Acme Main")
    bistro_loc = await make_location(raw_conn, bistro, "Bistro Main")

    # A user with no profile and no membership. Without one, the cross-tenant
    # INSERT into `profiles` would have to target Bob, who already has a row --
    # and would then be refused by the primary key before any policy ran,
    # passing the test for the wrong reason.
    cur = await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), %s) RETURNING id",
        ("mallory@nowhere.test",),
    )
    (mallory,) = await cur.fetchone()

    ids = dict(alice=alice, bob=bob, mallory=mallory, acme=acme, bistro=bistro,
               alice_m=alice_m, bob_m=bob_m, acme_loc=acme_loc, bistro_loc=bistro_loc)

    # One row per business table per org, through the same factories
    # `test_business_rls.py` uses -- these tables have no dedicated per-table
    # loop above because they were not TENANT_TABLES until this task.
    for side, loc in (("acme", acme_loc), ("bistro", bistro_loc)):
        ing = await make_ingredient(raw_conn, loc, f"{side}-flour")
        ids[f"{side}_ing"] = ing
        ids[f"{side}_purchase"] = await make_purchase(
            raw_conn, loc, ing, "2026-07-01", 10, 20.00)
        recipe = await make_recipe(raw_conn, loc, f"{side}-special", 12.00)
        ids[f"{side}_recipe"] = recipe
        ids[f"{side}_item"] = await add_recipe_item(raw_conn, loc, recipe, ing, 1)

    for side, org, user in (("acme", acme, alice), ("bistro", bistro, bob)):
        cur = await raw_conn.execute(
            "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at)"
            " VALUES (%s, %s, 'manager', %s, %s, now() + interval '7 days') RETURNING id",
            (org, f"hire@{side}.test", f"invite-{side}", user),
        )
        (ids[f"{side}_invite"],) = await cur.fetchone()
        cur = await raw_conn.execute(
            "INSERT INTO email_verifications (user_id, email, token_hash, expires_at)"
            " VALUES (%s, %s, %s, now() + interval '1 day') RETURNING id",
            (user, f"verify-{side}@test.example", f"verify-{side}"),
        )
        (ids[f"{side}_ev"],) = await cur.fetchone()
        cur = await raw_conn.execute(
            "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at)"
            " VALUES (%s, %s, now() + interval '1 day') RETURNING id",
            (str(user), f"link-{side}"),
        )
        (ids[f"{side}_alr"],) = await cur.fetchone()
        cur = await raw_conn.execute(
            "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
            " VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}') RETURNING op_id",
            (org,),
        )
        (ids[f"{side}_sync_op"],) = await cur.fetchone()
    await raw_conn.commit()
    return ids


@pytest.fixture
def spec(two_orgs):
    """Per table: Alice's own row, Bob's row, and a cross-tenant INSERT.

    `mine` and `theirs` are values of `key`, so one read, one update and one
    delete assertion serve all seven tables unchanged. A table added to
    TENANT_TABLES but not here raises KeyError -- loudly -- rather than
    shrinking the gate by one table in silence.
    """
    t = two_orgs
    return {
        "organizations": dict(
            key="id", mine=t["acme"], theirs=t["bistro"], col="name", val="pwned",
            # There is no INSERT policy on organizations by design (orgs are
            # created out of band), so any insert at all must be refused.
            insert=("INSERT INTO organizations (name) VALUES ('Trojan')", ()),
        ),
        "memberships": dict(
            key="id", mine=t["alice_m"], theirs=t["bob_m"], col="role", val="owner",
            insert=("INSERT INTO memberships (user_id, org_id, role)"
                    " VALUES (%s, %s, 'manager')", (t["mallory"], t["bistro"])),
        ),
        "locations": dict(
            key="id", mine=t["acme_loc"], theirs=t["bistro_loc"], col="name", val="pwned",
            insert=("INSERT INTO locations (org_id, name) VALUES (%s, 'Trojan')",
                    (t["bistro"],)),
        ),
        "invites": dict(
            key="id", mine=t["acme_invite"], theirs=t["bistro_invite"],
            col="email", val="pwned@x.test",
            insert=("INSERT INTO invites (org_id, email, role, token_hash, invited_by,"
                    " expires_at) VALUES (%s, 'x@x.test', 'owner', 'trojan-invite', %s,"
                    " now() + interval '1 day')", (t["bistro"], t["alice"])),
        ),
        "profiles": dict(
            key="user_id", mine=t["alice"], theirs=t["bob"],
            col="contact_email", val="pwned@x.test",
            insert=("INSERT INTO profiles (user_id, contact_email) VALUES (%s, 'x@x.test')",
                    (t["mallory"],)),
        ),
        "email_verifications": dict(
            key="id", mine=t["acme_ev"], theirs=t["bistro_ev"],
            col="token_hash", val="pwned-verify",
            insert=("INSERT INTO email_verifications (user_id, token_hash, expires_at)"
                    " VALUES (%s, 'trojan-verify', now() + interval '1 day')", (t["bob"],)),
        ),
        "apple_link_requests": dict(
            key="id", mine=t["acme_alr"], theirs=t["bistro_alr"],
            col="token_hash", val="pwned-link",
            insert=("INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at)"
                    " VALUES (%s, 'trojan-link', now() + interval '1 day')",
                    (str(t["bob"]),)),
        ),
        "ingredients": dict(
            key="id", mine=t["acme_ing"], theirs=t["bistro_ing"],
            col="name", val="pwned",
            insert=("INSERT INTO ingredients (location_id, name, base_unit)"
                    " VALUES (%s, 'Trojan', 'lb')", (t["bistro_loc"],)),
        ),
        "purchases": dict(
            key="id", mine=t["acme_purchase"], theirs=t["bistro_purchase"],
            col="unit", val="pwned",
            insert=("INSERT INTO purchases (location_id, ingredient_id,"
                    " purchased_on, qty, unit, qty_base_units, total_price)"
                    " VALUES (%s, %s, '2026-07-01', 1, 'lb', 1, 1.00)",
                    (t["bistro_loc"], t["bistro_ing"])),
        ),
        "recipes": dict(
            key="id", mine=t["acme_recipe"], theirs=t["bistro_recipe"],
            col="name", val="pwned",
            insert=("INSERT INTO recipes (location_id, name, menu_price)"
                    " VALUES (%s, 'Trojan', 1.00)", (t["bistro_loc"],)),
        ),
        "recipe_items": dict(
            key="id", mine=t["acme_item"], theirs=t["bistro_item"],
            col="qty_base_units", val="9.9999",
            insert=("INSERT INTO recipe_items (location_id, recipe_id,"
                    " ingredient_id, qty_base_units) VALUES (%s, %s, %s, 1)",
                    (t["bistro_loc"], t["bistro_recipe"], t["bistro_ing"])),
        ),
        "sync_ops": dict(
            key="op_id", mine=t["acme_sync_op"], theirs=t["bistro_sync_op"],
            col="batch_id", val=str(uuid.uuid4()),
            insert=("INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
                    " VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}')",
                    (t["bistro"],)),
        ),
    }


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_org_a_cannot_read_org_b_rows(db_url, two_orgs, spec, table):
    s = spec[table]
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute(f"SELECT {s['key']} FROM {table}")
        seen = {r[0] for r in await cur.fetchall()}
    await pool.close()
    # Both halves matter. The first catches a policy set that denies
    # everything -- which would satisfy every other assertion in this file.
    assert s["mine"] in seen, f"{table}: caller cannot see their own row"
    assert seen == {s["mine"]}, f"TENANCY LEAK: {table} exposed {seen - {s['mine']}}"


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_org_a_cannot_write_into_org_b(db_url, two_orgs, spec, table):
    """WITH CHECK is the clause under test. USING alone would allow this."""
    sql, args = spec[table]["insert"]
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(sql, args)
    await pool.close()
    # Not just "it failed": a missing GRANT would also raise here, and would
    # go on doing so after every policy in 0004 was deleted.
    assert "row-level security" in str(exc.value).lower(), str(exc.value)


# sync_ops is a write-once ledger (0014 §5): `authenticated` gets SELECT and
# INSERT only, never UPDATE -- a replayed op must find its stored result
# untouched, not editable by any tenant. That is a grant-level denial
# ("permission denied"), not an RLS one, and -- same reasoning as
# NO_DELETE_GRANT_TABLES below -- it applies uniformly regardless of whose
# row is targeted, so it never reaches the "0 rows matched" RLS outcome the
# other tenant tables produce.
NO_UPDATE_GRANT_TABLES = {"sync_ops"}


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_org_a_cannot_update_org_b_row_by_id(db_url, two_orgs, spec, table):
    s = spec[table]
    pool = await pool_open(app_url(db_url))
    if table in NO_UPDATE_GRANT_TABLES:
        with pytest.raises(Exception) as exc:
            async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
                await conn.execute(
                    f"UPDATE {table} SET {s['col']} = %s WHERE {s['key']} = %s",
                    (s["val"], s["theirs"]),
                )
        assert "permission denied" in str(exc.value).lower()
    else:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            cur = await conn.execute(
                f"UPDATE {table} SET {s['col']} = %s WHERE {s['key']} = %s",
                (s["val"], s["theirs"]),
            )
            assert cur.rowcount == 0, f"TENANCY LEAK: updated another org's {table} row"
    await pool.close()


# The four 0012 business tables tombstone (`deleted_at`) rather than hard
# deleting, and 0012 REVOKEs DELETE from `authenticated` on all four to make
# that structural rather than a convention -- see that migration's comment
# and `test_business_rls.py::test_delete_is_not_granted`, which pins the
# same-org case. That is a grant-level denial ("permission denied"), not an
# RLS one, and it applies uniformly regardless of whose row is targeted -- so
# a cross-org DELETE against one of these fails the same way a same-org one
# does, never reaching the "0 rows matched" RLS outcome the other tenant
# tables produce.
NO_DELETE_GRANT_TABLES = {"ingredients", "purchases", "recipes", "recipe_items", "sync_ops"}


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_org_a_cannot_delete_org_b_row(db_url, two_orgs, spec, table):
    s = spec[table]
    pool = await pool_open(app_url(db_url))
    if table in NO_DELETE_GRANT_TABLES:
        with pytest.raises(Exception) as exc:
            async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
                await conn.execute(f"DELETE FROM {table} WHERE {s['key']} = %s", (s["theirs"],))
        assert "permission denied" in str(exc.value).lower()
    else:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            cur = await conn.execute(f"DELETE FROM {table} WHERE {s['key']} = %s", (s["theirs"],))
            assert cur.rowcount == 0, f"TENANCY LEAK: deleted another org's {table} row"
    await pool.close()


async def test_org_a_cannot_escalate_by_inserting_membership(db_url, two_orgs):
    """Kept separate from the parametrised insert above, which adds a third
    party to Bistro. This is the sharper case: Alice writing *herself* into
    Bistro as an owner, the one insert that would hand her every other table.
    """
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(
                "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, 'owner')",
                (two_orgs["alice"], two_orgs["bistro"]),
            )
    await pool.close()
    assert "row-level security" in str(exc.value).lower()


@pytest.mark.parametrize("table", TENANT_TABLES)
async def test_unauthenticated_claims_see_nothing(db_url, two_orgs, table):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {}) as conn:
        cur = await conn.execute(f"SELECT count(*) FROM {table}")
        (n,) = await cur.fetchone()
    await pool.close()
    assert n == 0, f"a caller with no sub saw {n} rows of {table}"


async def test_every_table_in_public_enables_and_forces_rls(raw_conn):
    """Deliberately NOT an allowlist -- that is the whole point.

    Every other RLS assertion in this suite iterates TENANT_TABLES, so a table
    added by a later migration is not merely unchecked, it is never looked
    for. `pg_policies` makes that worse: a table with zero policies contributes
    zero rows, so the with_check audit passes vacuously. And 0003's ALTER
    DEFAULT PRIVILEGES hands `authenticated` full DML on any future table
    automatically, with no GRANT line in the new migration to prompt its author
    to think about access, while RLS stays off by default. The combination is a
    readable, writable, world-visible table that the whole suite stays green
    over -- and Tasks 6-14 add exactly such tables.

    So this walks pg_class instead: whatever exists in `public` must be
    protected. Applies EVERY migration on disk (no `upto`) -- pinning a version
    here would restore precisely the blindness it exists to remove.
    """
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class"
        " WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p')"
        " ORDER BY relname"
    )
    rows = await cur.fetchall()
    present = {name for name, _, _ in rows}
    assert present >= set(TENANT_TABLES), f"tables vanished: {set(TENANT_TABLES) - present}"
    unguarded = [name for name, enabled, forced in rows if not (enabled and forced)]
    assert unguarded == [], (
        f"{unguarded}: every table in `public` must ENABLE and FORCE row level "
        "security. A new tenant table inherits full DML for `authenticated` from "
        "0003's ALTER DEFAULT PRIVILEGES but no policies, so until both flags are "
        "set it is readable and writable by every tenant. Add the two ALTER TABLE "
        "lines and its policies to the migration, and add it to TENANT_TABLES and "
        "to the `spec` fixture in this file."
    )


async def test_every_security_definer_function_in_public_is_hardened(raw_conn):
    """Final-review Important-6, promoted from deferred.

    Every deliberate RLS bypass in this system is a `SECURITY DEFINER`
    function in `public` owned by a dedicated NOLOGIN role
    (`current_user_memberships` 0004, `accept_invite_tx` 0006,
    `reject_write_to_scheduled_org` / `accounts_pending_identity_purge` /
    `purge_scheduled_orgs` 0007, `organizations_pending_purge` 0008). Each
    one runs with its owner's privileges, so each is exactly as safe as its
    `search_path` pin and its EXECUTE grant, and no more.

    That discipline was applied by hand, six times, checked only by review --
    on the one surface where this branch's own catalog-driven habit had been
    skipped, and which has already produced a demonstrated Critical
    (`accept_invite_tx` shipped without `pg_temp` last, so a caller-owned
    TEMP table could shadow an unqualified name inside a definer function and
    answer on its own behalf). So it is derived from the catalog instead, and
    a seventh definer function added by any later migration is covered the
    day it lands rather than the day someone remembers.

    Three properties, all of them things a real migration got wrong at least
    once:

      1. `search_path` is PINNED. Unset, the function resolves unqualified
         names against the CALLER's search_path, which the caller controls.
      2. `pg_temp` is not FIRST. Postgres never consults `pg_temp` for
         FUNCTION names, but it does for TABLE names, so a leading `pg_temp`
         lets a caller shadow `public.memberships` (etc.) with its own temp
         table inside a function running as a bypassing role. `pg_temp` last
         -- or absent, as 0004's two helpers have it -- is fine; first is
         not.
      3. PUBLIC holds no EXECUTE. Functions grant EXECUTE to PUBLIC BY
         DEFAULT, so a definer function whose migration forgets
         `REVOKE ALL ... FROM PUBLIC` is reachable by every role in the
         cluster, including `authenticated` and `app_user`. A NULL `proacl`
         is that default, i.e. a failure, not an absence of information.
    """
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT p.proname, p.proconfig, p.proacl IS NULL, "
        "       coalesce((SELECT bool_or(a.privilege_type = 'EXECUTE') "
        "                   FROM aclexplode(p.proacl) a WHERE a.grantee = 0), false) "
        "  FROM pg_proc p "
        " WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef "
        " ORDER BY p.proname"
    )
    rows = await cur.fetchall()
    assert len(rows) >= 6, (
        f"expected at least the six known SECURITY DEFINER functions, found "
        f"{[r[0] for r in rows]}"
    )

    unpinned, pg_temp_first, public_executable = [], [], []
    for name, proconfig, acl_is_default, public_has_execute in rows:
        settings = dict(
            entry.split("=", 1) for entry in (proconfig or []) if "=" in entry
        )
        search_path = settings.get("search_path")
        if search_path is None:
            unpinned.append(name)
        elif [s.strip() for s in search_path.split(",")][0] == "pg_temp":
            pg_temp_first.append(name)
        if acl_is_default or public_has_execute:
            public_executable.append(name)

    assert unpinned == [], (
        f"{unpinned}: every SECURITY DEFINER function must SET search_path. "
        "Without it, unqualified names inside a function running as a "
        "bypassing role resolve against the caller's own search_path."
    )
    assert pg_temp_first == [], (
        f"{pg_temp_first}: pg_temp must never come first in a SECURITY DEFINER "
        "function's search_path -- a caller-owned TEMP table would shadow the "
        "public table the function means to read. Put it last (0006/0007/0008) "
        "or leave it out (0004)."
    )
    assert public_executable == [], (
        f"{public_executable}: every SECURITY DEFINER function must "
        "`REVOKE ALL ... FROM PUBLIC` and then grant EXECUTE only to the one "
        "role that needs it. Functions are EXECUTE-to-PUBLIC by default, so "
        "forgetting the REVOKE hands the bypass to `authenticated` and "
        "`app_user` alike."
    )
