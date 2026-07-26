# tests/test_deletion_services.py
import io
import json
import zipfile
import httpx
import pytest
import stripe
import stripe._http_client as stripe_http_client
from api.services.apple import revoke_apple_token, AppleRevokeError
from api.services.billing import cancel_subscription, BillingError
from api.services.export import build_export, ExportError
from api.db import pool_open, tenant_connection
from tests.factories import make_location, make_org
import api.services.apple as apple_module


async def test_apple_revoke_posts_to_the_documented_endpoint():
    seen = {}

    async def handler(request):
        seen["url"] = str(request.url)
        seen["body"] = request.content.decode()
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        await revoke_apple_token("rt-123", client_id="app.costsauce",
                                 client_secret="secret", http=client)
    assert seen["url"] == "https://appleid.apple.com/auth/revoke"
    assert "token=rt-123" in seen["body"]
    assert "token_type_hint=refresh_token" in seen["body"]


async def test_apple_revoke_raises_on_failure():
    transport = httpx.MockTransport(lambda r: httpx.Response(400, text="invalid_grant"))
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(AppleRevokeError):
            await revoke_apple_token("bad", client_id="c", client_secret="s", http=client)


async def test_export_contains_every_table_as_csv(raw_conn, seeded):
    blob = await build_export(raw_conn, str(seeded["acme"]))
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        names = set(z.namelist())
    assert {"organization.csv", "locations.csv", "members.csv"} <= names
    # Review round 1, Important-1: invites carries org_id (migration 0002,
    # NOT NULL FK to organizations) and is one of the seven TENANT_TABLES --
    # the first version of this file omitted it, which would have silently
    # dropped real org data from every export.
    assert "invites.csv" in names


# ---------------------------------------------------------------------------
# Apple: wire-contract coverage beyond the brief's two given assertions, and
# the owns-a-client-it-creates resource-management branch neither given test
# exercises (both given tests always pass an explicit `http=`).
# ---------------------------------------------------------------------------

async def test_apple_revoke_body_includes_client_credentials():
    """Apple's documented /auth/revoke contract requires client_id and
    client_secret as form fields too, not just token/token_type_hint --
    the brief's given test only checks the latter two."""
    seen = {}

    async def handler(request):
        seen["body"] = request.content.decode()
        seen["content_type"] = request.headers.get("content-type", "")
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        await revoke_apple_token("rt-abc", client_id="app.costsauce",
                                 client_secret="shh", http=client)
    assert "client_id=app.costsauce" in seen["body"]
    assert "client_secret=shh" in seen["body"]
    assert "application/x-www-form-urlencoded" in seen["content_type"]


async def test_apple_revoke_closes_a_client_it_created_itself(monkeypatch):
    """When no http client is injected, revoke_apple_token must own the
    lifecycle of the one it creates -- open it, use it, close it -- rather
    than leaking a client handle on every call."""
    closed = {"value": False}

    async def handler(request):
        return httpx.Response(200)

    owned_client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    real_aclose = owned_client.aclose

    async def tracking_aclose():
        closed["value"] = True
        await real_aclose()

    owned_client.aclose = tracking_aclose
    monkeypatch.setattr(apple_module.httpx, "AsyncClient", lambda *a, **kw: owned_client)

    await revoke_apple_token("rt-xyz", client_id="c", client_secret="s")

    assert closed["value"] is True


async def test_apple_revoke_does_not_close_an_injected_client():
    """The inverse of the above: a caller-supplied client is the caller's
    to close, not this function's."""
    closed = {"value": False}

    async def handler(request):
        return httpx.Response(200)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    real_aclose = client.aclose

    async def tracking_aclose():
        closed["value"] = True
        await real_aclose()

    client.aclose = tracking_aclose

    await revoke_apple_token("rt-1", client_id="c", client_secret="s", http=client)
    assert closed["value"] is False
    await real_aclose()


# ---------------------------------------------------------------------------
# Billing: the brief's own test file has no coverage of cancel_subscription
# at all. Required here to cover the judgement call on the missing-API-key
# path, and to verify the actual wire contract via an injected fake
# transport at the stripe-python HTTP client boundary (not merely mocking
# our own call into the SDK).
# ---------------------------------------------------------------------------

class _FakeStripeHTTPClient(stripe_http_client.HTTPClient):
    """Injected at `stripe.default_http_client`, the real seam stripe-python
    reads at request time (see `_APIRequestor._get_http_client`) -- so this
    exercises the SDK's actual request construction (method, URL, query
    string) rather than only asserting our own code called the SDK."""

    name = "fake-test-transport"

    def __init__(self, handler):
        super().__init__(verify_ssl_certs=False)
        self._handler = handler
        self.calls = []

    def request(self, method, url, headers, post_data=None):
        self.calls.append({"method": method, "url": url, "post_data": post_data})
        return self._handler(method, url, headers, post_data)

    def request_stream(self, method, url, headers, post_data=None):
        raise NotImplementedError("cancel_subscription does not stream")

    def close(self):
        pass


