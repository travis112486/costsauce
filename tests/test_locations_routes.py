# tests/test_locations_routes.py
from tests.factories import add_member
from tests.test_ingredients_routes import auth


async def test_list_locations_returns_acme_locations(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.get(f"/orgs/{s['acme']}/locations", headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body) == 1
    loc = body[0]
    assert loc["id"] == str(s["acme_loc"])
    assert loc["name"] == "Acme Main"
    assert loc["target_fc_pct"] == "30.00"
    assert loc["drift_threshold_pct"] == "5.00"


async def test_list_locations_bob_is_404(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.get(f"/orgs/{s['acme']}/locations", headers=auth(s["bob"]))
    assert r.status_code == 404


async def test_list_locations_unknown_org_is_404(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.get(
        "/orgs/00000000-0000-0000-0000-000000000000/locations",
        headers=auth(s["alice"]))
    assert r.status_code == 404


async def test_list_locations_unauthenticated_is_401(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.get(f"/orgs/{s['acme']}/locations")
    assert r.status_code == 401


async def test_patch_by_owner_updates_all_fields(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.patch(
        f"/locations/{s['acme_loc']}",
        json={"name": "Acme Downtown", "target_fc_pct": "28.50",
              "drift_threshold_pct": "7.25"},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["id"] == str(s["acme_loc"])
    assert body["name"] == "Acme Downtown"
    assert body["target_fc_pct"] == "28.50"
    assert body["drift_threshold_pct"] == "7.25"

    r2 = await app_client.get(f"/orgs/{s['acme']}/locations", headers=auth(s["alice"]))
    loc = r2.json()[0]
    assert loc["name"] == "Acme Downtown"
    assert loc["target_fc_pct"] == "28.50"
    assert loc["drift_threshold_pct"] == "7.25"


async def test_patch_by_bookkeeper_is_403(app_client, seeded_biz, raw_conn):
    s = seeded_biz
    carol = None
    from tests.factories import make_user
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, s["acme"], "bookkeeper")
    await raw_conn.commit()
    r = await app_client.patch(
        f"/locations/{s['acme_loc']}", json={"name": "Nope"}, headers=auth(carol))
    assert r.status_code == 403


async def test_patch_empty_body_is_422(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.patch(
        f"/locations/{s['acme_loc']}", json={}, headers=auth(s["alice"]))
    assert r.status_code == 422


async def test_patch_zero_target_fc_pct_is_422(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.patch(
        f"/locations/{s['acme_loc']}", json={"target_fc_pct": "0"},
        headers=auth(s["alice"]))
    assert r.status_code == 422


async def test_patch_cross_org_is_404(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.patch(
        f"/locations/{s['bistro_loc']}", json={"name": "Hostile Takeover"},
        headers=auth(s["alice"]))
    assert r.status_code == 404


async def test_patch_reflected_in_dashboard(app_client, seeded_biz):
    s = seeded_biz
    r = await app_client.patch(
        f"/locations/{s['acme_loc']}", json={"drift_threshold_pct": "9.00"},
        headers=auth(s["alice"]))
    assert r.status_code == 200, r.text
    r2 = await app_client.get(f"/locations/{s['acme_loc']}/dashboard",
                              headers=auth(s["alice"]))
    assert r2.status_code == 200, r2.text
    assert r2.json()["location"]["drift_threshold_pct"] == "9.00"
