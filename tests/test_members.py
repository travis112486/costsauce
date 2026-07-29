# tests/test_members.py
import asyncio
import hashlib
import uuid
import pytest
from fastapi import HTTPException
from tests.conftest import apply_migrations, MIGRATIONS
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
    dave = await make_user(raw_conn, "dave@acme.example.com", contact_email_verified=True)
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
    await raw_conn.execute("UPDATE profiles SET contact_email = 'alice@acme.example.com', "
                            "contact_email_verified_at = now() WHERE user_id = %s",
                            (seeded["alice"],))
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
    dave = await make_user(raw_conn, "dave@acme.example.com", contact_email_verified=True)
    await raw_conn.commit()
    r = await app_client.post("/invites/accept", json={"token": token},
                               headers={"Authorization": f"Bearer {mint(str(dave))}"})
    assert r.status_code == 200


async def test_accept_invite_email_binding_requires_verification_not_just_a_self_set_match(
    app_client, raw_conn, seeded
):
    """Task 9 review round 2: matching on contact_email alone (round 1's
    fix) was defeated by one extra request -- an attacker holding a leaked
    token, refused on their first attempt, could POST
    /identity/contact-email to self-set an UNVERIFIED contact_email to the
    invite's target address and retry successfully. Reproduces the
    reviewer's exact live sequence and proves the retry still fails now
    that the binding requires contact_email_verified_at IS NOT NULL."""
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "victim@acme.example.com", "role": "owner"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    token = r.json()["token"]

    mallory = await make_user(raw_conn, "mallory@acme.example.com")
    await raw_conn.commit()
    mallory_headers = {"Authorization": f"Bearer {mint(str(mallory))}"}

    # 1. mallory's own attempt -- binding correctly refuses the mismatch.
    r = await app_client.post("/invites/accept", json={"token": token}, headers=mallory_headers)
    assert r.status_code == 400

    # 2. mallory self-sets contact_email to the invite's target address.
    # This succeeds (set_contact_email has no ownership proof beyond what
    # this finding requires -- explicitly out of scope, see report) but
    # leaves contact_email_verified_at NULL.
    r = await app_client.post(
        "/identity/contact-email", json={"email": "victim@acme.example.com"},
        headers=mallory_headers,
    )
    assert r.status_code == 200

    # 3. Retrying with the SAME token must still fail: an unverified
    # self-set address must not satisfy the binding.
    r = await app_client.post("/invites/accept", json={"token": token}, headers=mallory_headers)
    assert r.status_code == 400, (
        "an unverified, self-set contact_email must not be sufficient to accept "
        "someone else's invite"
    )


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
    dave = await make_user(raw_conn, "dave@acme.example.com", contact_email_verified=True)
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
    dave = await make_user(raw_conn, "dave@acme.example.com", contact_email_verified=True)
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
    mallory = await make_user(raw_conn, "mallory@bistro.example.com", contact_email_verified=True)
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


# Critical-2 round 2: the round-1 concurrency tests above only ever drove
# the Python `_lock_org` (change_role/remove_member/create_invite), where
# the org-row lock genuinely worked -- neither exercised accept_invite_tx's
# OWN lock, which review round 2 found was silently a no-op (RLS filtered
# `invite_definer`'s FOR-UPDATE row out entirely, since it only had a
# SELECT policy on organizations, not an UPDATE one -- `FOR UPDATE` fails
# OPEN). This reproduces the reviewer's exact live sequence: two owners, a
# pending lower-role invite addressed to one of them; remove_member(the
# OTHER owner) holds the org lock uncommitted while accept_invite (via the
# real HTTP endpoint, exercising the real accept_invite_tx) runs
# concurrently. It must genuinely block, and once unblocked, must correctly
# refuse to leave the org with zero owners.

