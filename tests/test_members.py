# tests/test_members.py
from tests.test_auth import mint
from tests.factories import make_user, add_member


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
    dave = await make_user(raw_conn, "dave@acme.test")
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
    await raw_conn.commit()
    alice_headers = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}

    # While there are two owners, create an invite for a lower role.
    r = await app_client.post(f"/orgs/{seeded['acme']}/invites",
                               json={"email": "whoever@acme.example.com", "role": "manager"},
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
