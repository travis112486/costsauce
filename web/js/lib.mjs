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
