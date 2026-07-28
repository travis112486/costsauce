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
  buildRecipePayload, ratFromString, previewCost, buildSettingsPayload,
  validateRecipeLines, moneyFromCents,
} from "../../web/js/lib.mjs";
import { parseFragment, magicLinkBody, gotrueErrorDetail } from "../../web/js/auth.mjs";
// The B3 pin below imports the JS kernel directly by filesystem path (not
// via lib.mjs, which stays kernel-free -- see lib.mjs's previewCost) to
// exercise the FULL editor preview pipeline: previewCost -> fcStatus /
// suggestedPriceCents, exactly as app.js wires them.
import { fcStatus, suggestedPriceCents } from "../../shared/kernel.js";

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

// ---------------------------------------------------------------------
// buildRecipePayload -- POST/PUT .../recipes body. The item.id round-trip
// (the double-plate-cost bug's client half): create never carries item
// ids; update keeps ids on existing lines, omits them on new lines,
// and a removed line is simply absent from the array.
// ---------------------------------------------------------------------
const ING_A = "018f1e2a-aaaa-7000-8000-000000000001";
const ING_B = "018f1e2a-bbbb-7000-8000-000000000002";
const ITEM_1 = "018f1e2a-1111-7000-8000-0000000000a1";

test("buildRecipePayload: create strips id keys entirely, even if a line carries one", () => {
  const editing = {
    name: "Burger",
    menu_price: "12.50",
    target_fc_pct: "30.0",
    items: [
      { id: ITEM_1, ingredient_id: ING_A, qty_base_units: "2.0000" },
      { id: null, ingredient_id: ING_B, qty_base_units: "1.0000" },
    ],
  };
  const payload = buildRecipePayload(editing, true);
  assert.deepEqual(payload, {
    name: "Burger",
    menu_price: "12.50",
    target_fc_pct: "30.0",
    items: [
      { ingredient_id: ING_A, qty_base_units: "2.0000" },
      { ingredient_id: ING_B, qty_base_units: "1.0000" },
    ],
  });
  payload.items.forEach((it) => assert.equal("id" in it, false));
});

test("buildRecipePayload: update keeps id on existing lines, omits it on new lines", () => {
  const editing = {
    name: "Burger",
    menu_price: "12.50",
    target_fc_pct: "30.0",
    items: [
      { id: ITEM_1, ingredient_id: ING_A, qty_base_units: "3.0000" },
      { id: null, ingredient_id: ING_B, qty_base_units: "1.5000" },
    ],
  };
  const payload = buildRecipePayload(editing, false);
  assert.deepEqual(payload.items, [
    { id: ITEM_1, ingredient_id: ING_A, qty_base_units: "3.0000" },
    { ingredient_id: ING_B, qty_base_units: "1.5000" },
  ]);
  assert.equal("id" in payload.items[1], false);
});

test("buildRecipePayload: update -- a line removed from editing.items is simply absent from the payload", () => {
  // Simulates the user deleting a line in the editor: it's no longer in
  // `editing.items` at all by the time the form submits. The server's
  // contract is to tombstone anything missing from the sent id set --
  // buildRecipePayload's job is only to not silently re-add it.
  const editing = {
    name: "Burger",
    menu_price: "12.50",
    target_fc_pct: "30.0",
    items: [{ id: ITEM_1, ingredient_id: ING_A, qty_base_units: "3.0000" }],
  };
  const payload = buildRecipePayload(editing, false);
  assert.equal(payload.items.length, 1);
  assert.equal(payload.items[0].ingredient_id, ING_A);
});

test("buildRecipePayload: undefined id (never had one) is treated the same as null on update", () => {
  const editing = {
    name: "Burger", menu_price: "12.50", target_fc_pct: "30.0",
    items: [{ ingredient_id: ING_A, qty_base_units: "1.0000" }],
  };
  const payload = buildRecipePayload(editing, false);
  assert.equal("id" in payload.items[0], false);
});