async def test_concurrent_accept_invite_and_remove_member_cannot_zero_out_owners(
    pool, app_client, raw_conn, seeded
):
    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.execute(
        "UPDATE profiles SET contact_email = 'alice@acme.example.com', "
        "contact_email_verified_at = now() WHERE user_id = %s",
        (seeded["alice"],),
    )
    await raw_conn.commit()
    alice_headers = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}

    r = await app_client.post(f"/orgs/{seeded['acme']}/invites",
                               json={"email": "alice@acme.example.com", "role": "manager"},
                               headers=alice_headers)
    assert r.status_code == 200
    token = r.json()["token"]

    org_id = str(seeded["acme"])
    lock_acquired = asyncio.Event()
    proceed = asyncio.Event()

    async def hold_remove_lock():
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            await members_module._require_owner(conn, str(seeded["alice"]), org_id)
            await members_module._lock_org(conn, org_id)
            lock_acquired.set()
            await proceed.wait()
            cur = await conn.execute(
                "SELECT role FROM memberships WHERE org_id = %s AND user_id = %s",
                (org_id, boss),
            )
            (role,) = await cur.fetchone()
            if role == "owner" and await members_module._owner_count(conn, org_id) == 1:
                return "refused"
            await conn.execute(
                "DELETE FROM memberships WHERE org_id = %s AND user_id = %s", (org_id, boss)
            )
            return "removed"

    async def accept_via_http():
        return await app_client.post(
            "/invites/accept", json={"token": token}, headers=alice_headers
        )

    async def racer():
        await lock_acquired.wait()
        task = asyncio.create_task(accept_via_http())
        await asyncio.sleep(0.3)
        # If accept_invite_tx's lock were the round-1-broken row lock (or
        # any lock not sharing this key space with _lock_org), this call
        # would have no reason to still be running here.
        assert not task.done(), "accept_invite_tx must block on the same org lock too"
        proceed.set()
        return await task

    remove_result, accept_response = await asyncio.gather(hold_remove_lock(), racer())
    assert remove_result == "removed"
    assert accept_response.status_code == 409
    assert "last owner" in str(accept_response.json()).lower()

    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'",
        (seeded["acme"],),
    )
    (n,) = await cur.fetchone()
    assert n == 1, "org must be left with exactly one owner, never zero"


# New Important (introduced by the round-1 fix diff): CREATE OR REPLACE
# FUNCTION accept_invite_tx(p_token_hash text) does NOT touch a
# pre-existing accept_invite_tx(text, uuid) -- a different parameter list is
# a genuinely different function to Postgres, not a replacement. Simulates
# the reviewer's exact scenario: a database that already had the pre-fix
# 2-arg signature applied, before this migration's current content
# (including its explicit DROP) runs on top of it.

async def test_accept_invite_tx_has_no_orphaned_two_arg_overload(raw_conn):
    await apply_migrations(raw_conn, upto=5)
    await raw_conn.execute(
        "CREATE FUNCTION accept_invite_tx(p_token_hash text, p_user_id uuid) "
        "RETURNS TABLE(status text, out_org_id uuid, out_role text) "
        "LANGUAGE sql AS $$ SELECT 'stale'::text, NULL::uuid, NULL::text $$"
    )
    await raw_conn.commit()
    # NOT apply_migrations(upto=6) again -- that would re-run 0001-0005 from
    # scratch (it has no "already applied" tracking) and fail on the
    # non-idempotent CREATE TABLEs. Only 0006's own content simulates
    # "the current migration runs on top of an already-migrated database".
    migration_0006 = sorted(MIGRATIONS.glob("0006_*.sql"))[0]
    await raw_conn.execute(migration_0006.read_text())
    await raw_conn.commit()

    cur = await raw_conn.execute(
        "SELECT pg_get_function_identity_arguments(oid) FROM pg_proc "
        "WHERE proname = 'accept_invite_tx'"
    )
    signatures = [row[0] for row in await cur.fetchall()]
    assert signatures == ["p_token_hash text"], (
        f"expected exactly the 1-arg overload after the migration's DROP, found: {signatures}"
    )


# Critical-2, round 3 (a THIRD distinct cause, introduced by round 2's own
# advisory-lock fix): hashtextextended hashes whatever TEXT it is given, and
# different valid spellings of the identical uuid ("...", "...".upper(), no
# hyphens, braces) hash to DIFFERENT keys, even though every spelling
# resolves to the same row everywhere else in this file (a `uuid` column
# comparison normalizes case/format; a hash of the raw client-supplied
# string does not). Round 1's row lock (`WHERE id = %s FOR UPDATE` against
# a `uuid` column) never had this problem; switching to an advisory lock on
# raw text is what introduced it. Fixed at the boundary: every route in
# this file now types org_id/user_id path parameters as `uuid.UUID`, so
# FastAPI/Pydantic normalizes every spelling to the identical object before
# any handler runs.
#
# This proves the fix end-to-end: one side is a real HTTP request through
# the actual (now uuid.UUID-typed) route, deliberately spelled with a
# DIFFERENT case than the other side. `uuid.UUID(spelling)` is used to
# derive the "held" side's key -- exactly what FastAPI/Pydantic does
# internally to a path parameter, not a reimplementation of the fix.

