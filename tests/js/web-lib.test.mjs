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
