// tests/js/web-lib.test.mjs
// Run: node --test tests/js/
//
// Pure, DOM-free coverage for web/js/lib.mjs and web/js/auth.mjs::parseFragment
// (the only auth.mjs export that's pure and importable under plain Node --
// requestMagicLink/reviewerLogin/captureTokenFromFragment touch
// window/localStorage/fetch and are exercised by Task 7's scripted smoke
// instead).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  money, pct, signedPct, todayLocalISO, centsFromString, pickDefaultMembership,
  barWidths, sparklinePoints, buildPurchasePayload,
} from "../../web/js/lib.mjs";
import { parseFragment, magicLinkBody, gotrueErrorDetail } from "../../web/js/auth.mjs";

test("money formats a decimal string without re-rounding", () => {
  assert.equal(money("3.31"), "$3.31");
  assert.equal(money("3.3"), "$3.3");
  assert.equal(money("0"), "$0");
});

test("money renders an em dash for missing values", () => {
  assert.equal(money(null), "—");
  assert.equal(money(undefined), "—");
});

test("pct renders an em dash for null, else appends %", () => {
  assert.equal(pct(null), "—");
  assert.equal(pct("14.1"), "14.1%");
  assert.equal(pct("0.0"), "0.0%");
});

test("signedPct prefixes a + for non-negative values, leaves - alone", () => {
  assert.equal(signedPct("14.1"), "+14.1%");
  assert.equal(signedPct("-2.0"), "-2.0%");
  assert.equal(signedPct("0.0"), "+0.0%");
});

test("signedPct renders an em dash for missing values", () => {
  assert.equal(signedPct(null), "—");
  assert.equal(signedPct(undefined), "—");
});

test("todayLocalISO reads local date parts, not toISOString's UTC date (B5)", () => {
  // 2026-07-27 18:00 *local* -- if this were routed through
  // Date#toISOString (UTC) in a timezone west of UTC, the date would roll
  // forward to 2026-07-28. Must stay local.
  assert.equal(todayLocalISO(new Date(2026, 6, 27, 18)), "2026-07-27");
  // And a local midnight-adjacent time, for the opposite direction.
  assert.equal(todayLocalISO(new Date(2026, 0, 1, 0, 30)), "2026-01-01");
});

test("centsFromString is exact via string-split, no float rounding", () => {
  assert.equal(centsFromString("12.34"), 1234);
  assert.equal(centsFromString("0.1"), 10);
  assert.equal(centsFromString("5"), 500);
  assert.equal(centsFromString("-5.00"), -500);
  assert.equal(centsFromString("-0.05"), -5);
});

test("centsFromString throws on more than 2 decimal places", () => {
  assert.throws(() => centsFromString("14.005"));
});

test("centsFromString throws on non-decimal input", () => {
  assert.throws(() => centsFromString("abc"));
  assert.throws(() => centsFromString(""));
});

test("pickDefaultMembership: single membership is the default", () => {
  const membership = { org_id: "a", org_name: "Acme", role: "owner" };
  assert.deepEqual(pickDefaultMembership({ memberships: [membership] }), membership);
});

test("pickDefaultMembership: several memberships means ask (null)", () => {
  const memberships = [
    { org_id: "a", org_name: "Acme", role: "owner" },
    { org_id: "b", org_name: "Beta", role: "manager" },
  ];
  assert.equal(pickDefaultMembership({ memberships }), null);
});

test("pickDefaultMembership: no memberships is also null", () => {
  assert.equal(pickDefaultMembership({ memberships: [] }), null);
});

test("parseFragment extracts access_token from a location.hash-shaped string", () => {
  assert.equal(parseFragment("#access_token=abc&t=x"), "abc");
});

test("parseFragment returns null for an empty fragment", () => {
  assert.equal(parseFragment(""), null);
});

test("parseFragment returns null when access_token is absent", () => {
  assert.equal(parseFragment("#t=x&foo=bar"), null);
});

test("magicLinkBody sends the exact frozen GoTrue OTP shape", () => {
  assert.deepEqual(magicLinkBody("a@b.com", "https://app.costsauce.example"), {
    email: "a@b.com",
    create_user: false,
    options: { email_redirect_to: "https://app.costsauce.example/app/" },
  });
});

test("gotrueErrorDetail prefers msg, then error_description, then error", () => {
  assert.equal(gotrueErrorDetail({ msg: "rate limited" }, 429), "rate limited");
  assert.equal(gotrueErrorDetail({ error_description: "bad email" }, 400), "bad email");
  assert.equal(gotrueErrorDetail({ error: "invalid_request" }, 400), "invalid_request");
});

test("gotrueErrorDetail falls back to a readable string naming the status, never a raw object", () => {
  assert.equal(gotrueErrorDetail({}, 400), "magic link request failed (HTTP 400)");
  assert.equal(gotrueErrorDetail(null, 500), "magic link request failed (HTTP 500)");
});

