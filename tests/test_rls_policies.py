# tests/test_rls_policies.py
"""Does migration 0004 actually take effect?

Task 5 owns the cross-org isolation gate. This file owns the layer underneath
it: the properties of the policies themselves that a cross-org test would
still pass without -- FORCE being set, the claim helpers failing closed, and
the one deliberate RLS bypass in the schema being no wider than it claims.

Everything that exercises a policy goes through `tenant_connection`, never
through `raw_conn`. `raw_conn` is the superuser/owner connection: it bypasses
RLS, so a policy checked through it appears to pass while being skipped.
"""
import pytest
from tests.conftest import apply_migrations
from api.db import pool_open, tenant_connection

TENANT_TABLES = (
    "organizations", "memberships", "locations", "invites",
    "profiles", "email_verifications", "apple_link_requests",
)

ALICE = "11111111-1111-7111-8111-111111111111"   # owner      of Acme
CAROL = "33333333-3333-7333-8333-333333333333"   # manager    of Acme
DAVE = "55555555-5555-7555-8555-555555555555"    # bookkeeper of Acme
BOB = "22222222-2222-7222-8222-222222222222"     # owner      of Bistro
ACME = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
BISTRO = "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb"
ACME_LOC = "cccccccc-cccc-7ccc-8ccc-cccccccccccc"
BISTRO_LOC = "dddddddd-dddd-7ddd-8ddd-dddddddddddd"


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def seeded(raw_conn):
    """Two orgs, three users. Seeded as the owner, which bypasses RLS."""
    await apply_migrations(raw_conn, upto=4)
    for uid, email in ((ALICE, "alice@acme.test"), (BOB, "bob@bistro.test"),
                       (CAROL, "carol@acme.test"), (DAVE, "dave@acme.test")):
        await raw_conn.execute(
            "INSERT INTO auth.users (id, email) VALUES (%s, %s)", (uid, email))
        await raw_conn.execute(
            "INSERT INTO profiles (user_id, contact_email) VALUES (%s, %s)", (uid, email))
    for oid, name in ((ACME, "Acme Diner"), (BISTRO, "Bistro Nine")):
        await raw_conn.execute(
            "INSERT INTO organizations (id, name) VALUES (%s, %s)", (oid, name))
    for uid, oid, role in ((ALICE, ACME, "owner"), (CAROL, ACME, "manager"),
                           (DAVE, ACME, "bookkeeper"), (BOB, BISTRO, "owner")):
        await raw_conn.execute(
            "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, %s)",
            (uid, oid, role))
    for lid, oid, name in ((ACME_LOC, ACME, "Acme Main"), (BISTRO_LOC, BISTRO, "Bistro Main")):
        await raw_conn.execute(
            "INSERT INTO locations (id, org_id, name) VALUES (%s, %s, %s)", (lid, oid, name))
    for oid, uid, email in ((ACME, ALICE, "hire@acme.test"), (BISTRO, BOB, "hire@bistro.test")):
        await raw_conn.execute(
            "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
            "VALUES (%s, %s, 'manager', %s, %s, now() + interval '7 days')",
            (oid, email, f"hash-{oid}", uid))
    for uid in (ALICE, BOB):
        await raw_conn.execute(
            "INSERT INTO email_verifications (user_id, token_hash, expires_at) "
            "VALUES (%s, %s, now() + interval '1 day')", (uid, f"ev-{uid}"))
        await raw_conn.execute(
            "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at) "
            "VALUES (%s, %s, now() + interval '1 day')", (uid, f"al-{uid}"))
    await raw_conn.commit()
    return None


@pytest.fixture
async def pool(db_url, seeded):
    p = await pool_open(app_url(db_url))
    try:
        yield p
    finally:
        await p.close()


