// shared/kernel.js
// The CostSauce costing kernel, JavaScript implementation. ES module, zero
// dependencies, Node >= 18 or any modern browser.
//
// Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md
// §8-§10, pinned by shared/golden-vectors.json (also run by the Python
// kernel). All decimals cross this API as STRINGS; internals are BigInt
// rationals. Rounding is half-away-from-zero everywhere.

export class KernelError extends Error {}

// ---- rational plumbing ----------------------------------------------------
function parseDec(s) {
  const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(String(s).trim());
  if (!m) throw new KernelError(`not a decimal: ${s}`);
  const [, sign, ip, fp = ""] = m;
  const n = BigInt(ip + fp) * (sign === "-" ? -1n : 1n);
  return { n, d: 10n ** BigInt(fp.length) };
}
const ratMul = (a, b) => ({ n: a.n * b.n, d: a.d * b.d });
function ratDiv(a, b) {
  if (b.n === 0n) throw new KernelError("division by zero");
  let n = a.n * b.d, d = a.d * b.n;
  if (d < 0n) { n = -n; d = -d; }        // keep denominators positive
  return { n, d };
}
const ratAdd = (a, b) => ({ n: a.n * b.d + b.n * a.d, d: a.d * b.d });
const ratSub = (a, b) => ({ n: a.n * b.d - b.n * a.d, d: a.d * b.d });
function ratCmp(a, b) {
  const x = a.n * b.d - b.n * a.d;
  return x < 0n ? -1 : x > 0n ? 1 : 0;
}
const ratPos = (a) => a.n > 0n;

export function roundHalfAway(rat, places) {
  const scale = 10n ** BigInt(places);
  let { n, d } = rat;
  const neg = n < 0n;
  if (neg) n = -n;
  const q = (2n * n * scale + d) / (2n * d);   // floor(x*scale + 0.5)
  const sign = neg && q > 0n ? "-" : "";
  if (places === 0) return sign + q.toString();
  const ip = q / scale, fp = q % scale;
  return `${sign}${ip}.${fp.toString().padStart(places, "0")}`;
}

// ---- names ----------------------------------------------------------------
export function normalizeName(name) {
  let s = String(name).toLowerCase().trim();
  s = s.replace(/[^a-z0-9\s]/g, "");
  s = s.replace(/\s+/g, " ").trim();
  if (s.endsWith("s") && !s.endsWith("ss") && s.length > 3) s = s.slice(0, -1);
  return s;
}

export function matchIngredient(name, candidates) {
  const norm = normalizeName(name);
  if (!norm) return null;
  for (const [id, cname] of candidates)
    if (normalizeName(cname) === norm) return [id, cname, "exact"];
  for (const [id, cname] of candidates) {
    const cn = normalizeName(cname);
    if (cn.includes(norm) || norm.includes(cn)) return [id, cname, "fuzzy"];
  }
  return null;
}

// ---- units & money --------------------------------------------------------
const WEIGHT_TO_LB = {
  lb: parseDec("1"), oz: { n: 1n, d: 16n },
  kg: parseDec("2.2046226218"), g: parseDec("0.0022046226218"),
};
const BASE_UNITS = ["lb", "oz", "kg", "g", "each"];

export function normalizePurchase({ baseUnit, qty, unit, totalPrice, qtyInCase }) {
  const q = parseDec(qty), t = parseDec(totalPrice);
  if (!ratPos(q) || !ratPos(t))
    throw new KernelError("qty and total_price must be positive");
  if (!BASE_UNITS.includes(baseUnit))
    throw new KernelError(`unknown base_unit ${baseUnit}`);
  unit = String(unit || "").trim().toLowerCase();
  let baseQty;
  if (unit === "case") {
    if (qtyInCase == null) throw new KernelError("qty_in_case required");
    const qc = parseDec(qtyInCase);
    if (!ratPos(qc)) throw new KernelError("qty_in_case must be positive");
    baseQty = ratMul(q, qc);
  } else if (baseUnit === "each") {
    if (unit !== "each")
      throw new KernelError("tracked 'each' — use unit 'each' or 'case'");
    baseQty = q;
  } else {
    if (!(unit in WEIGHT_TO_LB))
      throw new KernelError(`unsupported unit ${unit}`);
    baseQty = ratDiv(ratMul(q, WEIGHT_TO_LB[unit]), WEIGHT_TO_LB[baseUnit]);
  }
  const result = roundHalfAway(baseQty, 4);
  if (parseDec(result).n <= 0n)
    throw new KernelError(
      "quantity is too small to register at 4 decimal places");
  return result;
}

