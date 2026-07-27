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
from fastapi import HTTPException
from tests.conftest import apply_migrations
from tests.test_auth import mint
from tests.factories import make_user, make_org, add_member
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


async def test_owner_can_cancel_with_a_trailing_slash_in_the_url(
    app_client, raw_conn, seeded
):
    """Final-review Minor: `deletion_guard` (api/main.py) exempted the two
    writes that must keep working on a scheduled org by testing
    `path.endswith("/deletion")`. It sees the RAW path, before Starlette's
    trailing-slash redirect, so `DELETE /orgs/{id}/deletion/` missed the
    exemption and the guard answered 410 -- meaning a client that appends a
    slash could never cancel a scheduled deletion, which is the exact write
    the exemption exists to preserve. `follow_redirects` because the
    canonical route has no trailing slash; the point is that the guard lets
    the request reach the router at all.
    """
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.delete(
        f"/orgs/{seeded['acme']}/deletion/", headers=hdr, follow_redirects=True
    )
    assert r.status_code == 200, f"{r.status_code} {r.text!r}"
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],)
    )
    assert (await cur.fetchone())[0] is None


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


async def test_membership_committed_after_the_fixed_point_is_never_left_behind(
    pool, raw_conn, seeded
):
    """Review round 1, Critical-1 -- and the outcome corrected in round 2.

    `_lock_caller_orgs` reaches a fixed point on the caller's org set. A
    membership committed AFTER that final read cannot have been locked: the
    caller was not a member yet, so `accept_invite_tx`'s own org lock never
    contended.

    Round 1 scoped the DELETE to that frozen set, so `DELETE /me` returned
    200 with `profiles` gone and a LIVE membership surviving in another
    tenant's org -- `GET /me` renders a null contact_email and that org's
    `members.csv` exports a NULL address. Round 2 rejected the obvious repair
    (delete unscoped) because it strips memberships in orgs that were never
    locked or owner-counted.

    The answer is neither: refuse the whole deletion with 409 and let the
    retry -- whose fixed point now includes the new org -- do it properly.
    Nothing is deleted and nothing is left behind.
    """
    # A second owner of Acme, so Alice is not the sole owner and the deletion
    # actually proceeds rather than 409ing before it can be tested.
    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                           (seeded["bistro"],))
    await raw_conn.execute(
        "UPDATE profiles SET contact_email_verified_at = now() WHERE user_id = %s",
        (seeded["alice"],))
    await raw_conn.execute(
        "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
        "VALUES (%s, 'alice@acme.test', 'manager', 'hash-late', %s, "
        "        now() + interval '7 days')",
        (seeded["bistro"], seeded["bob"]),
    )
    await raw_conn.commit()

    from api.routes import deletion as deletion_module

    async def alice_deletes_her_account():
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            orgs = await deletion_module._lock_caller_orgs(conn, str(seeded["alice"]))
            assert [str(o) for o in orgs] == [str(seeded["acme"])]

            # A second, fully independent transaction commits the new membership
            # while the first is still open and past its fixed point.
            async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as other:
                cur = await other.execute(
                    "SELECT status FROM accept_invite_tx('hash-late')")
                assert (await cur.fetchone())[0] == "ok"

            assert not await deletion_module._sole_owner_blocking_orgs(
                conn, str(seeded["alice"]))
            await deletion_module._purge_caller_rows(conn, str(seeded["alice"]), orgs)

    with pytest.raises(HTTPException) as exc:
        await alice_deletes_her_account()
    assert exc.value.status_code == 409, "must not report success over a live membership"

    # Nothing destroyed, nothing stranded: the caller retries and the retry's
    # fixed point covers both orgs.
    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE user_id = %s", (seeded["alice"],))
    assert (await cur.fetchone())[0] == 2
    cur = await raw_conn.execute(
        "SELECT count(*) FROM profiles WHERE user_id = %s", (seeded["alice"],))
    assert (await cur.fetchone())[0] == 1, "a refused deletion destroyed the profile"

    async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
        orgs = await deletion_module._lock_caller_orgs(conn, str(seeded["alice"]))
        assert len(orgs) == 2, "the retry must lock both orgs"
        assert not await deletion_module._sole_owner_blocking_orgs(
            conn, str(seeded["alice"]))
        assert await deletion_module._purge_caller_rows(
            conn, str(seeded["alice"]), orgs) == 2
    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE user_id = %s", (seeded["alice"],))
    assert (await cur.fetchone())[0] == 0, "the retry must converge and complete"