# --------------------------------------------------------------------------
# Step 2 of the brief, adapted. The brief ran a bare `psql "$TEST_DATABASE_URL"`;
# that variable is normally unset here because the harness starts an ephemeral
# container instead, so the check as written would silently not run.
# --------------------------------------------------------------------------
async def test_all_seven_tenant_tables_enable_and_force_rls(raw_conn):
    await apply_migrations(raw_conn, upto=4)
    cur = await raw_conn.execute(
        "SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class "
        "WHERE relname = ANY(%s) AND relnamespace = 'public'::regnamespace "
        "ORDER BY relname",
        (list(TENANT_TABLES),),
    )
    rows = await cur.fetchall()
    assert len(rows) == len(TENANT_TABLES), f"missing tables: {rows}"
    for name, enabled, forced in rows:
        assert enabled, f"{name}: ROW LEVEL SECURITY not enabled"
        assert forced, f"{name}: FORCE ROW LEVEL SECURITY not set -- the owner skips policies"


async def test_every_policy_carries_with_check_where_it_can_write(raw_conn):
    """USING alone lets a caller write a row into another org."""
    await apply_migrations(raw_conn, upto=4)
    cur = await raw_conn.execute(
        "SELECT tablename, policyname, cmd FROM pg_policies "
        "WHERE schemaname = 'public' AND cmd IN ('ALL', 'INSERT', 'UPDATE') "
        "AND with_check IS NULL ORDER BY tablename, policyname"
    )
    assert await cur.fetchall() == []


# --------------------------------------------------------------------------
# Claim helpers must fail closed, not raise. A helper that raises turns a
# malformed `sub` into a 500 on every query the caller makes.
# --------------------------------------------------------------------------
@pytest.mark.parametrize("claims", [
    {},                                    # no sub at all
    {"sub": ""},                           # blank sub
    {"sub": "not-a-uuid"},                 # unparseable sub
    {"sub": "'; DROP TABLE locations; --"},
    {"sub": None},                         # JSON null
])
async def test_malformed_claims_deny_rather_than_raise(pool, claims):
    async with tenant_connection(pool, claims) as conn:
        cur = await conn.execute("SELECT current_user_id()")
        (uid,) = await cur.fetchone()
        assert uid is None
        for table in TENANT_TABLES:
            cur = await conn.execute(f"SELECT count(*) FROM {table}")
            (n,) = await cur.fetchone()
            assert n == 0, f"{table}: caller with claims {claims!r} saw {n} rows"


async def test_non_json_claims_deny_rather_than_raise(pool):
    """set_config is a text channel; nothing guarantees the value parses."""
    async with tenant_connection(pool, {"sub": ALICE}) as conn:
        await conn.execute("SELECT set_config('request.jwt.claims', 'not json', true)")
        cur = await conn.execute("SELECT current_user_id(), current_jwt_sub()")
        assert await cur.fetchone() == (None, None)
        cur = await conn.execute("SELECT count(*) FROM locations")
        assert (await cur.fetchone())[0] == 0


# --------------------------------------------------------------------------
# Reads. Every tenant table, through the real checkout path.
# --------------------------------------------------------------------------
async def test_reads_are_scoped_to_the_callers_org(pool):
    async with tenant_connection(pool, {"sub": ALICE}) as conn:
        cur = await conn.execute("SELECT id FROM locations")
        assert {str(r[0]) for r in await cur.fetchall()} == {ACME_LOC}
        cur = await conn.execute("SELECT id FROM organizations")
        assert {str(r[0]) for r in await cur.fetchall()} == {ACME}
        cur = await conn.execute("SELECT org_id FROM invites")
        assert {str(r[0]) for r in await cur.fetchall()} == {ACME}
        cur = await conn.execute("SELECT user_id FROM profiles")
        assert {str(r[0]) for r in await cur.fetchall()} == {ALICE}
        cur = await conn.execute("SELECT user_id FROM email_verifications")
        assert {str(r[0]) for r in await cur.fetchall()} == {ALICE}
        cur = await conn.execute("SELECT apple_sub FROM apple_link_requests")
        assert {r[0] for r in await cur.fetchall()} == {ALICE}


@pytest.mark.parametrize("sub", [ALICE, CAROL, DAVE])
async def test_caller_sees_every_membership_of_their_own_org_only(pool, sub):
    """Task 9's last-owner protection counts owners org-wide; it needs this.

    Parametrised over all three roles because ALICE alone does not exercise
    `membership_select`: she is an owner, so `membership_write` -- a FOR ALL
    policy, whose USING also serves SELECT -- already returns the same rows.
    Drop `membership_select` and ALICE still sees 3 while CAROL and DAVE see 0.
    Same masking as location_write/location_select.
    """
    async with tenant_connection(pool, {"sub": sub}) as conn:
        cur = await conn.execute("SELECT user_id FROM memberships")
        assert {str(r[0]) for r in await cur.fetchall()} == {ALICE, CAROL, DAVE}