test("buildRecipePayload: scalars pass through as raw input strings, ingredient_id (UUID) untouched", () => {
  const editing = {
    name: "  Burger  ", // NOT trimmed here -- trimming is app.js's job on read
    menu_price: "12.5",
    target_fc_pct: "30",
    items: [{ id: ITEM_1, ingredient_id: ING_A, qty_base_units: "2" }],
  };
  const payload = buildRecipePayload(editing, false);
  assert.equal(payload.name, "  Burger  ");
  assert.equal(payload.menu_price, "12.5");
  assert.equal(payload.target_fc_pct, "30");
  assert.equal(payload.items[0].ingredient_id, ING_A);
  assert.equal(payload.items[0].qty_base_units, "2");
});

// ---------------------------------------------------------------------
// validateRecipeLines -- guards handleRecipeSubmit against silently
// tombstoning an existing line whose qty was blanked out.
// ---------------------------------------------------------------------
test("validateRecipeLines: a blank qty on an EXISTING (id-carrying) line is an error, not a silent drop", () => {
  const lines = [
    { id: ITEM_1, ingredient_id: ING_A, qty_base_units: "" },
  ];
  const result = validateRecipeLines(lines);
  assert.equal(result.ok, false);
  assert.match(result.error, /line 1 has no quantity/);
});

test("validateRecipeLines: whitespace-only qty on an existing line is also blank", () => {
  const lines = [{ id: ITEM_1, ingredient_id: ING_A, qty_base_units: "   " }];
  const result = validateRecipeLines(lines);
  assert.equal(result.ok, false);
});

test("validateRecipeLines: reports the 1-indexed position of the offending line", () => {
  const lines = [
    { id: ITEM_1, ingredient_id: ING_A, qty_base_units: "2.0000" },
    { id: "018f1e2a-1111-7000-8000-0000000000a2", ingredient_id: ING_B, qty_base_units: "" },
  ];
  const result = validateRecipeLines(lines);
  assert.equal(result.ok, false);
  assert.match(result.error, /line 2 has no quantity/);
});

test("validateRecipeLines: an id-less line with BOTH ingredient and qty blank is a never-filled add-row -- silently skipped", () => {
  const lines = [
    { id: ITEM_1, ingredient_id: ING_A, qty_base_units: "2.0000" },
    { id: null, ingredient_id: "", qty_base_units: "" },
  ];
  const result = validateRecipeLines(lines);
  assert.equal(result.ok, true);
  assert.deepEqual(result.lines, [{ id: ITEM_1, ingredient_id: ING_A, qty_base_units: "2.0000" }]);
});

test("validateRecipeLines: an id-less line with an ingredient chosen but a blank qty is still an error (not silently skipped)", () => {
  const lines = [{ id: null, ingredient_id: ING_A, qty_base_units: "" }];
  const result = validateRecipeLines(lines);
  assert.equal(result.ok, false);
  assert.match(result.error, /line 1 has no quantity/);
});

test("validateRecipeLines: all-valid lines pass through unchanged, in order", () => {
  const lines = [
    { id: ITEM_1, ingredient_id: ING_A, qty_base_units: "2.0000" },
    { id: null, ingredient_id: ING_B, qty_base_units: "1.5000" },
  ];
  const result = validateRecipeLines(lines);
  assert.deepEqual(result, { ok: true, lines });
});

test("validateRecipeLines: empty lines array -> ok with nothing kept", () => {
  assert.deepEqual(validateRecipeLines([]), { ok: true, lines: [] });
});

// ---------------------------------------------------------------------
// ratFromString -- exact decimal-string -> {n, d} BigInt rational.
// ---------------------------------------------------------------------
test("ratFromString: parses a plain integer", () => {
  assert.deepEqual(ratFromString("5"), { n: 5n, d: 1n });
});

test("ratFromString: parses a decimal exactly, denominator matches decimal places", () => {
  assert.deepEqual(ratFromString("3.500000"), { n: 3500000n, d: 1000000n });
  assert.deepEqual(ratFromString("0.0001"), { n: 1n, d: 10000n });
});

test("ratFromString: negative values keep the sign on the numerator", () => {
  assert.deepEqual(ratFromString("-3.25"), { n: -325n, d: 100n });
});