async def test_an_unlocked_org_is_refused_rather_than_silently_stripped(
    pool, raw_conn, seeded
):
    """Review round 2, Critical. The mirror image of the test above, and the
    reason the unscoped DELETE is compared against the locked set.

    An unscoped DELETE with no comparison removes memberships in orgs this
    transaction never locked or owner-counted -- re-opening the zero-owner
    write skew Task 9 needed three rounds to close, which is strictly worse
    than the false success it replaced.

    Alice is offered a SECOND-owner seat in Bistro. Her account deletion fixes
    its point at {Acme}. She accepts the Bistro owner invite in an independent
    transaction. Bistro's original owner Bob then locks Bistro, counts two
    owners and leaves. Alice's DELETE must now refuse: removing her Bistro
    owner row without ever holding Bistro's lock leaves Bistro with zero
    members and zero owners, `deletion_scheduled_at` NULL -- invisible to
    every tenant under RLS, administrable by nobody, and never enumerated by
    `purge_scheduled_orgs`.
    """
    from api.routes import deletion as D

    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                           (seeded["bistro"],))
    await raw_conn.execute(
        "UPDATE profiles SET contact_email_verified_at = now() WHERE user_id = %s",
        (seeded["alice"],))
    await raw_conn.execute(
        "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
        "VALUES (%s, 'alice@acme.test', 'owner', 'hash-owner-seat', %s, "
        "        now() + interval '7 days')",
        (seeded["bistro"], seeded["bob"]),
    )
    await raw_conn.commit()

    async def alice_deletes_her_account():
        # The handler's real order -- lock, owner-count, THEN delete -- and the
        # exception is allowed to PROPAGATE out of `tenant_connection`, exactly
        # as it does from the route. Catching it inside the context manager
        # would let the block exit normally and COMMIT the partial deletion,
        # which is the very thing being tested against.
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            orgs = await D._lock_caller_orgs(conn, str(seeded["alice"]))
            assert [str(o) for o in orgs] == [str(seeded["acme"])], "Bistro must be unlocked"
            assert not await D._sole_owner_blocking_orgs(conn, str(seeded["alice"]))

            # The interleave lands between the owner-count and the delete,
            # which is where a real request is actually vulnerable.
            async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as other:
                cur = await other.execute(
                    "SELECT status FROM accept_invite_tx('hash-owner-seat')")
                assert (await cur.fetchone())[0] == "ok"

            # Bob leaves Bistro: he locks it, counts two owners, and goes.
            async with tenant_connection(pool, {"sub": str(seeded["bob"])}) as bobs:
                bob_orgs = await D._lock_caller_orgs(bobs, str(seeded["bob"]))
                assert not await D._sole_owner_blocking_orgs(bobs, str(seeded["bob"]))
                await D._purge_caller_rows(bobs, str(seeded["bob"]), bob_orgs)

            await D._purge_caller_rows(conn, str(seeded["alice"]), orgs)

    with pytest.raises(HTTPException) as exc:
        await alice_deletes_her_account()
    assert exc.value.status_code == 409
    assert "changing concurrently" in str(exc.value.detail).lower()

    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'",
        (seeded["bistro"],))
    assert (await cur.fetchone())[0] == 1, (
        "an org lost its last owner through a membership row that was never locked")


async def test_a_refused_account_deletion_rolls_back_completely(pool, raw_conn, seeded):
    """The 409 above must delete nothing at all -- a partial deletion would be
    worse than either failure it replaces."""
    from api.routes import deletion as D

    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.execute("UPDATE organizations SET plan = 'growth' WHERE id = %s",
                           (seeded["bistro"],))
    await raw_conn.execute(
        "UPDATE profiles SET contact_email_verified_at = now() WHERE user_id = %s",
        (seeded["alice"],))
    await raw_conn.execute(
        "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
        "VALUES (%s, 'alice@acme.test', 'manager', 'hash-late2', %s, "
        "        now() + interval '7 days')",
        (seeded["bistro"], seeded["bob"]),
    )
    await raw_conn.commit()

    with pytest.raises(HTTPException):
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            orgs = await D._lock_caller_orgs(conn, str(seeded["alice"]))
            async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as other:
                await other.execute("SELECT status FROM accept_invite_tx('hash-late2')")
            await D._purge_caller_rows(conn, str(seeded["alice"]), orgs)

    cur = await raw_conn.execute(
        "SELECT count(*) FROM memberships WHERE user_id = %s", (seeded["alice"],))
    assert (await cur.fetchone())[0] == 2, "a refused deletion removed rows anyway"
    cur = await raw_conn.execute(
        "SELECT count(*) FROM profiles WHERE user_id = %s", (seeded["alice"],))
    assert (await cur.fetchone())[0] == 1
    cur = await raw_conn.execute("SELECT count(*) FROM deleted_accounts")
    assert (await cur.fetchone())[0] == 0, "a refused deletion left a tombstone"