async def test_a_bookkeeper_reads_its_org_and_writes_nothing(pool):
    """Isolates `location_select`.

    An owner or manager also passes `location_write`'s USING clause, which a
    FOR ALL policy applies to SELECT as well -- so for those two roles the
    read is served even if `location_select` is broken. A bookkeeper is the
    only role for which `location_select` is load-bearing on its own.
    """
    async with tenant_connection(pool, {"sub": DAVE}) as conn:
        cur = await conn.execute("SELECT id FROM locations")
        assert {str(r[0]) for r in await cur.fetchall()} == {ACME_LOC}
        cur = await conn.execute(
            "UPDATE locations SET name = 'nope' WHERE id = %s", (ACME_LOC,))
        assert cur.rowcount == 0, "a bookkeeper must not be able to write locations"
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": DAVE}) as conn:
            await conn.execute(
                "INSERT INTO locations (org_id, name) VALUES (%s, 'nope')", (ACME,))
    assert "row-level security" in str(exc.value).lower()


async def test_forged_claims_grant_nothing(pool):
    """The plan's rule: policies resolve through `memberships`, never a claim.

    Claims are client-derived. A caller who mints extra claims naming another
    org, or a higher role, must gain exactly nothing from them.
    """
    forged = {"sub": ALICE, "org_id": BISTRO, "role": "owner",
              "org_ids": [ACME, BISTRO], "orgs": [BISTRO]}
    async with tenant_connection(pool, forged) as conn:
        cur = await conn.execute("SELECT id FROM locations")
        assert {str(r[0]) for r in await cur.fetchall()} == {ACME_LOC}
        cur = await conn.execute("SELECT id FROM organizations")
        assert {str(r[0]) for r in await cur.fetchall()} == {ACME}
        cur = await conn.execute(
            "UPDATE locations SET name = 'pwned' WHERE id = %s", (BISTRO_LOC,))
        assert cur.rowcount == 0
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, forged) as conn:
            await conn.execute(
                "INSERT INTO locations (org_id, name) VALUES (%s, 'Trojan')", (BISTRO,))
    assert "row-level security" in str(exc.value).lower()


# --------------------------------------------------------------------------
# Writes. WITH CHECK is the clause under test.
# --------------------------------------------------------------------------
@pytest.mark.parametrize("sql, args", [
    ("INSERT INTO locations (org_id, name) VALUES (%s, 'Trojan')", (BISTRO,)),
    ("INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, 'owner')", (ALICE, BISTRO)),
    ("INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
     "VALUES (%s, 'x@x.test', 'owner', 'trojan', %s, now() + interval '1 day')", (BISTRO, ALICE)),
    ("INSERT INTO profiles (user_id, contact_email) VALUES (%s, 'x@x.test')",
     ("44444444-4444-7444-8444-444444444444",)),
    ("INSERT INTO email_verifications (user_id, token_hash, expires_at) "
     "VALUES (%s, 'trojan', now() + interval '1 day')", (BOB,)),
    ("INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at) "
     "VALUES (%s, 'trojan', now() + interval '1 day')", (BOB,)),
])
async def test_insert_into_another_tenant_is_refused(pool, sql, args):
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": ALICE}) as conn:
            await conn.execute(sql, args)
    assert "row-level security" in str(exc.value).lower(), str(exc.value)


