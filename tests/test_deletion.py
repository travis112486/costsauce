# tests/test_deletion.py
"""Account deletion, organization deletion, and the pre-write deletion guard.

The second non-negotiable gate of this phase (App Store 5.1.1(v)). Two
distinct operations live here and they are NOT the same thing:

  DELETE /me                       -- immediate. Removes the caller's
                                      memberships and profile. Refuses if the
                                      caller is the sole owner of an org that
                                      is not itself already scheduled for
                                      deletion, because a cascade would
                                      otherwise strip that org's last owner
                                      with no lock and no owner-count guard.
  POST/DELETE /orgs/{id}/deletion  -- 30-day grace period, owner-only,
                                      cancellable inside the window only.

Everything that could destroy data it should not, or claim to have destroyed
data it did not, gets a test here -- including the two false-success traps
(an RLS-filtered DELETE reporting 200 while the row survives) and the
write-skew race that Task 9 needed three rounds to close.
"""
import asyncio
import pytest
from tests.conftest import apply_migrations
from tests.test_auth import mint
from tests.factories import make_user, add_member
from api.db import pool_open, tenant_connection
from api.services.apple import AppleRevokeError


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def pool(db_url, seeded):
    """A second app_user pool, not routed through HTTP -- lets the
    concurrency test below hold one transaction open at a controlled point.
    Mirrors the identical fixture in tests/test_members.py.
    """
    p = await pool_open(app_url(db_url))
    try:
        yield p
    finally:
        await p.close()


# ---------------------------------------------------------------------------
# DELETE /me
# ---------------------------------------------------------------------------
async def test_deleting_own_account_when_not_last_owner_leaves_org_intact(
    app_client, raw_conn, seeded
):
    carol = await make_user(raw_conn, "carol@acme.example.com")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()
    r = await app_client.delete("/me", headers={"Authorization": f"Bearer {mint(str(carol))}"})
    assert r.status_code == 200
    assert r.json()["deleted"] == "membership"
    cur = await raw_conn.execute(
        "SELECT count(*) FROM organizations WHERE id = %s", (seeded["acme"],)
    )
    (n,) = await cur.fetchone()
    assert n == 1, "removing a member must not delete the organization"


async def test_delete_me_actually_removes_the_row_it_reports_removing(
    app_client, raw_conn, seeded
):
    """The false-success trap the brief's own test does not catch.

    `memberships` is under FORCE RLS and its only write policy
    (`membership_write`, migration 0004) is scoped to OWNERS of the org. A
    manager deleting their own membership through `tenant_connection`
    therefore matches ZERO rows -- and a handler that does not check
    rowcount happily returns 200 {"deleted": "membership"} while the
    membership, the profile, and the whole account survive untouched.
    Asserting only "the org still exists" passes in exactly that broken
    state (Task 4's carry note predicted this precise failure). So assert
    what was supposed to be destroyed is gone.
    """
    carol = await make_user(raw_conn, "carol@acme.example.com")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.execute(
        "INSERT INTO email_verifications (user_id, email, token_hash, expires_at) "
        "VALUES (%s, 'carol@acme.example.com', 'ev-carol', now() + interval '1 day')",
        (carol,)
    )
    await raw_conn.commit()

    r = await app_client.delete("/me", headers={"Authorization": f"Bearer {mint(str(carol))}"})
    assert r.status_code == 200

    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE user_id = %s", (carol,))
    assert (await cur.fetchone())[0] == 0, "membership survived a reported deletion"
    cur = await raw_conn.execute("SELECT count(*) FROM profiles WHERE user_id = %s", (carol,))
    assert (await cur.fetchone())[0] == 0, "profile survived a reported deletion"
    cur = await raw_conn.execute(
        "SELECT count(*) FROM email_verifications WHERE user_id = %s", (carol,))
    assert (await cur.fetchone())[0] == 0, "verification tokens survived a reported deletion"

    # ...and nothing that was not the caller's was touched.
    for table in ("memberships", "profiles"):
        cur = await raw_conn.execute(
            f"SELECT count(*) FROM {table} WHERE user_id = %s", (seeded["alice"],))
        assert (await cur.fetchone())[0] == 1, f"another user's {table} row was destroyed"
    cur = await raw_conn.execute("SELECT count(*) FROM memberships WHERE org_id = %s",
                                 (seeded["bistro"],))
    assert (await cur.fetchone())[0] == 1, "another org's data was destroyed"