async def test_purge_and_cancel_cannot_interleave_to_resurrect_an_org(
    pool, raw_conn, seeded, db_url
):
    """A cancel that commits while the purge job is mid-flight must either
    save the org or lose the race cleanly -- never leave a purged org's
    children behind, and never un-schedule an org that has already been
    deleted.

    Final-review Important-2: this used to call a local `_purge()` helper that
    ran only `purge_scheduled_orgs`, skipping `organizations_pending_purge`
    and therefore the row lock the shipping job actually takes. That is the
    one respect in which the replica differed from production, and it is the
    respect that hid a lock-order inversion between this path and
    `cancel_org_deletion` (see
    tests/test_purge_job.py::test_the_real_cancel_endpoint_racing_the_real_purge_job_never_deadlocks).
    It now drives `api.jobs.purge.run_purge` itself, with a storage callback,
    so the storage half of the guarantee is asserted too rather than assumed.
    """
    from api.jobs.purge import run_purge
    from api.routes import members as members_module

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' "
        "WHERE id = %s", (seeded["acme"],))
    await raw_conn.commit()

    storage_prefixes = []

    async def fake_storage_delete(prefix: str):
        storage_prefixes.append(prefix)

    async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as holder:
        # Hold the org lock exactly as cancel_org_deletion does, then prove
        # the purge blocks behind it rather than racing it.
        await members_module._lock_org(holder, seeded["acme"])
        task = asyncio.create_task(run_purge(db_url, storage_delete=fake_storage_delete))
        await asyncio.sleep(0.3)
        assert not task.done(), "purge must serialize against the org lock"
        await holder.execute(
            "UPDATE organizations SET deletion_scheduled_at = NULL WHERE id = %s",
            (seeded["acme"],))
    purged = await task
    assert purged == 0, "purge must re-read the schedule after taking the lock"
    assert storage_prefixes == [], (
        "an org the cancel saved must not have had its storage deleted -- the "
        "purge must be blocked BEFORE it reaches storage_delete, not after"
    )
    cur = await raw_conn.execute("SELECT count(*) FROM organizations WHERE id = %s",
                                 (seeded["acme"],))
    assert (await cur.fetchone())[0] == 1


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