// ---------------------------------------------------------------------
// barWidths -- dashboard "top movers" bar chart, pixel widths (max 100)
// proportional to |Number(drift_pct)|.
// ---------------------------------------------------------------------
test("barWidths: empty movers list -> empty array", () => {
  assert.deepEqual(barWidths([]), []);
});

test("barWidths: a single element always gets the full 100 width", () => {
  assert.deepEqual(barWidths([{ drift_pct: "5.0" }]), [100]);
  assert.deepEqual(barWidths([{ drift_pct: "-37.25" }]), [100]);
});

test("barWidths: widths are proportional to the largest |drift_pct|", () => {
  const movers = [
    { drift_pct: "10.0" },
    { drift_pct: "5.0" },
    { drift_pct: "2.5" },
  ];
  assert.deepEqual(barWidths(movers), [100, 50, 25]);
});

test("barWidths: negative drift uses its absolute value, sign doesn't affect width", () => {
  const movers = [{ drift_pct: "-20.0" }, { drift_pct: "10.0" }];
  assert.deepEqual(barWidths(movers), [100, 50]);
});

test("barWidths: all-zero drift never divides by zero", () => {
  assert.deepEqual(barWidths([{ drift_pct: "0.0" }, { drift_pct: "0.0" }]), [0, 0]);
});

// ---------------------------------------------------------------------
// sparklinePoints -- ingredient detail price-history chart coordinates.
// Number(unit_price) happens ONLY inside this helper.
// ---------------------------------------------------------------------
test("sparklinePoints: empty purchase list -> empty array", () => {
  assert.deepEqual(sparklinePoints([], 300, 140), []);
});

test("sparklinePoints: a single point centers in both axes", () => {
  assert.deepEqual(sparklinePoints([{ unit_price: "3.31" }], 300, 140), [
    { x: 150, y: 70 },
  ]);
});

test("sparklinePoints: known 3-point ascending series -> exact coords", () => {
  const purchasesAsc = [
    { unit_price: "1.00" },
    { unit_price: "2.00" },
    { unit_price: "3.00" },
  ];
  assert.deepEqual(sparklinePoints(purchasesAsc, 300, 140), [
    { x: 16, y: 124 },
    { x: 150, y: 70 },
    { x: 284, y: 16 },
  ]);
});

test("sparklinePoints: flat series (all equal prices) never divides by zero", () => {
  const purchasesAsc = [
    { unit_price: "4.00" },
    { unit_price: "4.00" },
    { unit_price: "4.00" },
  ];
  assert.deepEqual(sparklinePoints(purchasesAsc, 300, 140), [
    { x: 16, y: 124 },
    { x: 150, y: 124 },
    { x: 284, y: 124 },
  ]);
});

// ---------------------------------------------------------------------
// buildPurchasePayload -- POST /locations/{loc}/purchases body. Strings
// stay strings, no parseFloat, empty qty_in_case is omitted entirely.
// ---------------------------------------------------------------------
test("buildPurchasePayload: full form -> exact payload, values passed through as strings", () => {
  const form = {
    ingredient_id: "018f1e2a-1111-7000-8000-000000000001",
    purchased_on: "2026-07-27",
    qty: "12.5",
    unit: "lb",
    qty_in_case: "24",
    total_price: "45.00",
  };
  assert.deepEqual(buildPurchasePayload(form), {
    ingredient_id: "018f1e2a-1111-7000-8000-000000000001",
    purchased_on: "2026-07-27",
    qty: "12.5",
    unit: "lb",
    qty_in_case: "24",
    total_price: "45.00",
  });
});

test("buildPurchasePayload: empty qty_in_case is stripped, not sent as \"\"", () => {
  const form = {
    ingredient_id: "018f1e2a-1111-7000-8000-000000000001",
    purchased_on: "2026-07-27",
    qty: "3",
    unit: "each",
    qty_in_case: "",
    total_price: "9.99",
  };
  const payload = buildPurchasePayload(form);
  assert.deepEqual(payload, {
    ingredient_id: "018f1e2a-1111-7000-8000-000000000001",
    purchased_on: "2026-07-27",
    qty: "3",
    unit: "each",
    total_price: "9.99",
  });
  assert.equal("qty_in_case" in payload, false);
});

test("buildPurchasePayload: missing qty_in_case field entirely is also omitted", () => {
  const form = {
    ingredient_id: "018f1e2a-1111-7000-8000-000000000001",
    purchased_on: "2026-07-27",
    qty: "3",
    unit: "each",
    total_price: "9.99",
  };
  const payload = buildPurchasePayload(form);
  assert.equal("qty_in_case" in payload, false);
});
