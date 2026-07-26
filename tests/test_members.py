# tests/test_members.py
import asyncio
import hashlib
import pytest
from fastapi import HTTPException
from tests.test_auth import mint
from tests.factories import make_user, add_member
from api.db import pool_open, tenant_connection
from api.routes import members as members_module


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def pool(db_url, seeded):
    """A second, direct app_user connection pool -- same credentials
    app_client uses, but not routed through HTTP, so the concurrency tests
    below can hold one transaction open at a precise, controlled point while
    a second transaction runs concurrently against the same seeded data.
    Mirrors tests/test_rls_policies.py's identical fixture.
    """
    p = await pool_open(app_url(db_url))
    try:
        yield p
    finally:
        await p.close()


async def test_non_owner_cannot_invite(app_client, raw_conn, seeded):
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(carol))}"},
    )
    assert r.status_code == 403


async def test_owner_can_invite_and_invitee_joins(app_client, raw_conn, seeded):
    # seeded's "acme" org defaults to the starter plan (max_members=1) and
    # already has one member (alice, owner) -- i.e. it starts AT its plan
    # limit. Task 9's own max_members addition refuses a further invite at
    # the limit (by design -- see test_invite_refused_when_org_at_member_limit
    # below), so this test bumps Acme to the growth plan (max_members=3)
    # first. Without this bump, the brief's own scenario (owner invites,
    # invitee joins) would now correctly 402 under the new enforcement --
    # that's the enforcement working, not a bug in this test.
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "bookkeeper"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    token = r.json()["token"]
    # Important-3 fix (Task 9 review round 1): acceptance is now bound to the
    # caller's own profiles.contact_email matching the invite's email, so
    # dave's profile must carry the SAME address the invite was created for.
    dave = await make_user(raw_conn, "dave@acme.example.com")
    await raw_conn.commit()
    r2 = await app_client.post("/invites/accept", json={"token": token},
                               headers={"Authorization": f"Bearer {mint(str(dave))}"})
    assert r2.status_code == 200
    me = await app_client.get("/me", headers={"Authorization": f"Bearer {mint(str(dave))}"})
    assert me.json()["memberships"][0]["role"] == "bookkeeper"