# ---------------------------------------------------------------------------
# Self-review probes. Written after the implementation, as deliberate attempts
# to break it, and kept because each one pins a distinct property that nothing
# above covers: cross-org blast radius on a refusal, the non-canonical-UUID
# spelling that Task 9 needed three rounds to close, the orphan race between a
# cancel and an ex-sole-owner's account deletion, multi-org lock ordering, and
# the claim that the database trigger -- not the URL middleware -- is what
# actually stops writes.
# ---------------------------------------------------------------------------
async def test_refusal_does_not_delete_the_other_orgs_membership(app_client, raw_conn, seeded):
    """Blast radius of a 409: the caller's memberships in OTHER orgs must
    survive untouched. A refusal is a refusal, not a partial deletion."""
    other = await make_org(raw_conn, "Other Co")
    await add_member(raw_conn, seeded["alice"], other, "manager")
    await raw_conn.commit()
    r = await app_client.delete("/me", headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"})
    assert r.status_code == 409
    cur = await raw_conn.execute("SELECT count(*) FROM memberships WHERE user_id=%s", (seeded["alice"],))
    assert (await cur.fetchone())[0] == 2


async def test_uppercase_org_id_still_guarded(app_client, seeded):
    """Correction 3, reached through the guard rather than the lock. Task 9
    reproduced two concurrent removals -- one URL lowercase, one uppercase --
    both succeeding and leaving zero owners, because hashtextextended hashes
    the raw string. Everything here types its path param as uuid.UUID and the
    middleware parses the captured segment the same way, so every spelling of
    the same org resolves to one value before any handler or lock sees it."""
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    upper = str(seeded["acme"]).upper()
    r = await app_client.post(f"/orgs/{upper}/invites",
                              json={"email": "z@a.example.com", "role": "manager"}, headers=hdr)
    assert r.status_code == 410, r.text


async def test_malformed_org_id(app_client, seeded):
    """A bad org id in the URL must never reach Postgres and 500."""
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    for bad in ("not-a-uuid", "------------------------------------", "%00"):
        r = await app_client.post(f"/orgs/{bad}/deletion", headers=hdr)
        assert r.status_code in (404, 422), (bad, r.status_code, r.text)


async def test_double_delete_me(app_client, raw_conn, seeded):
    """Deleting an already-deleted account is a no-op, not a 500. A retrying
    client must not be told something went wrong."""
    carol = await make_user(raw_conn, "carol@acme.example.com")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()
    h = {"Authorization": f"Bearer {mint(str(carol))}"}
    assert (await app_client.delete("/me", headers=h)).status_code == 200
    r2 = await app_client.delete("/me", headers=h)
    assert r2.status_code == 200, r2.text


async def test_cancel_racing_account_deletion_cannot_orphan(pool, raw_conn, seeded):
    """A cancel racing an ex-sole-owner's account deletion must not leave an
    org UNSCHEDULED with ZERO members -- invisible to every tenant under RLS,
    administrable by nobody, and invisible to the purge job forever.

    Review round 1, Important-3 corrected what this pins: not lock ordering.
    `org_update` (0004) re-evaluates `current_user_memberships()` against the
    UPDATE's own snapshot, so once the membership delete commits the row is
    filtered out and the UPDATE matches zero rows. The load-bearing line is
    `cancel_org_deletion`'s `cur.rowcount != 1` check, which turns that zero
    into a refusal rather than a cheerful `{"cancelled": true}` over an org
    that is still scheduled.

    Review round 2 caught this test replicating the handler inline: deleting
    the rowcount check from the REAL handler left the suite green, because the
    mutation was only ever caught in the test's own copy. It now calls
    `cancel_org_deletion` itself. No hook is needed to force the interleave:
    the real handler blocks inside its own `_lock_org` on the lock the account
    deletion is holding.

    And driving the real handler corrected the story a SECOND time. The
    refusal here is a 404, not the 409 the round-1 docstring claimed: once the
    membership delete commits, `org_select` hides the org from the SELECT
    above the UPDATE, so the handler never reaches the rowcount check at all.
    Measured, both ways -- removing the `row is None` guard AND removing the
    rowcount check each leave this test and the whole suite green. Neither is
    load-bearing HERE, because `org_update` makes the orphaning UPDATE
    impossible on its own; they exist so a write that does not land is never
    reported as success.

    The rowcount branch is in fact unreachable on a SCHEDULED org: losing
    ownership needs either the membership row to go (caught by the SELECT
    above) or a role change, which migration 0007's trigger refuses while the
    org is scheduled. It is reachable, and pinned, on the not-yet-scheduled
    path -- see
    `test_losing_ownership_mid_schedule_is_refused_not_a_500` below.

    What this test pins is the invariant itself: the cancel is refused and no
    orphan exists afterwards.
    """
    from types import SimpleNamespace
    from api.auth import CallerIdentity
    from api.routes import deletion as D

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() WHERE id=%s",
        (seeded["acme"],))
    await raw_conn.commit()

    alice = str(seeded["alice"])
    caller = CallerIdentity(user_id=alice, claims={"sub": alice})
    request = SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace(pool=pool)))

    locked = asyncio.Event()
    go = asyncio.Event()

    async def delete_account():
        async with tenant_connection(pool, {"sub": alice}) as conn:
            orgs = await D._lock_caller_orgs(conn, alice)
            locked.set()
            await go.wait()
            assert not await D._sole_owner_blocking_orgs(conn, alice)
            await D._purge_caller_rows(conn, alice, orgs)
            return "deleted"

    async def cancel():
        await locked.wait()
        # THE REAL HANDLER, not a replica.
        t = asyncio.create_task(
            D.cancel_org_deletion(seeded["acme"], request, caller))
        await asyncio.sleep(0.3)
        assert not t.done(), "the cancel must serialize behind the org lock"
        go.set()
        try:
            await t
            return "cancelled"
        except HTTPException as e:
            return str(e.status_code)

    a, b = await asyncio.gather(delete_account(), cancel())
    assert a == "deleted"
    assert b in ("403", "404", "409"), f"the cancel must be refused, got {b}"

    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at IS NOT NULL, "
        "(SELECT count(*) FROM memberships m WHERE m.org_id = o.id) "
        "FROM organizations o WHERE id = %s", (seeded["acme"],))
    scheduled, members = await cur.fetchone()
    assert (scheduled, members) != (False, 0), "orphaned: unscheduled with zero members"
    assert scheduled is True and members == 0