@pytest.mark.parametrize("sql, args", [
    ("UPDATE locations SET name = 'pwned' WHERE id = %s", (BISTRO_LOC,)),
    ("UPDATE organizations SET name = 'pwned' WHERE id = %s", (BISTRO,)),
    ("UPDATE memberships SET role = 'owner' WHERE user_id = %s", (BOB,)),
    ("UPDATE profiles SET contact_email = 'pwned@x.test' WHERE user_id = %s", (BOB,)),
    ("DELETE FROM locations WHERE id = %s", (BISTRO_LOC,)),
    ("DELETE FROM memberships WHERE user_id = %s", (BOB,)),
    ("DELETE FROM invites WHERE org_id = %s", (BISTRO,)),
    ("DELETE FROM email_verifications WHERE user_id = %s", (BOB,)),
    ("DELETE FROM apple_link_requests WHERE apple_sub = %s", (BOB,)),
])
async def test_update_or_delete_of_another_tenants_row_touches_nothing(pool, sql, args):
    async with tenant_connection(pool, {"sub": ALICE}) as conn:
        cur = await conn.execute(sql, args)
        assert cur.rowcount == 0, f"TENANCY LEAK: {sql!r} touched {cur.rowcount} foreign rows"


@pytest.mark.parametrize("sql, args", [
    ("UPDATE locations   SET org_id = %s WHERE id = %s", (BISTRO, ACME_LOC)),
    ("UPDATE memberships SET org_id = %s WHERE user_id = %s", (BISTRO, ALICE)),
    ("UPDATE invites     SET org_id = %s WHERE org_id = %s", (BISTRO, ACME)),
])
async def test_a_row_cannot_be_moved_out_of_the_callers_org(pool, sql, args):
    """The only case where WITH CHECK is not a restatement of USING.

    For a FOR ALL policy PostgreSQL reuses USING as WITH CHECK when the latter
    is omitted, so most write tests pass either way. Not this one: USING sees
    the OLD row (in Acme, allowed) and WITH CHECK sees the NEW row (in Bistro).
    Drop WITH CHECK from a policy whose USING is wider and this is the hole.
    """
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": ALICE}) as conn:
            await conn.execute(sql, args)
    assert "row-level security" in str(exc.value).lower(), str(exc.value)


async def test_a_non_owner_cannot_rename_its_own_org(pool):
    """Isolates `org_update`'s role restriction.

    Cross-org UPDATEs on organizations are already stopped by `org_select`
    hiding the row, so they do not exercise `org_update` at all. A member of
    the org who is not an owner is the case that does.
    """
    for sub in (CAROL, DAVE):
        async with tenant_connection(pool, {"sub": sub}) as conn:
            cur = await conn.execute(
                "UPDATE organizations SET name = 'pwned' WHERE id = %s", (ACME,))
            assert cur.rowcount == 0, f"{sub} is not an owner but renamed the org"


async def test_a_valid_but_unknown_sub_sees_nothing(pool):
    async with tenant_connection(pool, {"sub": "99999999-9999-7999-8999-999999999999"}) as conn:
        for table in TENANT_TABLES:
            cur = await conn.execute(f"SELECT count(*) FROM {table}")
            assert (await cur.fetchone())[0] == 0, f"{table} visible to a non-member"


async def test_a_manager_cannot_change_memberships(pool):
    """Role separation, not just org separation: only owners write memberships."""
    async with tenant_connection(pool, {"sub": CAROL}) as conn:
        cur = await conn.execute(
            "UPDATE memberships SET role = 'owner' WHERE user_id = %s", (CAROL,))
        assert cur.rowcount == 0
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": CAROL}) as conn:
            await conn.execute(
                "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, 'owner')",
                ("44444444-4444-7444-8444-444444444444", ACME))
    assert "row-level security" in str(exc.value).lower()


async def test_the_owner_can_still_do_its_own_work(pool):
    """A policy set that denies everything would pass every test above."""
    async with tenant_connection(pool, {"sub": ALICE}) as conn:
        cur = await conn.execute(
            "INSERT INTO locations (org_id, name) VALUES (%s, 'Acme Second') RETURNING id", (ACME,))
        assert await cur.fetchone() is not None
        cur = await conn.execute(
            "UPDATE organizations SET name = 'Acme Renamed' WHERE id = %s", (ACME,))
        assert cur.rowcount == 1
        cur = await conn.execute(
            "UPDATE memberships SET role = 'bookkeeper' WHERE user_id = %s", (CAROL,))
        assert cur.rowcount == 1
        await conn.execute("ROLLBACK")