async def test_last_owner_deleting_account_is_routed_to_org_deletion(app_client, seeded):
    """Must not silently orphan the org."""
    r = await app_client.delete(
        "/me", headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    )
    assert r.status_code == 409
    detail = r.json()["detail"]
    assert "organization" in detail["detail"].lower()
    assert str(seeded["acme"]) in detail["orgs_requiring_deletion"]


async def test_refused_account_deletion_leaves_everything_in_place(
    app_client, raw_conn, seeded
):
    """A 409 must be a true no-op, not a partial deletion."""
    r = await app_client.delete(
        "/me", headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    )
    assert r.status_code == 409
    for table in ("memberships", "profiles"):
        cur = await raw_conn.execute(
            f"SELECT count(*) FROM {table} WHERE user_id = %s", (seeded["alice"],))
        assert (await cur.fetchone())[0] == 1, f"{table} row was destroyed by a refused deletion"


async def test_sole_owner_can_delete_account_once_the_org_is_scheduled(
    app_client, raw_conn, seeded
):
    """The escape hatch. Without it, a sole owner who has already asked for
    their org to be deleted is trapped for 30 days -- which is a deactivation,
    not a deletion, and fails 5.1.1(v).
    """
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    assert (await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)).status_code == 200
    r = await app_client.delete("/me", headers=hdr)
    assert r.status_code == 200
    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE user_id = %s", (seeded["alice"],))
    assert (await cur.fetchone())[0] == 0
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at IS NOT NULL FROM organizations WHERE id = %s",
        (seeded["acme"],))
    assert (await cur.fetchone())[0] is True, "the org must remain scheduled, not be resurrected"


async def test_apple_revocation_failure_does_not_block_account_deletion(
    app_client, raw_conn, seeded, monkeypatch
):
    """A user who asked to be deleted must not be trapped because Apple's
    endpoint is down. Non-blocking by decision (Task 10's recommendation,
    ratified in Task 11's corrections).
    """
    carol = await make_user(raw_conn, "carol@acme.example.com")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.execute(
        "UPDATE profiles SET apple_sub = 'apple-sub-carol' WHERE user_id = %s", (carol,))
    await raw_conn.commit()

    monkeypatch.setenv("APPLE_REFRESH_TOKEN", "rt-carol")
    monkeypatch.setenv("APPLE_CLIENT_ID", "cid")
    monkeypatch.setenv("APPLE_CLIENT_SECRET", "csecret")
    called = []

    async def boom(*a, **kw):
        called.append(True)
        raise AppleRevokeError("apple is down")

    monkeypatch.setattr("api.routes.deletion.revoke_apple_token", boom)

    r = await app_client.delete("/me", headers={"Authorization": f"Bearer {mint(str(carol))}"})
    assert r.status_code == 200
    assert called, "revocation must at least be attempted when apple_sub is set"
    assert r.json()["apple_revoked"] is False, "a failed side effect must be reported, not hidden"
    cur = await raw_conn.execute("SELECT count(*) FROM profiles WHERE user_id = %s", (carol,))
    assert (await cur.fetchone())[0] == 0, "deletion must have completed anyway"


# ---------------------------------------------------------------------------
# POST /orgs/{id}/deletion
# ---------------------------------------------------------------------------
async def test_scheduling_org_deletion_sets_timestamp_immediately(app_client, raw_conn, seeded):
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/deletion",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    assert r.json()["purge_after_days"] == 30
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],)
    )
    (ts,) = await cur.fetchone()
    assert ts is not None, "deletion_scheduled_at must be set on confirm"


async def test_non_owner_cannot_schedule_or_cancel_org_deletion(app_client, raw_conn, seeded):
    carol = await make_user(raw_conn, "carol@acme.example.com")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()
    hdr = {"Authorization": f"Bearer {mint(str(carol))}"}
    assert (await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)).status_code == 403
    assert (await app_client.delete(f"/orgs/{seeded['acme']}/deletion", headers=hdr)).status_code == 403
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],))
    assert (await cur.fetchone())[0] is None


async def test_owner_of_another_org_cannot_schedule_this_ones_deletion(app_client, seeded):
    r = await app_client.post(
        f"/orgs/{seeded['bistro']}/deletion",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 403


async def test_rescheduling_does_not_extend_the_grace_window(app_client, raw_conn, seeded):
    """Re-confirming must be idempotent. Refreshing deletion_scheduled_at
    would silently restart the 30 days and, on a real device retrying a
    request, could keep an org alive indefinitely.
    """
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    r1 = await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert r1.status_code == 200
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '20 days' "
        "WHERE id = %s", (seeded["acme"],))
    await raw_conn.commit()
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],))
    (before,) = await cur.fetchone()

    r2 = await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert r2.status_code == 200
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],))
    (after,) = await cur.fetchone()
    assert after == before, "re-confirming must not restart the grace window"