async def test_owner_of_org_a_cannot_invite_into_org_b(app_client, seeded):
    r = await app_client.post(
        f"/orgs/{seeded['bistro']}/invites",
        json={"email": "x@y.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 403


async def test_last_owner_cannot_be_demoted(app_client, seeded):
    r = await app_client.patch(
        f"/orgs/{seeded['acme']}/members/{seeded['alice']}",
        json={"role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 409
    assert "last owner" in str(r.json()).lower()


async def test_last_owner_cannot_be_removed(app_client, seeded):
    r = await app_client.delete(
        f"/orgs/{seeded['acme']}/members/{seeded['alice']}",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 409


# --- max_members enforcement (Task 9 addition; not in the original brief) --
#
# PLAN_LIMITS defines max_members (starter=1, growth=3, pro=10) but nothing
# enforced it before this task. Enforcement happens at invite-creation time:
# existing memberships PLUS pending (unaccepted, unexpired) invites must stay
# under the plan's max_members, or the invite is refused before it is ever
# created.

async def test_invite_refused_when_org_at_member_limit(app_client, seeded):
    # seeded's "acme" is starter (max_members=1) with exactly one member
    # (alice, owner) already -- i.e. it starts AT its limit.
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 402
    body = str(r.json()).lower()
    assert "starter" in body
    assert "1" in body


async def test_invite_allowed_when_org_below_member_limit(app_client, raw_conn, seeded):
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200


async def test_pending_invites_count_toward_member_limit(app_client, raw_conn, seeded):
    # growth = max_members 3. Acme starts with 1 member (alice). Two pending
    # invites bring the count to 3 (1 member + 2 pending) without a single
    # extra ACCEPTED member -- proving the limit counts pending invites, not
    # just accepted memberships. Counting only accepted members would let an
    # owner send far more invites than the plan allows in one sitting.
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    headers = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}

    r1 = await app_client.post(f"/orgs/{seeded['acme']}/invites",
                                json={"email": "dave@acme.example.com", "role": "manager"},
                                headers=headers)
    assert r1.status_code == 200

    r2 = await app_client.post(f"/orgs/{seeded['acme']}/invites",
                                json={"email": "erin@acme.example.com", "role": "manager"},
                                headers=headers)
    assert r2.status_code == 200

    # Third invite would push (1 member + 3 pending) past growth's limit of 3.
    r3 = await app_client.post(f"/orgs/{seeded['acme']}/invites",
                                json={"email": "frank@acme.example.com", "role": "manager"},
                                headers=headers)
    assert r3.status_code == 402
    body = str(r3.json()).lower()
    assert "growth" in body


# --- last-owner protection must hold through accept_invite too ------------
#
# change_role and remove_member both refuse to leave an org with zero
# owners. accept_invite is a THIRD path that writes memberships.role (via
# `ON CONFLICT DO UPDATE`) and, unguarded, could demote an existing owner
# down to whatever role a stale invite carries -- silently leaving the org
# with zero owners with no check at all. Found in Task 9 self-review; fixed
# in migration 0006's accept_invite_tx (same last-owner invariant as
# change_role/remove_member).

async def test_accept_invite_cannot_demote_the_last_owner(app_client, raw_conn, seeded):
    from tests.factories import make_user

    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    # Important-3 fix (Task 9 review round 1): acceptance is bound to the
    # caller's own profiles.contact_email matching the invite's email. Alice
    # is going to accept this invite herself, so it must be addressed to her
    # own contact_email. Seeded alice's address is "alice@acme.test", which
    # EmailStr rejects on the request body (SPECIAL_USE_DOMAIN_NAMES), so her
    # profile's contact_email is bumped to a real domain here -- this changes
    # neither her identity (JWT `sub`) nor her auth.users row, only the
    # address this one test's invite is addressed to and matched against.
    await raw_conn.execute("UPDATE profiles SET contact_email = 'alice@acme.example.com' "
                            "WHERE user_id = %s", (seeded["alice"],))
    await raw_conn.commit()
    alice_headers = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}

    # While there are two owners, create an invite for a lower role,
    # addressed to alice's own (bumped) contact_email.
    r = await app_client.post(f"/orgs/{seeded['acme']}/invites",
                               json={"email": "alice@acme.example.com", "role": "manager"},
                               headers=alice_headers)
    assert r.status_code == 200
    token = r.json()["token"]

    # Remove the second owner -- permitted, since two owners remain at the
    # time of removal -- leaving alice as the sole owner.
    r = await app_client.delete(f"/orgs/{seeded['acme']}/members/{boss}",
                                 headers=alice_headers)
    assert r.status_code == 200

    # Alice, now the LAST owner, holds a valid, unexpired token for a
    # lower-role invite. Accepting it must not demote her.
    r = await app_client.post("/invites/accept", json={"token": token}, headers=alice_headers)
    assert r.status_code == 409
    assert "last owner" in str(r.json()).lower()

    me = await app_client.get("/me", headers=alice_headers)
    acme_membership = next(m for m in me.json()["memberships"] if m["org_id"] == str(seeded["acme"]))
    assert acme_membership["role"] == "owner", "alice must still be owner after the refused accept"


# --- self-review: privilege checks through the real HTTP path -------------
#
# create_invite's non-owner/cross-org 403s are covered above. change_role and
# remove_member share the same _require_owner helper but are not otherwise
# exercised against a non-owner or a cross-org caller -- verified directly
# rather than assumed from shared code.

async def test_non_owner_cannot_change_role(app_client, raw_conn, seeded):
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()
    r = await app_client.patch(
        f"/orgs/{seeded['acme']}/members/{seeded['alice']}",
        json={"role": "bookkeeper"},
        headers={"Authorization": f"Bearer {mint(str(carol))}"},
    )
    assert r.status_code == 403


async def test_non_owner_cannot_remove_member(app_client, raw_conn, seeded):
    carol = await make_user(raw_conn, "carol@acme.test")
    dave = await make_user(raw_conn, "dave@acme.test")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await add_member(raw_conn, dave, seeded["acme"], "bookkeeper")
    await raw_conn.commit()
    r = await app_client.delete(
        f"/orgs/{seeded['acme']}/members/{dave}",
        headers={"Authorization": f"Bearer {mint(str(carol))}"},
    )
    assert r.status_code == 403


async def test_bookkeeper_cannot_self_promote_to_owner(app_client, raw_conn, seeded):
    dave = await make_user(raw_conn, "dave@acme.test")
    await add_member(raw_conn, dave, seeded["acme"], "bookkeeper")
    await raw_conn.commit()
    r = await app_client.patch(
        f"/orgs/{seeded['acme']}/members/{dave}",
        json={"role": "owner"},
        headers={"Authorization": f"Bearer {mint(str(dave))}"},
    )
    assert r.status_code == 403


async def test_owner_of_org_a_cannot_change_role_in_org_b(app_client, raw_conn, seeded):
    carol = await make_user(raw_conn, "carol@bistro.test")
    await add_member(raw_conn, carol, seeded["bistro"], "manager")
    await raw_conn.commit()
    r = await app_client.patch(
        f"/orgs/{seeded['bistro']}/members/{carol}",
        json={"role": "owner"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 403


async def test_owner_of_org_a_cannot_remove_member_in_org_b(app_client, seeded):
    r = await app_client.delete(
        f"/orgs/{seeded['bistro']}/members/{seeded['bob']}",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 403


async def test_change_role_on_a_non_member_is_404_not_a_silent_success(app_client, raw_conn, seeded):
    """Found in self-review: without a rowcount check, PATCHing a user_id
    that is not a member of this org updates zero rows and still returns
    200 {"role": ...} -- a false success (same class of bug Task 7 review
    caught in set_contact_email)."""
    stranger = await make_user(raw_conn, "stranger@acme.example.com")
    await raw_conn.commit()
    r = await app_client.patch(
        f"/orgs/{seeded['acme']}/members/{stranger}",
        json={"role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 404


# --- Task 9 review round 1 fixes -------------------------------------------
#
# Important-3: invites were an unbound bearer token -- token possession alone
# was sufficient to accept, regardless of who the invite's `email` named.
# Acceptance is now bound to the caller's own profiles.contact_email
# (migration 0006's accept_invite_tx). Verified both that a mismatched caller
# is refused AND that the token survives the refusal for the real invitee.

async def test_accept_invite_refuses_a_caller_whose_email_does_not_match(app_client, raw_conn, seeded):
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    token = r.json()["token"]

    # mallory's profile carries a DIFFERENT contact_email than the invite.
    mallory = await make_user(raw_conn, "mallory@acme.example.com")
    await raw_conn.commit()
    r = await app_client.post("/invites/accept", json={"token": token},
                               headers={"Authorization": f"Bearer {mint(str(mallory))}"})
    assert r.status_code == 400

    # The token must still be usable by the actual invitee: a wrong-email
    # attempt must not have consumed it.
    dave = await make_user(raw_conn, "dave@acme.example.com")
    await raw_conn.commit()
    r = await app_client.post("/invites/accept", json={"token": token},
                               headers={"Authorization": f"Bearer {mint(str(dave))}"})
    assert r.status_code == 200


# Important-5: accept_invite's failure branches (invalid, expired, replayed
# token) had no coverage at all.

async def test_accept_invite_with_unknown_token_is_400(app_client, seeded):
    r = await app_client.post(
        "/invites/accept", json={"token": "not-a-real-token"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 400


async def test_accept_invite_with_expired_token_is_400(app_client, raw_conn, seeded):
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    token = r.json()["token"]
    dave = await make_user(raw_conn, "dave@acme.example.com")
    await raw_conn.execute(
        "UPDATE invites SET expires_at = now() - interval '1 hour' "
        "WHERE token_hash = %s",
        (hashlib.sha256(token.encode()).hexdigest(),),
    )
    await raw_conn.commit()
    r = await app_client.post("/invites/accept", json={"token": token},
                               headers={"Authorization": f"Bearer {mint(str(dave))}"})
    assert r.status_code == 400


async def test_accept_invite_replay_is_400(app_client, raw_conn, seeded):
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    token = r.json()["token"]
    dave = await make_user(raw_conn, "dave@acme.example.com")
    await raw_conn.commit()
    headers = {"Authorization": f"Bearer {mint(str(dave))}"}
    r1 = await app_client.post("/invites/accept", json={"token": token}, headers=headers)
    assert r1.status_code == 200
    r2 = await app_client.post("/invites/accept", json={"token": token}, headers=headers)
    assert r2.status_code == 400


# Critical-2 / Important-4: the last-owner check and the max_members check
# were both unlocked reads, vulnerable to write skew between two concurrent
# requests. A first attempt at these tests fired two real concurrent HTTP
# requests via asyncio.gather and relied on natural scheduling to interleave
# them -- that version passed EVEN WITH THE LOCKS DELETED (confirmed by
# mutation), because httpx's ASGITransport / this harness's DB round-trips
# don't reliably interleave without being forced to. A test that passes
# whether or not the fix exists proves nothing, so these were rewritten to
# force the interleaving deterministically: two REAL connections opened via
# `tenant_connection` (the same helper every request uses), calling the
# ACTUAL shared production functions (`api.routes.members._require_owner`,
# `_lock_org`, `_owner_count`, `_check_member_limit`) rather than
# reimplementing their SQL, with an `asyncio.Event` pausing the first
# transaction immediately after it acquires the org lock so the second is
# provably still blocked on it before either can commit.
#
# Trade-off, stated plainly: because these call the shared helpers directly
# instead of going through the HTTP endpoints, a future regression that
# stops `remove_member`/`create_invite` from CALLING `_lock_org` at all
# would not be caught here -- only a regression in what `_lock_org` itself
# does would be. That is the same shared function all three real call sites
# use, so this is still real coverage of the actual locking mechanism, not a
# reimplementation of it.

async def test_concurrent_removals_cannot_zero_out_owners(pool, raw_conn, seeded):
    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.commit()
    org_id = str(seeded["acme"])

    lock_acquired = asyncio.Event()
    proceed = asyncio.Event()

    async def do_remove(conn, target_user_id, pause_after_lock):
        await members_module._require_owner(conn, str(target_user_id), org_id)
        await members_module._lock_org(conn, org_id)
        if pause_after_lock:
            lock_acquired.set()
            await proceed.wait()
        cur = await conn.execute(
            "SELECT role FROM memberships WHERE org_id = %s AND user_id = %s",
            (org_id, target_user_id),
        )
        (role,) = await cur.fetchone()
        if role == "owner" and await members_module._owner_count(conn, org_id) == 1:
            return "refused"
        await conn.execute(
            "DELETE FROM memberships WHERE org_id = %s AND user_id = %s",
            (org_id, target_user_id),
        )
        return "removed"

    async def first():
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            return await do_remove(conn, seeded["alice"], pause_after_lock=True)

    async def second_inner():
        async with tenant_connection(pool, {"sub": str(boss)}) as conn:
            return await do_remove(conn, boss, pause_after_lock=False)

    async def second():
        await lock_acquired.wait()
        task = asyncio.create_task(second_inner())
        await asyncio.sleep(0.3)
        # If _lock_org did not truly hold a lock, this second call would
        # have no reason to still be running -- it would already have read
        # a stale owner_count of 2 and returned. Still pending here IS the
        # proof the lock is blocking it.
        assert not task.done(), "second removal must block on the org row lock"
        proceed.set()
        return await task

    first_result, second_result = await asyncio.gather(first(), second())
    assert first_result == "removed"
    assert second_result == "refused"

    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'",
        (seeded["acme"],),
    )
    (n,) = await cur.fetchone()
    assert n == 1, "org must be left with exactly one owner, never zero"


async def test_concurrent_invites_cannot_exceed_member_limit(pool, raw_conn, seeded):
    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    org_id = str(seeded["acme"])
    # growth max_members=3, acme now has 2 members (alice, boss) -- exactly
    # one slot remains. Two concurrent invites must not both take it.

    lock_acquired = asyncio.Event()
    proceed = asyncio.Event()

    async def do_invite(conn, email, pause_after_lock):
        await members_module._lock_org(conn, org_id)
        if pause_after_lock:
            lock_acquired.set()
            await proceed.wait()
        try:
            # Re-acquiring an already-self-held lock is a harmless no-op;
            # this calls the REAL, unmodified production function.
            await members_module._check_member_limit(conn, org_id)
        except HTTPException:
            return "refused"
        await conn.execute(
            "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
            "VALUES (%s, %s, 'manager', %s, %s, now() + interval '7 days')",
            (org_id, email, hashlib.sha256(email.encode()).hexdigest(), seeded["alice"]),
        )
        return "created"

    async def first():
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            return await do_invite(conn, "first@acme.example.com", pause_after_lock=True)

    async def second_inner():
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            return await do_invite(conn, "second@acme.example.com", pause_after_lock=False)

    async def second():
        await lock_acquired.wait()
        task = asyncio.create_task(second_inner())
        await asyncio.sleep(0.3)
        assert not task.done(), "second invite must block on the org row lock"
        proceed.set()
        return await task

    first_result, second_result = await asyncio.gather(first(), second())
    assert {first_result, second_result} == {"created", "refused"}, \
        "exactly one of the two concurrent invites must succeed"


# Critical-1: `SET search_path = pg_catalog, public` (no `pg_temp`) let an
# authenticated session shadow public.invites with a same-named TEMP table
# it owns, granted to invite_definer -- accept_invite_tx's bare `invites`
# reference then resolved to the forged table instead of the real one.
# Reproduces the reviewer's exploit shape directly against the fixed
# migration (search_path now lists pg_temp explicitly LAST, and every
# reference inside the function is schema-qualified with `public.`).

async def test_accept_invite_tx_is_not_shadowable_by_a_forged_temp_table(pool, raw_conn, seeded):
    mallory = await make_user(raw_conn, "mallory@bistro.example.com")
    await raw_conn.commit()

    async with tenant_connection(pool, {"sub": str(mallory)}) as conn:
        await conn.execute(
            "CREATE TEMP TABLE invites ("
            "  org_id uuid NOT NULL, email text NOT NULL, role text NOT NULL,"
            "  token_hash text NOT NULL, expires_at timestamptz NOT NULL,"
            "  accepted_at timestamptz)"
        )
        await conn.execute("GRANT ALL ON invites TO invite_definer")
        await conn.execute(
            "INSERT INTO invites (org_id, email, role, token_hash, expires_at) "
            "VALUES (%s, 'mallory@bistro.example.com', 'owner', 'forged-token', "
            "now() + interval '1 day')",
            (seeded["bistro"],),
        )
        cur = await conn.execute(
            "SELECT status, out_org_id, out_role FROM accept_invite_tx('forged-token')"
        )
        status, org_id, role = await cur.fetchone()

    assert status == "invalid", (
        f"forged temp-table row was accepted (status={status!r}); "
        "accept_invite_tx resolved 'invites' to the shadow table, not public.invites"
    )

    cur = await raw_conn.execute(
        "SELECT 1 FROM memberships WHERE org_id = %s AND user_id = %s",
        (seeded["bistro"], mallory),
    )
    assert await cur.fetchone() is None, \
        "mallory must not have gained a forged 'owner' membership in bistro"