# Final-review Important-5, promoted from Task 9's deferred minors. The
# version of this test that shipped drove `remove_member` ONLY. Reverting
# just `change_role`'s `uuid.UUID` typing left the whole suite green while a
# probe yielded 8/12 zero-owner via concurrent `PATCH`es spelled with
# differing URL case: two of the three org-locking routes carried no
# regression guard at all for the exact cause that took three rounds to find,
# on an invariant that has already regenerated three times.
#
# So it is parametrised over every route in this file that reaches
# `_lock_org` -- `remove_member` and `change_role` directly, `create_invite`
# through `_check_member_limit`. The load-bearing assertion is the same for
# all three and is what a reverted `uuid.UUID` annotation breaks: a request
# whose URL spells the org id differently must STILL block on the lock held
# under the canonical spelling. The per-route status and the surviving owner
# count are asserted after, so a route that blocks correctly but then decides
# wrongly is still caught.
@pytest.mark.parametrize("route", ["remove_member", "change_role", "create_invite"])
async def test_every_org_locking_route_normalizes_uuid_spelling_before_locking(
    pool, app_client, raw_conn, seeded, route
):
    # Each side acts on ITSELF, with its OWN JWT -- not one side acting on the
    # other. (An earlier draft of this test had alice's request remove boss
    # while alice's own membership was concurrently deleted by the other
    # side: once alice's own row was gone, RLS's membership_select policy
    # correctly hid boss's row from her too -- current_user_memberships()
    # has nothing to return for a caller who is no longer a member of
    # anything, so EVERY row in that org becomes invisible to her, not just
    # her own. That is correct RLS behavior, not the bug under test, and it
    # produced a misleading 404. Self-action on both sides avoids it.)
    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    # `create_invite` is gated by _check_member_limit before it ever reaches
    # the lock-sensitive work; `starter` caps max_members at 1, which would
    # 402 this org before the race is interesting. The plan is irrelevant to
    # what is under test, so lift it out of the way.
    await raw_conn.execute("UPDATE organizations SET plan = 'pro' WHERE id = %s",
                           (seeded["acme"],))
    await raw_conn.commit()

    org_id_canonical = uuid.UUID(str(seeded["acme"]))
    org_id_uppercase_url = str(seeded["acme"]).upper()
    assert org_id_uppercase_url != str(org_id_canonical), "fixture value must not already be upper"

    boss_auth = {"Authorization": f"Bearer {mint(str(boss))}"}
    # Every request is spelled UPPERCASE in the URL -- a different, equally
    # valid spelling of the same uuid as `org_id_canonical` above, which is
    # what the holder locks under.
    requests = {
        "remove_member": lambda: app_client.delete(
            f"/orgs/{org_id_uppercase_url}/members/{boss}", headers=boss_auth,
        ),
        "change_role": lambda: app_client.patch(
            f"/orgs/{org_id_uppercase_url}/members/{boss}",
            json={"role": "manager"}, headers=boss_auth,
        ),
        "create_invite": lambda: app_client.post(
            f"/orgs/{org_id_uppercase_url}/invites",
            json={"email": "invitee@acme-diner.example.com", "role": "manager"},
            headers=boss_auth,
        ),
    }
    # remove_member: boss removing himself is the last owner -> refused.
    # change_role:   boss demoting himself is the last owner -> refused.
    # create_invite: nothing about the last owner; it must simply succeed,
    #                having correctly waited its turn on the lock.
    expected_status = {"remove_member": 409, "change_role": 409, "create_invite": 200}[route]

    lock_acquired = asyncio.Event()
    proceed = asyncio.Event()

    async def hold_lock_removing_alice():
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            await members_module._require_owner(conn, str(seeded["alice"]), org_id_canonical)
            await members_module._lock_org(conn, org_id_canonical)
            lock_acquired.set()
            await proceed.wait()
            cur = await conn.execute(
                "SELECT role FROM memberships WHERE org_id = %s AND user_id = %s",
                (org_id_canonical, seeded["alice"]),
            )
            (role,) = await cur.fetchone()
            if role == "owner" and await members_module._owner_count(conn, org_id_canonical) == 1:
                return "refused"
            await conn.execute(
                "DELETE FROM memberships WHERE org_id = %s AND user_id = %s",
                (org_id_canonical, seeded["alice"]),
            )
            return "removed"

    async def racer():
        await lock_acquired.wait()
        task = asyncio.create_task(requests[route]())
        await asyncio.sleep(0.3)
        assert not task.done(), (
            f"{route}: a request spelled with a different (but equal) uuid case "
            "must still block on the SAME org lock"
        )
        proceed.set()
        return await task

    alice_result, boss_response = await asyncio.gather(hold_lock_removing_alice(), racer())
    assert alice_result == "removed"
    assert boss_response.status_code == expected_status, (
        f"{route}: {boss_response.status_code} {boss_response.text!r}"
    )
    if expected_status == 409:
        assert "last owner" in str(boss_response.json()).lower()

    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'",
        (seeded["acme"],),
    )
    (n,) = await cur.fetchone()
    assert n == 1, "org must be left with exactly one owner, never zero, regardless of URL spelling"

    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'",
        (seeded["acme"],),
    )
    (n,) = await cur.fetchone()
    assert n == 1, "org must be left with exactly one owner, never zero, regardless of URL spelling"