async def test_billing_failure_is_reported_not_silently_swallowed(app_client, raw_conn, seeded):
    """`cancel_subscription` raises BillingError when STRIPE_API_KEY is
    missing but a customer id is on file. The deletion is still scheduled
    (the user asked for it and that is the durable state), but the response
    must not claim billing was cancelled, and the database must not record
    it as cancelled -- Task 12 has to be able to see the difference.
    """
    await raw_conn.execute(
        "UPDATE organizations SET stripe_customer_id = 'cus_orphan' WHERE id = %s",
        (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/deletion",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["scheduled"] is True
    assert body["billing_cancelled"] is False
    assert body["warnings"], "a failed side effect must surface in the response"
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at IS NOT NULL, billing_cancelled_at "
        "FROM organizations WHERE id = %s", (seeded["acme"],))
    scheduled, billing_cancelled_at = await cur.fetchone()
    assert scheduled is True
    assert billing_cancelled_at is None, "must not record a cancellation that did not happen"


# ---------------------------------------------------------------------------
# The write guard
# ---------------------------------------------------------------------------
async def test_scheduled_org_rejects_writes_before_purge(app_client, seeded):
    """The pre-sync deletion guard. Data must not be resurrected."""
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "zombie@acme.example.com", "role": "manager"}, headers=hdr,
    )
    assert r.status_code == 410
    assert "scheduled for deletion" in str(r.json()).lower()


async def test_offline_device_push_after_deletion_is_discarded(app_client, seeded):
    """The 30-days-offline case: a stale device must not resurrect the org."""
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.patch(
        f"/orgs/{seeded['acme']}/members/{seeded['alice']}",
        json={"role": "manager"}, headers=hdr,
    )
    assert r.status_code == 410


async def test_guard_does_not_tell_strangers_which_orgs_are_being_deleted(
    app_client, raw_conn, seeded
):
    """The guard runs before the route's own authorization, so it must not
    answer for a caller who has no business knowing the org exists at all --
    otherwise 410-vs-403 becomes an oracle for "is this org being deleted?".
    """
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "x@acme.example.com", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['bob']))}"},
    )
    assert r.status_code == 403, "a non-member must get the ordinary 403, not a 410 oracle"


async def test_accepting_an_invite_into_a_scheduled_org_is_rejected(
    app_client, raw_conn, seeded
):
    """`POST /invites/accept` carries no org id in its path, so the URL-shaped
    middleware guard cannot see it. Without a database-level guard, an invite
    issued before the deletion was scheduled still adds a live membership to a
    doomed org.
    """
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                           (seeded["acme"],))
    await raw_conn.commit()
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.example.com", "role": "manager"}, headers=hdr,
    )
    assert r.status_code == 200
    token = r.json()["token"]
    dave = await make_user(raw_conn, "dave@acme.example.com", contact_email_verified=True)
    await raw_conn.commit()

    assert (await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)).status_code == 200

    r2 = await app_client.post(
        "/invites/accept", json={"token": token},
        headers={"Authorization": f"Bearer {mint(str(dave))}"},
    )
    assert r2.status_code == 410
    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE user_id = %s", (dave,))
    assert (await cur.fetchone())[0] == 0, "a doomed org must not gain members"


async def test_guard_rejects_before_the_route_does_any_work(app_client, raw_conn, seeded):
    """Pins the middleware specifically, not the database trigger.

    Removing a user who is not a member writes nothing, so migration 0007's
    trigger never fires and the route would answer 404. The 410 can therefore
    only come from the middleware refusing the request up front -- which is
    the property a future `POST /sync` depends on: the batch must be discarded
    before any of it is applied, not row by row.
    """
    stranger = await make_user(raw_conn, "stranger@acme.example.com")
    await raw_conn.commit()
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.delete(
        f"/orgs/{seeded['acme']}/members/{stranger}", headers=hdr)
    assert r.status_code == 410


async def test_reads_are_never_blocked_by_the_guard(app_client, seeded):
    """The export is the user's last copy. Blocking GETs during the grace
    window would make the deletion unrecoverable by design.
    """
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.get(f"/orgs/{seeded['acme']}/export", headers=hdr)
    assert r.status_code == 200
    assert (await app_client.get("/me", headers=hdr)).status_code == 200