async def test_cancel_subscription_is_a_noop_without_a_customer_id(monkeypatch):
    """organizations.stripe_customer_id does not exist until Task 11, so
    this is the only path every org takes today. Review round 1, Minor:
    the original version of this test had no assertion at all -- its only
    pass criterion was "didn't raise". Install a fake transport that fails
    loudly if touched at all, matching the pattern used two tests below,
    so "no network call was made" is an actual assertion."""
    def handler(method, url, headers, post_data):
        raise AssertionError("must not call Stripe when there is no customer_id")

    fake = _FakeStripeHTTPClient(handler)
    monkeypatch.setattr(stripe, "default_http_client", fake)

    await cancel_subscription(None)

    assert fake.calls == []


async def test_cancel_subscription_raises_when_key_missing_but_customer_present(monkeypatch):
    """Judgement call: a configured customer_id with no STRIPE_API_KEY is a
    deployment misconfiguration, not a no-op. The brief's original code
    swallowed this with a silent `return`, which would let Stripe keep
    billing a customer the deletion flow was about to tell was cancelled.
    Must raise instead, and must not attempt any network call."""
    monkeypatch.delenv("STRIPE_API_KEY", raising=False)

    def handler(method, url, headers, post_data):
        raise AssertionError("must not call Stripe with no API key configured")

    fake = _FakeStripeHTTPClient(handler)
    monkeypatch.setattr(stripe, "default_http_client", fake)

    with pytest.raises(BillingError):
        await cancel_subscription("cus_123")
    assert fake.calls == []


async def test_cancel_subscription_deletes_every_billable_subscription(monkeypatch):
    """Task 11 correction 5: this used to pass `status="active"` to Stripe,
    which silently skipped `trialing`, `past_due` and `paused` subscriptions.
    For a DELETION flow that is a money bug, not a nicety -- a trialing
    subscription converts and starts charging a customer whose organization
    no longer exists. The status filter is gone (Stripe's documented default
    is "everything not canceled") and only genuinely terminal statuses are
    skipped client-side. Fixture data below deliberately mixes statuses so a
    regression back to active-only fails here.
    """
    monkeypatch.setenv("STRIPE_API_KEY", "sk_test_fake")
    deleted = []

    def handler(method, url, headers, post_data):
        if method == "get":
            body = json.dumps({
                "object": "list",
                "data": [
                    {"id": "sub_active", "object": "subscription",
                     "customer": "cus_123", "status": "active"},
                    {"id": "sub_trial", "object": "subscription",
                     "customer": "cus_123", "status": "trialing"},
                    {"id": "sub_pastdue", "object": "subscription",
                     "customer": "cus_123", "status": "past_due"},
                    {"id": "sub_paused", "object": "subscription",
                     "customer": "cus_123", "status": "paused"},
                    {"id": "sub_dead", "object": "subscription",
                     "customer": "cus_123", "status": "incomplete_expired"},
                ],
                "has_more": False,
                "url": "/v1/subscriptions",
            })
            return body, 200, {}
        if method == "delete":
            deleted.append(url.rsplit("/", 1)[1])
            body = json.dumps({"id": url.rsplit("/", 1)[1], "object": "subscription",
                                "status": "canceled"})
            return body, 200, {}
        raise AssertionError(f"unexpected method {method}")

    fake = _FakeStripeHTTPClient(handler)
    monkeypatch.setattr(stripe, "default_http_client", fake)

    await cancel_subscription("cus_123")

    assert fake.calls[0]["method"] == "get"
    assert fake.calls[0]["url"] == "https://api.stripe.com/v1/subscriptions?customer=cus_123"
    assert deleted == ["sub_active", "sub_trial", "sub_pastdue", "sub_paused"], (
        "every subscription that can still bill must be cancelled; a terminal "
        "incomplete_expired one must not be re-deleted"
    )


async def test_cancel_subscription_wraps_stripe_errors(monkeypatch):
    monkeypatch.setenv("STRIPE_API_KEY", "sk_test_fake")

    def handler(method, url, headers, post_data):
        if method == "get":
            body = json.dumps({
                "object": "list",
                "data": [{"id": "sub_1", "object": "subscription",
                          "customer": "cus_123", "status": "active"}],
                "has_more": False,
                "url": "/v1/subscriptions",
            })
            return body, 200, {}
        if method == "delete":
            body = json.dumps({"error": {"type": "invalid_request_error",
                                          "message": "No such subscription: sub_1"}})
            return body, 404, {}
        raise AssertionError(f"unexpected method {method}")

    fake = _FakeStripeHTTPClient(handler)
    monkeypatch.setattr(stripe, "default_http_client", fake)

    with pytest.raises(BillingError):
        await cancel_subscription("cus_123")


# ---------------------------------------------------------------------------
# Export: self-review requirement -- can build_export be made to emit
# another org's rows, or to silently emit an incomplete export that looks
# complete? `raw_conn` connects as the superuser `postgres`, which bypasses
# RLS regardless of FORCE, so these prove the WHERE-clause isolation (and
# the completeness guard) hold on their own, with no RLS backstop at all.
# ---------------------------------------------------------------------------