async def test_losing_ownership_mid_schedule_is_refused_not_a_500(pool, raw_conn, seeded):
    """Review round 2, Minor: `schedule_org_deletion` returned 500 when its
    UPDATE matched zero rows, which is a lost race, not a server fault.

    This is the one path where that branch is genuinely REACHABLE. The org is
    not scheduled yet, so migration 0007's trigger does not block a concurrent
    role change: the caller passes `_require_owner`, blocks on the org lock,
    is demoted to manager while it waits, and then still SELECTs the row
    (`org_select` admits any member) while the UPDATE matches nothing
    (`org_update` admits only owners). Drives the REAL handler.
    """
    from types import SimpleNamespace
    from api.auth import CallerIdentity
    from api.routes import deletion as D, members as M

    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.commit()

    alice = str(seeded["alice"])
    caller = CallerIdentity(user_id=alice, claims={"sub": alice})
    request = SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace(pool=pool)))

    async with tenant_connection(pool, {"sub": str(boss)}) as bosss:
        await M._lock_org(bosss, seeded["acme"])
        task = asyncio.create_task(
            D.schedule_org_deletion(seeded["acme"], request, caller))
        await asyncio.sleep(0.3)
        assert not task.done(), "the schedule must serialize behind the org lock"
        # Alice passed _require_owner already; take her ownership away.
        await bosss.execute(
            "UPDATE memberships SET role = 'manager' WHERE org_id = %s AND user_id = %s",
            (seeded["acme"], seeded["alice"]))

    with pytest.raises(HTTPException) as exc:
        await task
    assert exc.value.status_code == 409, "a lost race is not a 500"

    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],))
    assert (await cur.fetchone())[0] is None, "a refused schedule must not have landed"


async def test_a_non_member_cannot_reach_the_org_advisory_lock(pool, app_client, seeded):
    """Review round 1, Important-3: why both /deletion handlers authorize
    BEFORE locking.

    An earlier version locked first, to keep the ownership check inside the
    lock. That was unnecessary -- `org_update` (0004) re-evaluates
    `current_user_memberships()` on the UPDATE's own snapshot, so the race it
    was defending against was already closed -- and it was not free: any
    authenticated caller could take and hold the advisory lock on an arbitrary
    org id, one they have no relationship with and whose existence RLS
    otherwise hides, just by POSTing here. That serializes every
    owner-count-sensitive operation on the victim org.

    Held here deterministically: with Bistro's lock taken by another
    transaction, Alice -- an owner of Acme and a stranger to Bistro -- must be
    refused immediately rather than queueing behind it.
    """
    from api.routes import members as members_module
    async with tenant_connection(pool, {"sub": str(seeded["bob"])}) as holder:
        await members_module._lock_org(holder, seeded["bistro"])
        r = await asyncio.wait_for(
            app_client.post(
                f"/orgs/{seeded['bistro']}/deletion",
                headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
            ),
            timeout=5,
        )
    assert r.status_code == 403


# ---------------------------------------------------------------------------
# The account tombstone (review round 1, Critical-2)
# ---------------------------------------------------------------------------
async def test_deleted_account_leaves_a_tombstone_for_the_identity_purge(
    app_client, raw_conn, seeded
):
    """`DELETE /me` cannot remove the `auth.users` row, so something
    privileged has to finish the job. Once `profiles` is deleted, the only
    surviving record of the account is that same `auth.users` row -- which no
    code on the request path can read. Without this tombstone, every account
    deleted before Task 12 lands is permanently unenumerable and therefore
    permanently unpurgeable, and the set grows with each deletion.
    """
    carol = await make_user(raw_conn, "carol@acme.example.com")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()

    r = await app_client.delete("/me", headers={"Authorization": f"Bearer {mint(str(carol))}"})
    assert r.status_code == 200
    cur = await raw_conn.execute(
        "SELECT count(*) FROM deleted_accounts WHERE user_id = %s", (carol,))
    assert (await cur.fetchone())[0] == 1, "no record of the account to purge later"
    cur = await raw_conn.execute("SELECT count(*) FROM profiles WHERE user_id = %s", (carol,))
    assert (await cur.fetchone())[0] == 0