# ---------------------------------------------------------------------------
# DELETE /orgs/{id}/deletion  (cancel within the grace window)
# ---------------------------------------------------------------------------
async def test_owner_can_cancel_within_grace_window(app_client, raw_conn, seeded):
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.delete(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert r.status_code == 200
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],)
    )
    (ts,) = await cur.fetchone()
    assert ts is None


async def test_cancelling_restores_writability(app_client, seeded, raw_conn):
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                           (seeded["acme"],))
    await raw_conn.commit()
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    assert (await app_client.post(
        f"/orgs/{seeded['acme']}/deletion", headers=hdr)).status_code == 200
    assert (await app_client.delete(
        f"/orgs/{seeded['acme']}/deletion", headers=hdr)).status_code == 200
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "back@acme.example.com", "role": "manager"}, headers=hdr,
    )
    assert r.status_code == 200


async def test_cancelling_after_the_grace_window_is_refused(app_client, raw_conn, seeded):
    """Once the window has elapsed the deletion is due; the only reason the
    org still exists is that the purge job has not run yet. Letting a cancel
    land in that gap resurrects a deletion that was already final, and the
    Stripe subscription cancelled 30 days ago does not come back with it.
    """
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s", (seeded["acme"],))
    await raw_conn.commit()
    r = await app_client.delete(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert r.status_code == 410
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],))
    assert (await cur.fetchone())[0] is not None, "an expired deletion must stay scheduled"


async def test_cancelling_a_deletion_that_was_never_scheduled_is_404(app_client, seeded):
    r = await app_client.delete(
        f"/orgs/{seeded['acme']}/deletion",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 404


# ---------------------------------------------------------------------------
# purge_scheduled_orgs
# ---------------------------------------------------------------------------
async def test_purge_removes_org_only_after_grace_elapses(raw_conn, seeded):
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '10 days' WHERE id = %s",
        (seeded["acme"],),
    )
    cur = await raw_conn.execute("SELECT purge_scheduled_orgs(interval '30 days')")
    (purged,) = await cur.fetchone()
    assert purged == 0, "must not purge inside the grace window"

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' WHERE id = %s",
        (seeded["acme"],),
    )
    cur = await raw_conn.execute("SELECT purge_scheduled_orgs(interval '30 days')")
    (purged,) = await cur.fetchone()
    assert purged == 1
    cur = await raw_conn.execute(
        "SELECT count(*) FROM locations WHERE org_id = %s", (seeded["acme"],)
    )
    (n,) = await cur.fetchone()
    assert n == 0, "purge must cascade to locations"


async def test_purge_never_touches_an_unscheduled_org(raw_conn, seeded):
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '99 days' WHERE id = %s",
        (seeded["acme"],),
    )
    cur = await raw_conn.execute("SELECT purge_scheduled_orgs(interval '30 days')")
    assert (await cur.fetchone())[0] == 1
    cur = await raw_conn.execute("SELECT count(*) FROM organizations WHERE id = %s",
                                 (seeded["bistro"],))
    assert (await cur.fetchone())[0] == 1, "an unscheduled org must survive the purge"
    cur = await raw_conn.execute("SELECT count(*) FROM memberships WHERE org_id = %s",
                                 (seeded["bistro"],))
    assert (await cur.fetchone())[0] == 1


async def test_authenticated_cannot_execute_the_purge_function(pool, seeded):
    """`purge_scheduled_orgs(interval)` takes the grace period as an
    argument, so EXECUTE on it is equivalent to "delete every organization
    in the database that anyone has ever scheduled, right now, grace
    ignored". It must not be reachable from the request path.
    """
    import psycopg
    async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            await conn.execute("SELECT purge_scheduled_orgs(interval '0 days')")


# ---------------------------------------------------------------------------
# GET /orgs/{id}/export
# ---------------------------------------------------------------------------
async def test_export_is_owner_only(app_client, raw_conn, seeded):
    """`invites` is owner-only under RLS (0004's `invite_all`). Exporting on
    a non-owner's tenant_connection would silently drop every pending invite
    from the zip -- an export that looks complete and is not, immediately
    before an irreversible purge. Resolved by requiring owner.
    """
    carol = await make_user(raw_conn, "carol@acme.example.com")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()
    r = await app_client.get(
        f"/orgs/{seeded['acme']}/export",
        headers={"Authorization": f"Bearer {mint(str(carol))}"},
    )
    assert r.status_code == 403