# --------------------------------------------------------------------------
# The one deliberate bypass. If `rls_definer` were reachable, or its policy
# wider than one SELECT, the whole scheme would be decoration.
# --------------------------------------------------------------------------
async def test_rls_definer_cannot_be_logged_into_or_escalated(raw_conn):
    await apply_migrations(raw_conn, upto=4)
    cur = await raw_conn.execute(
        "SELECT rolcanlogin, rolbypassrls, rolsuper, rolinherit "
        "FROM pg_roles WHERE rolname = 'rls_definer'")
    canlogin, bypass, super_, inherit = await cur.fetchone()
    assert canlogin is False, "rls_definer must not be a login role"
    assert bypass is False and super_ is False and inherit is False

    cur = await raw_conn.execute(
        "SELECT pg_has_role('app_user', 'rls_definer', 'MEMBER'), "
        "       pg_has_role('authenticated', 'rls_definer', 'MEMBER')")
    assert await cur.fetchone() == (False, False), \
        "the request-path roles must not be able to SET ROLE rls_definer"

    cur = await raw_conn.execute(
        "SELECT cmd, qual FROM pg_policies WHERE policyname = 'membership_definer_read'")
    (cmd, qual) = await cur.fetchone()
    assert cmd == "SELECT", "the definer bypass must be read-only"
    assert qual == "true", (
        "membership_definer_read must stay a permissive USING (true). Narrowing it to "
        "anything that reads memberships makes current_user_memberships() recurse into "
        f"itself at runtime -- 'stack depth limit exceeded'. Found: {qual!r}")

    cur = await raw_conn.execute(
        "SELECT count(*) FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner "
        "WHERE r.rolname = 'rls_definer'")
    assert (await cur.fetchone())[0] == 0, "rls_definer must own no table"


async def test_nothing_is_left_a_member_of_rls_definer(raw_conn):
    """The migration grants itself rls_definer to reassign ownership, then
    gives it back. If the REVOKE is ever dropped, FORCE is measurably softened:
    RLS role matching uses has_privs_of_role(), so `membership_definer_read`
    reaches any INHERIT member and a non-superuser migration runner reads every
    membership row unfiltered.

    Checked against pg_auth_members, not pg_has_role() -- the latter answers
    true for a superuser no matter what, so it cannot see this regression in a
    harness whose `postgres` is a superuser.
    """
    await apply_migrations(raw_conn, upto=4)
    cur = await raw_conn.execute(
        "SELECT g.rolname FROM pg_auth_members m "
        "JOIN pg_roles r ON r.oid = m.roleid "
        "JOIN pg_roles g ON g.oid = m.member "
        "WHERE r.rolname = 'rls_definer'")
    assert await cur.fetchall() == [], "rls_definer must be left with no members"


async def test_definer_read_policy_is_load_bearing(pool, raw_conn):
    """Mutation check: the bypass policy is what makes any of this work.

    Without it the lookup function reads zero rows and every policy silently
    denies -- which is the failure mode this whole file exists to catch, only
    inverted. Proves the test suite is sensitive to that policy at all.
    """
    await raw_conn.execute("DROP POLICY membership_definer_read ON memberships")
    await raw_conn.commit()
    try:
        async with tenant_connection(pool, {"sub": ALICE}) as conn:
            cur = await conn.execute("SELECT count(*) FROM locations")
            assert (await cur.fetchone())[0] == 0
    finally:
        await raw_conn.execute(
            "CREATE POLICY membership_definer_read ON memberships "
            "FOR SELECT TO rls_definer USING (true)")
        await raw_conn.commit()


async def test_application_policies_never_apply_to_the_definer_role(raw_conn):
    """If any policy reached rls_definer, the recursion would come back.

    A policy with no `TO` clause is `TO PUBLIC`, which includes rls_definer.
    """
    await apply_migrations(raw_conn, upto=4)
    cur = await raw_conn.execute(
        "SELECT tablename, policyname, roles FROM pg_policies "
        "WHERE schemaname = 'public' AND policyname <> 'membership_definer_read' "
        "ORDER BY tablename, policyname")
    for table, policy, roles in await cur.fetchall():
        assert roles == ["authenticated"], f"{table}.{policy} is scoped to {roles}"