export function unitPrice(totalPrice, qtyBaseUnits) {
  const t = parseDec(totalPrice), q = parseDec(qtyBaseUnits);
  if (!ratPos(t) || !ratPos(q))
    throw new KernelError("total_price and qty_base_units must be positive");
  return roundHalfAway(ratDiv(t, q), 6);
}

export function suggestedPriceCents(plateCents, targetBp) {
  if (targetBp <= 0) throw new KernelError("target_bp must be positive");
  if (plateCents < 0) throw new KernelError("plate_cents must be non-negative");
  const num = BigInt(plateCents) * 10000n, den = BigInt(targetBp) * 50n;
  const ceil = (num + den - 1n) / den;
  return Number(ceil * 50n);
}

export function fcStatus(plateCents, menuCents, targetBp) {
  if (menuCents <= 0) throw new KernelError("menu_cents must be positive");
  const fc = roundHalfAway({ n: BigInt(plateCents) * 100n, d: BigInt(menuCents) }, 1);
  const fcR = parseDec(fc), target = { n: BigInt(targetBp), d: 100n };
  let status;
  if (ratCmp(fcR, target) <= 0) status = "ok";
  else if (ratCmp(fcR, ratAdd(target, { n: 2n, d: 1n })) <= 0) status = "watch";
  else status = "danger";
  return { fc, status };
}

// ---- drift ----------------------------------------------------------------
function dayNumber(iso) {
  // days since epoch via integer civil-date math — never Date (spec §4.3;
  // B5 was a Date-object timezone bug).
  const [y, m, d] = iso.split("-").map(Number);
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor(yy / 400);
  const yoe = yy - era * 400;
  const doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}
function dayToIso(z) {
  z += 719468;
  const era = Math.floor(z / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor(
    (doe - Math.floor(doe / 1460) + Math.floor(doe / 36524)
     - Math.floor(doe / 146096)) / 365);
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp + (mp < 10 ? 3 : -9);
  const yy = m <= 2 ? y + 1 : y;
  return `${String(yy).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

export function drift(rows) {
  const live = rows.filter((r) => !r.deleted);
  if (live.length === 0) return null;
  const ordered = [...live].sort((a, b) => {
    if (a.purchased_on !== b.purchased_on)
      return a.purchased_on < b.purchased_on ? 1 : -1;
    if (a.recorded_at !== b.recorded_at)
      return a.recorded_at < b.recorded_at ? 1 : -1;
    return a.id < b.id ? 1 : a.id > b.id ? -1 : 0;
  });
  const latest = ordered[0];
  const windowStartDay = dayNumber(latest.purchased_on) - 90;
  const windowStart = dayToIso(windowStartDay);
  const baseline = ordered.slice(1)
    .filter((r) => dayNumber(r.purchased_on) >= windowStartDay);
  const n = baseline.length;
  const out = { latest_price: latest.unit_price,
                latest_on: latest.purchased_on, window_start: windowStart,
                baseline_n: n, trailing_avg: null, drift_pct: null };
  if (n === 0) return out;
  let sum = { n: 0n, d: 1n };
  for (const r of baseline) sum = ratAdd(sum, parseDec(r.unit_price));
  const avg = ratDiv(sum, { n: BigInt(n), d: 1n });
  out.trailing_avg = roundHalfAway(avg, 6);
  if (n >= 3) {
    const pct = ratMul(ratDiv(ratSub(parseDec(latest.unit_price), avg), avg),
                       { n: 100n, d: 1n });
    out.drift_pct = roundHalfAway(pct, 1);
  }
  return out;
}