test("ratFromString: throws on junk input", () => {
  assert.throws(() => ratFromString("abc"));
  assert.throws(() => ratFromString(""));
  assert.throws(() => ratFromString("1.2.3"));
  assert.throws(() => ratFromString("1,234"));
});

// ---------------------------------------------------------------------
// previewCost -- exact recipe-editor plate-cost preview (the B3-JS fix).
// Sums qty * unit_price as BigInt rationals, rounds to cents exactly once
// at the end; unresolvable lines are excluded and flip `complete` false.
// ---------------------------------------------------------------------
test("previewCost: single fully-priced line, exact cents", () => {
  const lines = [{ ingredient_id: ING_A, qty_base_units: "2.5000" }];
  const priceIndex = { [ING_A]: "3.500000" }; // 2.5 * 3.5 = 8.75 -> 875c
  assert.deepEqual(previewCost(lines, priceIndex), { cents: 875, complete: true });
});

test("previewCost: sums multiple lines exactly", () => {
  const lines = [
    { ingredient_id: ING_A, qty_base_units: "2.5000" },
    { ingredient_id: ING_B, qty_base_units: "1.0000" },
  ];
  const priceIndex = { [ING_A]: "3.500000", [ING_B]: "1.250000" };
  // 8.75 + 1.25 = 10.00 -> 1000c
  assert.deepEqual(previewCost(lines, priceIndex), { cents: 1000, complete: true });
});

test("previewCost: rounds half-away-from-zero at the exact cent boundary", () => {
  const lines = [{ ingredient_id: ING_A, qty_base_units: "1.0000" }];
  const priceIndex = { [ING_A]: "0.125000" }; // 0.125 -> exactly half a cent -> rounds up
  assert.deepEqual(previewCost(lines, priceIndex), { cents: 13, complete: true });
});

test("previewCost: a line with no known price is excluded and flips complete to false", () => {
  const lines = [
    { ingredient_id: ING_A, qty_base_units: "2.0000" },
    { ingredient_id: ING_B, qty_base_units: "1.0000" },
  ];
  const priceIndex = { [ING_A]: "1.000000", [ING_B]: null }; // B unresolvable
  // only A contributes: 2.0 * 1.0 = 2.00 -> 200c
  assert.deepEqual(previewCost(lines, priceIndex), { cents: 200, complete: false });
});

test("previewCost: a line whose ingredient_id is entirely absent from priceIndex is also excluded", () => {
  const lines = [{ ingredient_id: "not-in-index", qty_base_units: "5.0000" }];
  assert.deepEqual(previewCost(lines, {}), { cents: 0, complete: false });
});

test("previewCost: empty lines -> zero cents, complete (nothing to be incomplete about)", () => {
  assert.deepEqual(previewCost([], {}), { cents: 0, complete: true });
});

// ---------------------------------------------------------------------
// B3 pin: previewCost -> shared/kernel.js's fcStatus/suggestedPriceCents,
// the FULL editor preview pipeline, against two vectors ported from
// shared/golden-vectors.json's suggested_price_cents section. The second
// is a boundary case where the legacy float formula
// (product/static/js/app.js:568) gets the wrong answer -- that mismatch
// IS the regression this test guards.
// ---------------------------------------------------------------------
function legacySuggestedCents(plateCents, targetPct) {
  // Ported verbatim from product/static/js/app.js:568, working in the same
  // units the legacy UI used (plate cost and target as JS floats).
  const plateCost = plateCents / 100;
  const suggestedDollars = Math.ceil((plateCost / (targetPct / 100)) * 2) / 2;
  return Math.round(suggestedDollars * 100);
}

test("B3 pin: plate_cents=100, target_bp=2500 -> suggested 400c (plain vector, from golden-vectors.json)", () => {
  const lines = [{ ingredient_id: ING_A, qty_base_units: "1.0000" }];
  const priceIndex = { [ING_A]: "1.000000" }; // -> exactly 100c
  const { cents: plateCents, complete } = previewCost(lines, priceIndex);
  assert.equal(complete, true);
  assert.equal(plateCents, 100);
  assert.equal(suggestedPriceCents(plateCents, 2500), 400);
});