async def test_the_purge_job_can_actually_enumerate_pending_identities(raw_conn, seeded):
    """A write-only tombstone is no better than none. `deleted_accounts` is
    FORCE RLS with no SELECT policy for the migration runner, so a job
    connecting as `postgres` would read ZERO rows and silently purge nothing
    -- Task 4's carry note, applied to the very table that exists to stop
    deletions being lost. The SECURITY DEFINER reader is what closes it.
    """
    await raw_conn.execute(
        "INSERT INTO deleted_accounts (user_id) VALUES (%s)", (seeded["alice"],))
    cur = await raw_conn.execute("SELECT user_id FROM accounts_pending_identity_purge()")
    assert [r[0] for r in await cur.fetchall()] == [seeded["alice"]]


async def test_tombstone_disappears_when_the_identity_is_finally_removed(raw_conn, seeded):
    """The FK cascades from auth.users, so the table means exactly "identities
    still awaiting purge" and Task 12 needs no second cleanup step."""
    await raw_conn.execute(
        "INSERT INTO deleted_accounts (user_id) VALUES (%s)", (seeded["alice"],))
    await raw_conn.execute("DELETE FROM auth.users WHERE id = %s", (seeded["alice"],))
    cur = await raw_conn.execute("SELECT count(*) FROM deleted_accounts")
    assert (await cur.fetchone())[0] == 0


async def test_a_tenant_cannot_read_or_forge_the_tombstone_list(pool, raw_conn, seeded):
    """0003's ALTER DEFAULT PRIVILEGES hands `authenticated` full DML on every
    new table in this schema automatically, so the ABSENCE of
    SELECT/UPDATE/DELETE policies is what actually confines this one. A tenant
    must not read the global list of deleted accounts, un-delete itself, or
    tombstone somebody else.
    """
    import psycopg
    await raw_conn.execute(
        "INSERT INTO deleted_accounts (user_id) VALUES (%s)", (seeded["bob"],))
    await raw_conn.commit()
    async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
        cur = await conn.execute("SELECT count(*) FROM deleted_accounts")
        assert (await cur.fetchone())[0] == 0, "the tombstone list is not tenant-readable"
        cur = await conn.execute("DELETE FROM deleted_accounts")
        assert cur.rowcount == 0, "a tenant must not be able to un-delete an account"
    async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
        with pytest.raises(psycopg.Error):
            await conn.execute(
                "INSERT INTO deleted_accounts (user_id) VALUES (%s)", (seeded["bob"],))


# ---------------------------------------------------------------------------
# Billing remediation (review round 1, Important-4)
# ---------------------------------------------------------------------------
async def test_a_failed_billing_cancellation_is_retried_on_every_confirm(
    app_client, raw_conn, seeded, monkeypatch
):
    """The durable `billing_cancelled_at IS NULL` record needs a remediation
    path, or it is just a permanent alert nobody can clear.

    Gating the side effect on `not already_scheduled` sent every retry down
    the already-scheduled branch: it never re-attempted, and returned
    `billing_cancelled: false` with an EMPTY `warnings` list -- quietly
    downgrading a live billing discrepancy to silence. The gate is now the
    record itself.
    """
    monkeypatch.delenv("STRIPE_API_KEY", raising=False)
    await raw_conn.execute(
        "UPDATE organizations SET stripe_customer_id = 'cus_orphan' WHERE id = %s",
        (seeded["acme"],))
    await raw_conn.commit()
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}

    first = await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert first.json()["billing_cancelled"] is False
    assert first.json()["warnings"]

    retry = await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert retry.status_code == 200
    assert retry.json()["billing_cancelled"] is False
    assert retry.json()["warnings"], (
        "an unresolved billing failure must keep surfacing, not fall silent on retry")

    # ...and once the misconfiguration is fixed, confirming again settles it.
    calls = []

    async def ok(customer_id):
        calls.append(customer_id)

    monkeypatch.setattr("api.routes.deletion.cancel_subscription", ok)
    healed = await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert calls == ["cus_orphan"], "the retry must re-attempt the cancellation"
    assert healed.json()["billing_cancelled"] is True
    assert healed.json()["warnings"] == []
    cur = await raw_conn.execute(
        "SELECT billing_cancelled_at IS NOT NULL, deletion_scheduled_at IS NOT NULL "
        "FROM organizations WHERE id = %s", (seeded["acme"],))
    assert await cur.fetchone() == (True, True)


