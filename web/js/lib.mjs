// web/js/lib.mjs
// Pure, framework-free helpers shared across DOM views. No window,
// document, or localStorage reference anywhere in this file -- ever --
// because tests/js/web-lib.test.mjs imports it by filesystem path under
// plain `node --test`, where none of those globals (and no /shared/...
// or /app/... URL) resolve. DOM-touching code belongs in app.js instead.

// money("3.31") -> "$3.31". The input is already a formatted decimal
// string (typically straight off the wire from the API), so this never
// re-rounds or reformats digits -- it just prefixes the currency sign.
export function money(s) {
  if (s === null || s === undefined) return "—";
  return "$" + s;
}

// pct("14.1") -> "14.1%". Same no-reformatting contract as money().
export function pct(s) {
  if (s === null || s === undefined) return "—";
  return s + "%";
}

// signedPct("14.1") -> "+14.1%"; signedPct("-2.0") -> "-2.0%". A leading
// "-" in the input is left alone (it's already the sign); everything else
// gets an explicit "+" so drift direction reads at a glance.
export function signedPct(s) {
  if (s === null || s === undefined) return "—";
  const str = String(s);
  const sign = str.startsWith("-") ? "" : "+";
  return sign + str + "%";
}

// todayLocalISO(now = new Date()) -> local "YYYY-MM-DD".
//
// Deliberately built from getFullYear/getMonth/getDate (local time), NOT
// now.toISOString().slice(0, 10) (UTC). The legacy product/static/js/app.js
// todayISO() used toISOString(), which rolls the date forward for anyone
// west of UTC in the evening -- e.g. 2026-07-27 18:00 local in US timezones
// is already 2026-07-28 in UTC. That's the B5 bug this function fixes.
export function todayLocalISO(now = new Date()) {
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

// centsFromString("12.34") -> 1234. Exact via string-split -- never
// Number(s) * 100, which is subject to float error (e.g. 0.1 + 0.2). At
// most 2 decimal places are accepted; anything finer (e.g. "14.005")
// throws rather than silently truncating or rounding. Negatives are
// allowed (refunds/corrections).
export function centsFromString(s) {
  const str = String(s).trim();
  const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(str);
  if (!m) throw new Error(`not a decimal string: ${JSON.stringify(s)}`);
  const [, sign, ip, fp = ""] = m;
  if (fp.length > 2)
    throw new Error(`more than 2 decimal places: ${JSON.stringify(s)}`);
  const cents = Number(ip) * 100 + Number(fp.padEnd(2, "0"));
  return sign === "-" ? -cents : cents;
}

// pickDefaultMembership(me) -> the one membership to preselect, or null
// meaning "ask the user". Exactly one membership is the only case that can
// be resolved without a choice; zero (not provisioned into any org yet)
// and several (ambiguous) both mean null.
export function pickDefaultMembership(me) {
  const memberships = (me && me.memberships) || [];
  if (memberships.length === 1) return memberships[0];
  return null;
}

// barWidths(movers) -> pixel widths (0-100), one per mover, proportional to
// |Number(m.drift_pct)|. The mover with the largest absolute drift always
// gets exactly 100; everything else is scaled relative to it. These are
// literal pixel widths for a small fixed-scale bar (not a percentage of the
// track's flexible width) -- app.js applies them directly as `width:${w}px`.
// Sign is irrelevant to width (direction is rendered separately via
// m.direction); an all-zero set never divides by zero.
export function barWidths(movers) {
  if (!movers || movers.length === 0) return [];
  const abs = movers.map((m) => Math.abs(Number(m.drift_pct)));
  const max = Math.max(...abs);
  if (max === 0) return abs.map(() => 0);
  return abs.map((a) => (a / max) * 100);
}

// sparklinePoints(purchasesAsc, w, h) -> [{x, y}, ...] plot coordinates for
// the ingredient-detail price sparkline, one per purchase, oldest first.
// Number(unit_price) happens ONLY in here -- callers pass the raw
// {unit_price: "3.31", ...} purchase rows straight off the wire.
//
// - Empty input -> [].
// - A single point can't be plotted against a range, so it centers in both
//   axes instead of collapsing to a corner.
// - Otherwise x walks left-to-right across [pad, w-pad] and y maps
//   min..max price onto [h-pad, pad] (higher price -> higher up the
//   canvas), matching the legacy product/static/js/app.js drawSparkline
//   layout. A flat series (min === max) maps every y to the vertical
//   center of that band rather than dividing by zero.
export function sparklinePoints(purchasesAsc, w, h) {
  if (!purchasesAsc || purchasesAsc.length === 0) return [];
  const n = purchasesAsc.length;
  if (n === 1) return [{ x: w / 2, y: h / 2 }];

  const prices = purchasesAsc.map((p) => Number(p.unit_price));
  const min = Math.min(...prices);
  const max = Math.max(...prices);
  const range = max - min || 1;
  const pad = 16;

  return prices.map((price, idx) => {
    const x = pad + (idx / (n - 1)) * (w - pad * 2);
    const y = h - pad - ((price - min) / range) * (h - pad * 2);
    return { x, y };
  });
}

// buildPurchasePayload(form) -> the exact POST /locations/{loc}/purchases
// body. `form` carries raw string field values (straight off DOM inputs in
// app.js, or a plain object in tests) -- every value is passed through
// as-is, never parseFloat'd (the server's Decimal fields own precision).
// qty_in_case is optional on the wire; an empty/absent value is omitted
// entirely rather than sent as "".
export function buildPurchasePayload(form) {
  const payload = {
    ingredient_id: form.ingredient_id,
    purchased_on: form.purchased_on,
    qty: form.qty,
    unit: form.unit,
    total_price: form.total_price,
  };
  const qtyInCase = form.qty_in_case;
  if (qtyInCase !== undefined && qtyInCase !== null && String(qtyInCase).trim() !== "") {
    payload.qty_in_case = qtyInCase;
  }
  return payload;
}

// ---------------------------------------------------------------------
// recipes -- editor payload (the item.id round-trip / B-fix) + exact live
// preview (the B3-JS fix). See tests/js/web-lib.test.mjs for the golden-
// vector pin against shared/kernel.js.
// ---------------------------------------------------------------------

// buildRecipePayload(editing, isCreate) -> the exact POST/PUT
// .../recipes body. `editing` is the editor's in-memory state: { name,
// menu_price, target_fc_pct, items: [{id, ingredient_id, qty_base_units},
// ...] }, where a line's `id` is the recipe_items row id for an existing
// line (read straight off the costed payload's items[].id and carried
// through every re-render) or null/undefined for a line added in this
// editing session.
//
// On create, the server 422s if ANY item carries an `id` at all, so every
// id key is stripped outright regardless of what's on the line. On
// update, existing lines keep their id (so the server updates that row in
// place); new lines omit the key entirely (so the server inserts); a line
// the user removed is simply absent from `editing.items` -- the server
// tombstones anything missing from the sent id set. This is the client
// half of the double-plate-cost bug: the legacy editor
// (product/static/js/app.js:469) rebuilt its rows from `{ingredient_id,
// qty_base_units}` only, silently dropping `id` on every edit, so a save
// re-inserted every line instead of updating in place.
//
// All scalar values (name/menu_price/target_fc_pct/qty_base_units) pass
// through as the raw input strings -- never parseFloat'd -- and
// ingredient_id (a UUID string) is never touched.
export function buildRecipePayload(editing, isCreate) {
  const items = (editing.items || []).map((it) => {
    const line = { ingredient_id: it.ingredient_id, qty_base_units: it.qty_base_units };
    if (!isCreate && it.id !== null && it.id !== undefined) {
      line.id = it.id;
    }
    return line;
  });
  return {
    name: editing.name,
    menu_price: editing.menu_price,
    target_fc_pct: editing.target_fc_pct,
    items,
  };
}

// validateRecipeLines(lines) -> {ok: true, lines: kept} | {ok: false, error}.
// Guards the recipe editor submit path against silently tombstoning an
// existing line whose quantity field was blanked out. The prior filter
// (`items.filter(it => it.ingredient_id && qty !== "")`) dropped ANY line
// with a blank qty, existing or new alike -- for an existing line that
// means it simply vanishes from the payload, and the server (which diffs
// by id) tombstones it as if the user had explicitly removed it, with no
// error surfaced at all.
//
// The rule: a line that carries an `id` (an existing recipe_items row)
// MUST have a non-blank qty -- a blank qty on an existing line is always
// an error, never a silent drop. A line with no `id` (added this editing
// session) whose ingredient AND qty are BOTH blank is a never-filled
// "+ Add ingredient" row -- the one case that's silently skipped. Any
// other id-less combination (e.g. an ingredient chosen but no qty typed
// yet) is also an error, not a silent drop, since it's ambiguous whether
// the user meant to abandon the row or just hasn't finished it.
export function validateRecipeLines(lines) {
  const kept = [];
  const list = lines || [];
  for (let i = 0; i < list.length; i++) {
    const line = list[i];
    const hasId = line.id !== null && line.id !== undefined;
    const qtyBlank = line.qty_base_units === null || line.qty_base_units === undefined
      || String(line.qty_base_units).trim() === "";
    const ingredientBlank = !line.ingredient_id;

    if (!hasId && ingredientBlank && qtyBlank) {
      continue; // never-filled add-row -- silently skipped
    }
    if (qtyBlank) {
      return { ok: false, error: `line ${i + 1} has no quantity — remove the line explicitly or enter a quantity` };
    }
    kept.push(line);
  }
  return { ok: true, lines: kept };
}

// ratFromString(s) -> {n: BigInt, d: BigInt}, the exact rational a decimal
// string represents. Mirrors shared/kernel.js's internal parseDec,
// deliberately duplicated rather than imported -- lib.mjs stays a
// standalone module with zero imports (see file header), and this is the
// one place besides centsFromString that needs exact decimal parsing.
// Throws on anything that isn't an optionally-signed plain decimal (empty
// string, "abc", "1.2.3", ...).
export function ratFromString(s) {
  const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(String(s).trim());
  if (!m) throw new Error(`not a decimal string: ${JSON.stringify(s)}`);
  const [, sign, ip, fp = ""] = m;
  const n = BigInt(ip + fp) * (sign === "-" ? -1n : 1n);
  const d = 10n ** BigInt(fp.length);
  return { n, d };
}

function ratMul(a, b) {
  return { n: a.n * b.n, d: a.d * b.d };
}

function ratAdd(a, b) {
  return { n: a.n * b.d + b.n * a.d, d: a.d * b.d };
}

// centsFromRat(rat) -> the dollar rational `rat` rounded half-away-from-
// zero to the nearest cent, as an integer. Bit-for-bit the same rounding
// shared/kernel.js's roundHalfAway(rat, 2) performs (its `q` before the
// ip/fp string split IS the cent count) -- reimplemented locally rather
// than imported, for the same standalone-module reason as ratFromString.
function centsFromRat(rat) {
  let { n, d } = rat;
  const neg = n < 0n;
  if (neg) n = -n;
  const scale = 100n;
  const q = (2n * n * scale + d) / (2n * d);
  return neg ? -Number(q) : Number(q);
}

// previewCost(lines, priceIndex) -> {cents, complete}, the recipe editor's
// live plate-cost preview. `lines` are the editor's current
// {ingredient_id, qty_base_units} rows (qty as the raw input string);
// `priceIndex` maps ingredient_id -> unit_price string (or null/undefined
// for an ingredient with no resolvable price).
//
// This is the B3-JS fix: the legacy preview
// (product/static/js/app.js:563,568) accumulated `plateCost += latest_price
// * qty_base_units` in plain floats and derived the suggested price via
// `Math.ceil((plateCost / (target/100)) * 2) / 2`, which can disagree with
// the server's exact BigInt-rational kernel at the boundary. Here every
// line's contribution is computed as an exact BigInt rational
// (qty * unit_price), summed exactly, and rounded to cents exactly once at
// the very end -- feed that cents value straight into shared/kernel.js's
// fcStatus/suggestedPriceCents and the preview matches the server exactly.
//
// A line with no known price is EXCLUDED from the sum (never contributes
// NaN) and flips `complete` to false so the caller can show "preview
// incomplete" instead of a misleadingly-precise total.
export function previewCost(lines, priceIndex) {
  let sum = { n: 0n, d: 1n };
  let complete = true;
  for (const line of lines || []) {
    const price = priceIndex ? priceIndex[line.ingredient_id] : undefined;
    if (price === null || price === undefined) {
      complete = false;
      continue;
    }
    const qty = ratFromString(line.qty_base_units);
    const unitPrice = ratFromString(price);
    sum = ratAdd(sum, ratMul(qty, unitPrice));
  }
  return { cents: centsFromRat(sum), complete };
}

// moneyFromCents(cents) -> "12.34" from an EXACT integer cent count (as
// returned by shared/kernel.js's suggestedPriceCents, or by this module's
// own previewCost). Pure integer arithmetic (Math.floor/% on an
// already-integer Number) -- never float division of the kind that would
// re-introduce the B3 bug this module exists to close. Pairs with
// money(moneyFromCents(cents)) for display.
export function moneyFromCents(cents) {
  const neg = cents < 0;
  const abs = Math.abs(cents);
  const dollars = Math.floor(abs / 100);
  const rem = abs % 100;
  return (neg ? "-" : "") + dollars + "." + String(rem).padStart(2, "0");
}

// buildSettingsPayload(form, current) -> the exact PATCH /locations/{loc}
// body, or null when nothing changed. `form` carries the settings form's
// current (string) field values; `current` is the location row the form
// was seeded from (also strings, straight off the API). Only fields that
// differ from `current` are sent -- the server rejects an explicit null
// with a 422 (a field it doesn't know changed must simply be absent, not
// null), and re-sending unchanged values is a needless write. Comparison
// is plain string equality; nothing here is parsed as a number.
export function buildSettingsPayload(form, current) {
  const payload = {};
  if (form.name !== undefined && form.name !== current.name) {
    payload.name = form.name;
  }
  if (form.target_fc_pct !== undefined && form.target_fc_pct !== current.target_fc_pct) {
    payload.target_fc_pct = form.target_fc_pct;
  }
  if (form.drift_threshold_pct !== undefined && form.drift_threshold_pct !== current.drift_threshold_pct) {
    payload.drift_threshold_pct = form.drift_threshold_pct;
  }
  return Object.keys(payload).length === 0 ? null : payload;
}