async def test_malformed_org_id_in_path_is_422_not_500(app_client, seeded):
    """The uuid.UUID path typing that fixes the spelling-divergence race
    above also closes this deferred minor as a side effect: a malformed id
    now fails FastAPI/Pydantic validation before any handler runs, instead
    of reaching Postgres and 500ing."""
    r = await app_client.post(
        "/orgs/not-a-uuid/invites",
        json={"email": "dave@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 422


# Minor (Task 9 review round 2): tests/conftest.py's app_client fixture sets
# RETURN_INVITE_TOKEN_ENABLED=1 for every test so the rest of this file can
# drive the accept_invite round trip, but nothing asserted the default
# itself -- reverting the gate to an unconditional echo would break zero
# tests. The gate itself is correct; this closes the missing coverage.

async def test_create_invite_does_not_echo_token_without_the_enable_flag(
    app_client, monkeypatch, raw_conn, seeded
):
    monkeypatch.delenv("RETURN_INVITE_TOKEN_ENABLED", raising=False)
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                            (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    assert "token" not in r.json(), "token must not be echoed when the flag is unset"
    assert "invite_id" in r.json()


# --- Task 1 (Phase 2a): GET /orgs/{org_id}/members -------------------------
#
# The iOS client needs a member roster; none existed before (this file had
# invite/accept/patch/delete only, and /me shows only the caller's own
# memberships). Auth is deliberately "any member", not owner-only: RLS's
# membership_select policy (supabase/migrations/0004_rls_policies.sql:192)
# already grants org-wide membership visibility to every member, and the
# query mirrors the export's members join exactly
# (api/services/export.py:100-101). Under RLS profile_self
# (0004_rls_policies.sql:225-226), a joined profiles row is only visible for
# the caller's own user_id, so contact_email comes back non-null only for
# the caller's own row and null for every other member's row.

async def test_owner_lists_roster_with_own_contact_email_and_roles(
    app_client, raw_conn, seeded
):
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, seeded["acme"], "bookkeeper")
    await raw_conn.commit()
    r = await app_client.get(
        f"/orgs/{seeded['acme']}/members",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body) == 2
    alice_row = next(m for m in body if m["user_id"] == str(seeded["alice"]))
    assert alice_row["role"] == "owner"
    assert alice_row["contact_email"] == "alice@acme.test"
    carol_row = next(m for m in body if m["user_id"] == str(carol))
    assert carol_row["role"] == "bookkeeper"
    assert carol_row["contact_email"] is None, (
        "RLS profile_self must hide another member's contact_email from the caller"
    )


async def test_bookkeeper_member_can_also_list_roster(app_client, raw_conn, seeded):
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, seeded["acme"], "bookkeeper")
    await raw_conn.commit()
    r = await app_client.get(
        f"/orgs/{seeded['acme']}/members",
        headers={"Authorization": f"Bearer {mint(str(carol))}"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body) == 2
    carol_row = next(m for m in body if m["user_id"] == str(carol))
    assert carol_row["contact_email"] == "carol@acme.test"
    alice_row = next(m for m in body if m["user_id"] == str(seeded["alice"]))
    assert alice_row["contact_email"] is None


async def test_non_member_cannot_list_roster(app_client, seeded):
    r = await app_client.get(
        f"/orgs/{seeded['acme']}/members",
        headers={"Authorization": f"Bearer {mint(str(seeded['bob']))}"},
    )
    assert r.status_code == 404


async def test_list_roster_unknown_org_is_404(app_client, seeded):
    r = await app_client.get(
        "/orgs/00000000-0000-0000-0000-000000000000/members",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 404


async def test_list_roster_unauthenticated_is_401(app_client, seeded):
    r = await app_client.get(f"/orgs/{seeded['acme']}/members")
    assert r.status_code == 401


async def test_list_roster_ordering_stable_across_two_calls(app_client, raw_conn, seeded):
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, seeded["acme"], "bookkeeper")
    dave = await make_user(raw_conn, "dave@acme.test")
    await add_member(raw_conn, dave, seeded["acme"], "manager")
    await raw_conn.commit()
    headers = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    r1 = await app_client.get(f"/orgs/{seeded['acme']}/members", headers=headers)
    r2 = await app_client.get(f"/orgs/{seeded['acme']}/members", headers=headers)
    assert r1.status_code == 200, r1.text
    assert r2.status_code == 200, r2.text
    ids1 = [m["user_id"] for m in r1.json()]
    ids2 = [m["user_id"] for m in r2.json()]
    assert len(ids1) == 3
    assert ids1 == ids2, "ordering (created_at, user_id) must be stable across repeat calls"