test("B3 pin: plate_cents=210, target_bp=3000 -> suggested 700c exactly, where the legacy float formula gets 750c", () => {
  // From shared/golden-vectors.json's suggested_price_cents section:
  // {plate_cents: 210, target_bp: 3000, expect: 700}. The legacy float
  // path (2.1 / 0.3 in IEEE-754 double) lands on 7.000000000000001,
  // Math.ceil(...*2) overshoots to 15, giving $7.50 (750c) -- fifty cents
  // over the exact answer. This is the B3-JS bug the kernel path closes.
  const lines = [{ ingredient_id: ING_A, qty_base_units: "1.0000" }];
  const priceIndex = { [ING_A]: "2.100000" }; // -> exactly 210c
  const { cents: plateCents, complete } = previewCost(lines, priceIndex);
  assert.equal(complete, true);
  assert.equal(plateCents, 210);

  const exact = suggestedPriceCents(plateCents, 3000);
  assert.equal(exact, 700);

  const legacy = legacySuggestedCents(plateCents, 30);
  assert.equal(legacy, 750);
  assert.notEqual(legacy, exact); // the regression this test pins shut
});

test("B3 pin: previewCost feeds fcStatus correctly too (full pipeline, not just suggested price)", () => {
  const lines = [{ ingredient_id: ING_A, qty_base_units: "1.0000" }];
  const priceIndex = { [ING_A]: "2.100000" }; // plate = 210c
  const { cents: plateCents } = previewCost(lines, priceIndex);
  const { fc, status } = fcStatus(plateCents, 1000, 3000); // menu $10.00, target 30%
  assert.equal(fc, "21.0");
  assert.equal(status, "ok");
});

// ---------------------------------------------------------------------
// moneyFromCents -- exact integer cent count -> "12.34" decimal string.
// Final fix wave, Minor-3: moved from app.js into lib.mjs (pure, DOM-free)
// so it's directly testable under plain node:test.
// ---------------------------------------------------------------------
test("moneyFromCents: positive cents formats dollars.cents", () => {
  assert.equal(moneyFromCents(531), "5.31");
});

test("moneyFromCents: negative cents keeps the sign in front", () => {
  assert.equal(moneyFromCents(-50), "-0.50");
});

test("moneyFromCents: sub-10 cent remainder is zero-padded", () => {
  assert.equal(moneyFromCents(105), "1.05");
});

// ---------------------------------------------------------------------
// buildSettingsPayload -- PATCH /locations/{loc} body. Only changed
// fields are sent; nothing changed -> null (no request at all).
// ---------------------------------------------------------------------
const CURRENT_LOCATION = { name: "The Fictional Diner", target_fc_pct: "30.00", drift_threshold_pct: "15.00" };

test("buildSettingsPayload: nothing changed -> null", () => {
  const form = { ...CURRENT_LOCATION };
  assert.equal(buildSettingsPayload(form, CURRENT_LOCATION), null);
});

test("buildSettingsPayload: only the changed field is sent", () => {
  const form = { ...CURRENT_LOCATION, name: "New Name" };
  assert.deepEqual(buildSettingsPayload(form, CURRENT_LOCATION), { name: "New Name" });
});

test("buildSettingsPayload: multiple changed fields are all sent, unchanged ones omitted", () => {
  const form = { name: "The Fictional Diner", target_fc_pct: "28.00", drift_threshold_pct: "20.00" };
  assert.deepEqual(buildSettingsPayload(form, CURRENT_LOCATION), {
    target_fc_pct: "28.00",
    drift_threshold_pct: "20.00",
  });
});

test("buildSettingsPayload: all fields changed", () => {
  const form = { name: "New Name", target_fc_pct: "28.00", drift_threshold_pct: "20.00" };
  assert.deepEqual(buildSettingsPayload(form, CURRENT_LOCATION), {
    name: "New Name",
    target_fc_pct: "28.00",
    drift_threshold_pct: "20.00",
  });
});