async def test_a_cancellation_that_cannot_be_recorded_is_surfaced_not_assumed(
    app_client, raw_conn, seeded, monkeypatch
):
    """Review round 2, Minor: the second transaction's UPDATE had no rowcount
    check, so a zero-row match returned `billing_cancelled: true` over a NULL
    column -- a discrepancy only Task 12's alert would ever notice.

    Zero rows is reachable: `org_update` admits only owners, and the caller
    can stop being one between the schedule commit and the record write. Here
    the caller's membership disappears while Stripe is being called. The
    cancellation really did happen, so the response must not claim otherwise
    -- but it must say the record is missing.
    """
    boss = await make_user(raw_conn, "boss@acme.example.com")
    await add_member(raw_conn, boss, seeded["acme"], "owner")
    await raw_conn.execute(
        "UPDATE organizations SET stripe_customer_id = 'cus_x' WHERE id = %s",
        (seeded["acme"],))
    await raw_conn.commit()

    async def cancel_and_unseat_the_caller(customer_id):
        await raw_conn.execute(
            "DELETE FROM memberships WHERE org_id = %s AND user_id = %s",
            (seeded["acme"], seeded["alice"]))
        await raw_conn.commit()

    monkeypatch.setattr(
        "api.routes.deletion.cancel_subscription", cancel_and_unseat_the_caller)

    r = await app_client.post(
        f"/orgs/{seeded['acme']}/deletion",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"})
    assert r.status_code == 200
    body = r.json()
    assert body["billing_cancelled"] is True, "the cancellation did happen; say so"
    assert any("could not be recorded" in w for w in body["warnings"]), body["warnings"]

    cur = await raw_conn.execute(
        "SELECT billing_cancelled_at, deletion_scheduled_at IS NOT NULL "
        "FROM organizations WHERE id = %s", (seeded["acme"],))
    recorded_at, scheduled = await cur.fetchone()
    assert recorded_at is None and scheduled is True


async def test_a_settled_billing_cancellation_is_not_re_attempted(
    app_client, raw_conn, seeded, monkeypatch
):
    """The re-attempt is gated on the record, so a settled org must not call
    Stripe again on every confirm."""
    calls = []

    async def ok(customer_id):
        calls.append(customer_id)

    monkeypatch.setattr("api.routes.deletion.cancel_subscription", ok)
    await raw_conn.execute(
        "UPDATE organizations SET stripe_customer_id = 'cus_live' WHERE id = %s",
        (seeded["acme"],))
    await raw_conn.commit()
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert calls == ["cus_live"]


# ---------------------------------------------------------------------------
# Guard coverage (review round 1, Important-5)
# ---------------------------------------------------------------------------
async def test_every_org_scoped_table_carries_the_deletion_guard_trigger(raw_conn):
    """Deliberately NOT an allowlist -- the same reasoning as
    `test_every_table_in_public_enables_and_forces_rls` in
    tests/test_rls_cross_org.py.

    Migration 0007 argues that the trigger, not the URL middleware, is the
    real invariant: it fires "regardless of route, role, or SECURITY DEFINER
    indirection". That claim only holds for tables that actually HAVE the
    trigger, and it is three hand-written CREATE TRIGGER statements with
    nothing checking them. A Phase 1b table with an `org_id` and no trigger
    would be silently writable on an org scheduled for deletion, with nothing
    failing anywhere to say so.

    So this derives the expected set from the catalog instead: every ordinary
    table in `public` carrying an `org_id` column must have a row-level BEFORE
    INSERT OR UPDATE trigger running `reject_write_to_scheduled_org`.
    `organizations` is correctly absent -- it keys on `id`, and
    scheduling/cancelling are updates to it.
    """
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT c.relname FROM pg_class c "
        "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'org_id' "
        "                   AND a.attnum > 0 AND NOT a.attisdropped "
        "WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')"
    )
    org_scoped = {r[0] for r in await cur.fetchall()}
    assert org_scoped, "sanity: some table in public must carry an org_id"

    # tgtype bits: 1 = ROW, 2 = BEFORE, 4 = INSERT, 16 = UPDATE.
    cur = await raw_conn.execute(
        "SELECT c.relname FROM pg_trigger t "
        "JOIN pg_class c ON c.oid = t.tgrelid "
        "JOIN pg_proc  p ON p.oid = t.tgfoid "
        "WHERE NOT t.tgisinternal AND p.proname = 'reject_write_to_scheduled_org' "
        "  AND (t.tgtype & 1) <> 0 AND (t.tgtype & 2) <> 0 "
        "  AND (t.tgtype & 4) <> 0 AND (t.tgtype & 16) <> 0"
    )
    guarded = {r[0] for r in await cur.fetchall()}

    assert guarded == org_scoped, (
        f"unguarded org-scoped tables: {sorted(org_scoped - guarded)}; "
        f"guarded non-org tables: {sorted(guarded - org_scoped)}. Every table in "
        "`public` with an org_id must carry a BEFORE INSERT OR UPDATE row trigger "
        "running reject_write_to_scheduled_org(), or writes to an organization "
        "scheduled for deletion succeed through any path the URL middleware "
        "cannot see (POST /invites/accept is one; a future POST /sync is another)."
    )