async def test_export_contains_pending_invites(app_client, raw_conn, seeded):
    await raw_conn.execute(
        "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
        "VALUES (%s, 'pending@acme.example.com', 'manager', 'hash-pending', %s, "
        "        now() + interval '7 days')",
        (seeded["acme"], seeded["alice"]),
    )
    await raw_conn.commit()
    r = await app_client.get(
        f"/orgs/{seeded['acme']}/export",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    assert r.headers["content-type"] == "application/zip"
    import io, zipfile
    z = zipfile.ZipFile(io.BytesIO(r.content))
    assert set(z.namelist()) == {
        "organization.csv", "locations.csv", "members.csv", "invites.csv"}
    assert b"pending@acme.example.com" in z.read("invites.csv")
    assert b"Acme Main" in z.read("locations.csv")


async def test_a_zero_membership_org_never_reaches_build_export(app_client, raw_conn, seeded):
    """`members.csv` is marked must-be-non-empty in api/services/export.py, on
    the assumption that a live org always has at least one membership. The one
    flow in this phase that can leave an org with zero memberships is a sole
    owner deleting their account after scheduling the org -- so prove that
    state can never reach `build_export` and raise a false `ExportError` that
    blocks a legitimate deletion. Nothing that can still call the endpoint
    survives the owner check.
    """
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert (await app_client.delete("/me", headers=hdr)).status_code == 200
    cur = await raw_conn.execute("SELECT count(*) FROM memberships WHERE org_id = %s",
                                 (seeded["acme"],))
    assert (await cur.fetchone())[0] == 0, "precondition: the org now has no members"

    r = await app_client.get(f"/orgs/{seeded['acme']}/export", headers=hdr)
    assert r.status_code == 403, f"must be an ordinary 403, not an ExportError 500: {r.text}"


async def test_export_of_another_orgs_data_is_refused(app_client, seeded):
    r = await app_client.get(
        f"/orgs/{seeded['bistro']}/export",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 403


# ---------------------------------------------------------------------------
# Concurrency: the write-skew race that Task 9 needed three rounds to close,
# reached through a NEW path (DELETE /me) that also removes owner rows.
# ---------------------------------------------------------------------------
async def test_concurrent_account_deletions_cannot_zero_out_owners(pool, raw_conn, seeded):
    """Two owners of one org, both deleting their own account at once.

    Unlocked, each reads an owner count of 2 (neither sees the other's
    uncommitted DELETE under READ COMMITTED), each concludes it is not the
    sole owner, and both commit -- textbook write skew, zero owners left, an
    org nobody can ever delete or administer again. The org advisory lock
    (`api.routes.members._lock_org`, identical key derivation) is what makes
    the second request re-read a fresh count.

    Driven through two real `tenant_connection`s rather than two HTTP
    requests: httpx's ASGITransport does not reliably interleave, and a
    concurrency test that passes with the lock deleted proves nothing (see
    the same note in tests/test_members.py).
    """
    from api.routes import deletion as deletion_module

    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.commit()

    first_locked = asyncio.Event()
    proceed = asyncio.Event()

    async def run(user_id, pause):
        # The exact sequence delete_account performs, against the SAME shared
        # production helpers rather than a reimplementation of their SQL.
        async with tenant_connection(pool, {"sub": str(user_id)}) as conn:
            orgs = await deletion_module._lock_caller_orgs(conn, str(user_id))
            if pause:
                first_locked.set()
                await proceed.wait()
            if await deletion_module._sole_owner_blocking_orgs(conn, str(user_id)):
                return "refused"
            await deletion_module._purge_caller_rows(conn, str(user_id), orgs)
            return "deleted"

    async def first():
        return await run(seeded["alice"], pause=True)

    async def second():
        await first_locked.wait()
        task = asyncio.create_task(run(boss, pause=False))
        await asyncio.sleep(0.3)
        assert not task.done(), "the second account deletion must block on the org lock"
        proceed.set()
        return await task

    a, b = await asyncio.gather(first(), second())
    assert {a, b} == {"deleted", "refused"}

    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'",
        (seeded["acme"],),
    )
    assert (await cur.fetchone())[0] == 1, "the org must keep exactly one owner, never zero"


async def test_purge_and_cancel_cannot_interleave_to_resurrect_an_org(
    pool, raw_conn, seeded, db_url
):
    """A cancel that commits while the purge job is mid-flight must either
    save the org or lose the race cleanly -- never leave a purged org's
    children behind, and never un-schedule an org that has already been
    deleted.
    """
    from api.routes import members as members_module

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s", (seeded["acme"],))
    await raw_conn.commit()

    async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as holder:
        # Hold the org lock exactly as cancel_org_deletion does, then prove
        # the purge blocks behind it rather than racing it.
        await members_module._lock_org(holder, seeded["acme"])
        task = asyncio.create_task(_purge(db_url))
        await asyncio.sleep(0.3)
        assert not task.done(), "purge must serialize against the org lock"
        await holder.execute(
            "UPDATE organizations SET deletion_scheduled_at = NULL WHERE id = %s",
            (seeded["acme"],))
    purged = await task
    assert purged == 0, "purge must re-read the schedule after taking the lock"
    cur = await raw_conn.execute("SELECT count(*) FROM organizations WHERE id = %s",
                                 (seeded["acme"],))
    assert (await cur.fetchone())[0] == 1


async def _purge(db_url):
    """A separate owner connection -- the purge job runs as the migration
    runner, never as app_user."""
    import psycopg
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    try:
        cur = await conn.execute("SELECT purge_scheduled_orgs(interval '30 days')")
        (n,) = await cur.fetchone()
        await conn.commit()
        return n
    finally:
        await conn.close()


# ---------------------------------------------------------------------------
# The two new deliberate RLS bypasses
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("role", ["deletion_definer", "purge_definer"])
async def test_new_definer_roles_are_unreachable(raw_conn, role):
    """Same discipline 0004 and 0006 apply to `rls_definer`/`invite_definer`.
    Both new roles hold a permissive `USING (true)` policy on organizations --
    one of them a DELETE policy -- so if either were reachable, FORCE ROW
    LEVEL SECURITY on organizations would be decoration.
    """
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT rolcanlogin, rolbypassrls, rolsuper, rolinherit "
        "FROM pg_roles WHERE rolname = %s", (role,))
    canlogin, bypass, super_, inherit = await cur.fetchone()
    assert (canlogin, bypass, super_, inherit) == (False, False, False, False)

    cur = await raw_conn.execute(
        "SELECT pg_has_role('app_user', %s, 'MEMBER'), "
        "       pg_has_role('authenticated', %s, 'MEMBER')", (role, role))
    assert await cur.fetchone() == (False, False)

    # pg_auth_members, not pg_has_role(): the latter answers true for a
    # superuser regardless, so it cannot see the migration forgetting to give
    # its temporary membership back (0004's REVOKE dance).
    cur = await raw_conn.execute(
        "SELECT g.rolname FROM pg_auth_members m "
        "JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles g ON g.oid = m.member "
        "WHERE r.rolname = %s", (role,))
    assert await cur.fetchall() == [], f"{role} must be left with no members"

    cur = await raw_conn.execute(
        "SELECT count(*) FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner "
        "WHERE r.rolname = %s", (role,))
    assert (await cur.fetchone())[0] == 0, f"{role} must own no table"