async def test_export_excludes_other_orgs_rows(raw_conn, seeded):
    await make_location(raw_conn, seeded["bistro"], "Bistro Back Kitchen")
    await raw_conn.commit()

    blob = await build_export(raw_conn, str(seeded["acme"]))
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        locations_csv = z.read("locations.csv").decode()
        members_csv = z.read("members.csv").decode()

    assert "Acme Main" in locations_csv
    assert "Bistro Back Kitchen" not in locations_csv, (
        "TENANCY LEAK: acme's export contained bistro's location"
    )
    assert "alice@acme.test" in members_csv
    assert "bob@bistro.test" not in members_csv, (
        "TENANCY LEAK: acme's export contained bistro's member"
    )


async def test_export_excludes_other_orgs_invites(raw_conn, seeded):
    """Same tenancy-leak check as locations/members, for the table Important-1
    added. Real (non-.test) domains per this plan's global constraint --
    unlike `seeded`'s pre-existing emails, these are new strings I'm
    introducing, inserted directly via SQL so no EmailStr validation
    boundary applies either way."""
    await raw_conn.execute(
        "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at)"
        " VALUES (%s, 'newhire@acme-diner.com', 'manager', 'tok-acme',"
        " %s, now() + interval '7 days')",
        (seeded["acme"], seeded["alice"]),
    )
    await raw_conn.execute(
        "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at)"
        " VALUES (%s, 'newhire@bistro-nine.com', 'manager', 'tok-bistro',"
        " %s, now() + interval '7 days')",
        (seeded["bistro"], seeded["bob"]),
    )
    await raw_conn.commit()

    blob = await build_export(raw_conn, str(seeded["acme"]))
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        invites_csv = z.read("invites.csv").decode()

    assert "newhire@acme-diner.com" in invites_csv
    assert "newhire@bistro-nine.com" not in invites_csv, (
        "TENANCY LEAK: acme's export contained bistro's invite"
    )


async def test_export_raises_when_members_is_unexpectedly_empty(raw_conn, seeded):
    """Important-2: `organization.csv`'s completeness guard was the only
    one -- a bug in the `members.csv` WHERE clause, or (under a
    tenant_connection) an RLS-visible set that shifts mid-export, would
    otherwise still produce a well-formed zip with a silently-empty
    members.csv. That must never happen for an org build_export can already
    see: remove_member/change_role/accept_invite_tx all refuse to let an
    org's owner count reach zero. Simulated directly here with an org that
    has zero memberships (make_org alone, no add_member) -- exactly the bug
    class this guard exists to catch, whether the zero memberships come
    from a real invariant violation or a WHERE-clause defect."""
    lonely_org = await make_org(raw_conn, "Nobody Home")
    await raw_conn.commit()

    with pytest.raises(ExportError):
        await build_export(raw_conn, str(lonely_org))


async def test_export_raises_for_a_nonexistent_org(raw_conn, seeded):
    """A wrong or stale org_id must not produce a well-formed-looking zip
    with an empty organization.csv -- indistinguishable from a complete
    export until a human opens the file. That silent truncation is worse
    than a loud failure the caller can catch and investigate."""
    bogus_org_id = "00000000-0000-0000-0000-000000000000"
    with pytest.raises(ExportError):
        await build_export(raw_conn, bogus_org_id)


async def test_export_works_through_a_tenant_scoped_connection(db_url, seeded):
    """The connection every other route in this codebase actually uses:
    SET LOCAL ROLE authenticated + the caller's own JWT claims. RLS
    restricts organizations/locations/memberships to orgs the caller
    belongs to, on top of build_export's own WHERE org_id = %s -- belt and
    suspenders, for a caller who really is a member of the org exported."""
    app_url = db_url.replace("postgres:postgres", "app_user:app_pw")
    pool = await pool_open(app_url)
    try:
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            blob = await build_export(conn, str(seeded["acme"]))
    finally:
        await pool.close()

    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        names = set(z.namelist())
        org_csv = z.read("organization.csv").decode()
    assert {"organization.csv", "locations.csv", "members.csv"} <= names
    assert str(seeded["acme"]) in org_csv


async def test_export_via_tenant_connection_cannot_reach_another_org(db_url, seeded):
    """Same tenant-scoped connection as above, but Alice (an acme owner,
    with no membership in bistro) asking for bistro's export. RLS must
    empty out organizations/locations/memberships before build_export's own
    WHERE clause even runs, so this must raise ExportError (organization
    row not visible), never return bistro's data."""
    app_url = db_url.replace("postgres:postgres", "app_user:app_pw")
    pool = await pool_open(app_url)
    try:
        async with tenant_connection(pool, {"sub": str(seeded["alice"])}) as conn:
            with pytest.raises(ExportError):
                await build_export(conn, str(seeded["bistro"]))
    finally:
        await pool.close()