async def test_multi_org_deletions_do_not_deadlock(pool, raw_conn, seeded):
    """Two callers deleting their accounts out of the SAME two orgs. Locking
    several orgs at once is a deadlock risk unless every acquirer agrees on an
    order; _lock_caller_orgs and purge_scheduled_orgs both use ORDER BY
    org_id, so neither can hold one org while waiting on another."""
    from api.routes import deletion as D
    o1 = await make_org(raw_conn, "One")
    o2 = await make_org(raw_conn, "Two")
    keeper = await make_user(raw_conn, "keeper@x.example.com")
    u1 = await make_user(raw_conn, "u1@x.example.com")
    u2 = await make_user(raw_conn, "u2@x.example.com")
    for o in (o1, o2):
        await add_member(raw_conn, keeper, o, "owner")
        await add_member(raw_conn, u1, o, "manager")
        await add_member(raw_conn, u2, o, "manager")
    await raw_conn.commit()

    async def run(uid):
        async with tenant_connection(pool, {"sub": str(uid)}) as conn:
            orgs = await D._lock_caller_orgs(conn, str(uid))
            await asyncio.sleep(0.15)
            if await D._sole_owner_blocking_orgs(conn, str(uid)):
                return "refused"
            await D._purge_caller_rows(conn, str(uid), orgs)
            return "deleted"

    res = await asyncio.wait_for(asyncio.gather(run(u1), run(u2)), timeout=10)
    assert res == ["deleted", "deleted"], res


@pytest.mark.parametrize("role", ["manager", "bookkeeper"])
async def test_non_owner_roles_locked_out(app_client, raw_conn, seeded, role):
    """Every new org-scoped endpoint is owner-only. Roles are exactly owner,
    manager, bookkeeper."""
    u = await make_user(raw_conn, f"{role}@acme.example.com")
    await add_member(raw_conn, u, seeded["acme"], role)
    await raw_conn.commit()
    h = {"Authorization": f"Bearer {mint(str(u))}"}
    assert (await app_client.get(f"/orgs/{seeded['acme']}/export", headers=h)).status_code == 403
    assert (await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=h)).status_code == 403
    assert (await app_client.delete(f"/orgs/{seeded['acme']}/deletion", headers=h)).status_code == 403


async def test_unauthenticated(app_client, seeded):
    """The middleware runs before authentication, so it must fall through
    rather than answering for an anonymous caller."""
    assert (await app_client.delete("/me")).status_code == 401
    assert (await app_client.post(f"/orgs/{seeded['acme']}/deletion")).status_code == 401
    assert (await app_client.get(f"/orgs/{seeded['acme']}/export")).status_code == 401


async def test_future_scheduled_at_is_not_purged(raw_conn, seeded):
    """Clock skew must never shorten the grace window."""
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() + interval '5 days' WHERE id=%s",
        (seeded["acme"],))
    cur = await raw_conn.execute("SELECT purge_scheduled_orgs(interval '30 days')")
    assert (await cur.fetchone())[0] == 0


async def test_locations_write_blocked(pool, raw_conn, seeded):
    """Pins the migration's future-proofing claim directly at the database.
    No /locations route exists yet, so this is reachable only through raw SQL
    on a tenant connection -- which is exactly the point: the trigger, not the
    URL middleware, is what a future POST /sync will be relying on."""
    import psycopg
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() WHERE id=%s", (seeded["acme"],))
    await raw_conn.commit()
    async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
        with pytest.raises(psycopg.Error) as e:
            await conn.execute(
                "INSERT INTO locations (org_id, name) VALUES (%s, 'zombie')", (seeded["acme"],))
        assert e.value.sqlstate == "CS410"