async def test_a_tenant_cannot_learn_another_orgs_deletion_state(pool, raw_conn, seeded):
    """The guard must not become a cross-org oracle. `deletion_scheduled_at`
    is a new column on an existing RLS-governed table, and the trigger that
    reads it is deliberately not exposed as a callable helper.
    """
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() WHERE id = %s",
        (seeded["bistro"],))
    await raw_conn.commit()
    async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
        cur = await conn.execute(
            "SELECT count(*) FROM organizations WHERE id = %s", (seeded["bistro"],))
        assert (await cur.fetchone())[0] == 0
        cur = await conn.execute(
            "SELECT count(*) FROM pg_proc WHERE proname = 'org_is_scheduled_for_deletion'")
        assert (await cur.fetchone())[0] == 0, (
            "a granted org_is_scheduled_for_deletion() helper would answer for any "
            "org id a tenant can name; the check belongs inside the trigger")


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------
async def test_deletion_columns_and_index_exist(raw_conn):
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = 'public' AND table_name = 'organizations' "
        "AND column_name IN ('deletion_scheduled_at', 'stripe_customer_id', "
        "                    'billing_cancelled_at') ORDER BY column_name")
    assert [r[0] for r in await cur.fetchall()] == [
        "billing_cancelled_at", "deletion_scheduled_at", "stripe_customer_id"]
    cur = await raw_conn.execute(
        "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' "
        "AND indexname = 'organizations_deletion_idx'")
    assert (await cur.fetchone())[0] == 1
