// The CostSauce costing kernel, Swift implementation — rounding, names,
// units, and money.
//
// Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md
// §8-§10, pinned by shared/golden-vectors.json (also run by the Python and
// JavaScript kernels), compared as EXACT strings, zero tolerance. All
// decimals cross this API as STRINGS; internals are Int128 rationals
// (see Rational.swift). Rounding is half-away-from-zero everywhere.
//
// Function-for-function port of shared/kernel.js:35-128 (kernel.js is the
// reference implementation; line numbers below refer to it).

import Foundation

public enum Kernel {

    // MARK: - Rounding

    /// Round-half-away-from-zero at `places` decimals, formatted as a
    /// zero-padded decimal string. `q = floor((2n*10^places + d) / (2d))`
    /// on `|n|`; sign is re-applied unless `q == 0`. Port of kernel.js:35-45.
    public static func roundHalfAway(_ r: Rational, places: Int) -> String {
        let scale = Rational.pow10(places)
        var n = r.n
        let d = r.d
        let neg = n < 0
        if neg { n = -n }
        let q = (2 * n * scale + d) / (2 * d)
        let sign = (neg && q > 0) ? "-" : ""
        if places == 0 {
            return sign + String(q)
        }
        let ip = q / scale
        let fp = q % scale
        var fpString = String(fp)
        while fpString.count < places {
            fpString = "0" + fpString
        }
        return "\(sign)\(ip).\(fpString)"
    }

    // MARK: - Names

    /// lowercase → trim → drop non `[a-z0-9\s]` → collapse whitespace →
    /// strip a trailing "s" unless the word ends "ss" or is length ≤ 3.
    /// Port of kernel.js:48-54.
    public static func normalizeName(_ name: String) -> String {
        var s = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacing(/[^a-z0-9\s]/, with: "")
        s = s.replacing(/\s+/, with: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("s") && !s.hasSuffix("ss") && s.count > 3 {
            s.removeLast()
        }
        return s
    }

    public struct Candidate: Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public enum MatchType: String {
        case exact, fuzzy
    }

    public struct Match {
        public let id: String
        public let name: String
        public let type: MatchType
    }

    /// Two passes in candidate order: exact normalized equality first, then
    /// bidirectional containment. Port of kernel.js:56-66.
    public static func matchIngredient(name: String, candidates: [Candidate]) -> Match? {
        let norm = normalizeName(name)
        if norm.isEmpty { return nil }
        for c in candidates where normalizeName(c.name) == norm {
            return Match(id: c.id, name: c.name, type: .exact)
        }
        for c in candidates {
            let cn = normalizeName(c.name)
            if cn.contains(norm) || norm.contains(cn) {
                return Match(id: c.id, name: c.name, type: .fuzzy)
            }
        }
        return nil
    }

    /// Mirrors api/routes/ingredients.py:63-65: candidates (already in
    /// (created_at, id) order) where the normalized query is a substring of
    /// the candidate's normalized name or vice versa, first 3; empty when
    /// the normalized query is empty.
    public static func nearMatches(name: String, candidates: [Candidate]) -> [Candidate] {
        let norm = normalizeName(name)
        if norm.isEmpty { return [] }
        var out: [Candidate] = []
        for c in candidates {
            let cn = normalizeName(c.name)
            if norm.contains(cn) || cn.contains(norm) {
                out.append(c)
                if out.count == 3 { break }
            }
        }
        return out
    }

    // MARK: - Units & money

    /// Exact-rational conversion factors to lb. Mirrors kernel.js:69-72's
    /// WEIGHT_TO_LB (computed there via parseDec at module load).
    private static let weightToLb: [String: Rational] = [
        "lb": Rational(n: 1, d: 1),
        "oz": Rational(n: 1, d: 16),
        "kg": Rational(n: 22_046_226_218, d: 10_000_000_000),
        "g": Rational(n: 22_046_226_218, d: 10_000_000_000_000),
    ]
    private static let baseUnits: Set<String> = ["lb", "oz", "kg", "g", "each"]

    /// qty entered in `unit` → quantity in the ingredient's `baseUnit`,
    /// rounded half-away-from-zero to 4dp. Exact port of kernel.js:75-102,
    /// including error message strings.
    public static func normalizePurchase(
        baseUnit: String, qty: String, unit: String,
        totalPrice: String, qtyInCase: String?
    ) throws -> String {
        let q = try Rational.parseDec(qty)
        let t = try Rational.parseDec(totalPrice)
        if !q.isPositive || !t.isPositive {
            throw KernelError("qty and total_price must be positive")
        }
        if !baseUnits.contains(baseUnit) {
            throw KernelError("unknown base_unit \(baseUnit)")
        }
        let normUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseQty: Rational
        if normUnit == "case" {
            guard let qtyInCase else {
                throw KernelError("qty_in_case required")
            }
            let qc = try Rational.parseDec(qtyInCase)
            if !qc.isPositive {
                throw KernelError("qty_in_case must be positive")
            }
            baseQty = q.mul(qc)
        } else if baseUnit == "each" {
            if normUnit != "each" {
                throw KernelError("tracked 'each' — use unit 'each' or 'case'")
            }
            baseQty = q
        } else {
            guard let unitRat = weightToLb[normUnit] else {
                throw KernelError("unsupported unit \(normUnit)")
            }
            guard let baseRat = weightToLb[baseUnit] else {
                throw KernelError("unknown base_unit \(baseUnit)")
            }
            baseQty = try q.mul(unitRat).div(baseRat)
        }
        let result = roundHalfAway(baseQty, places: 4)
        let resultRat = try Rational.parseDec(result)
        if resultRat.n <= 0 {
            throw KernelError("quantity is too small to register at 4 decimal places")
        }
        return result
    }

    /// Mirror of the DB generated column: round(total/qty, 6). Port of
    /// kernel.js:104-109.
    public static func unitPrice(totalPrice: String, qtyBaseUnits: String) throws -> String {
        let t = try Rational.parseDec(totalPrice)
        let q = try Rational.parseDec(qtyBaseUnits)
        if !t.isPositive || !q.isPositive {
            throw KernelError("total_price and qty_base_units must be positive")
        }
        return roundHalfAway(try t.div(q), places: 6)
    }

    /// `ceil(plate·10000 / (targetBp·50)) · 50` via integer math. Port of
    /// kernel.js:111-117.
    public static func suggestedPriceCents(plateCents: Int, targetBp: Int) throws -> Int {
        if targetBp <= 0 {
            throw KernelError("target_bp must be positive")
        }
        if plateCents < 0 {
            throw KernelError("plate_cents must be non-negative")
        }
        let num = Int128(plateCents) * 10000
        let den = Int128(targetBp) * 50
        let ceil = (num + den - 1) / den
        return Int(ceil * 50)
    }

    /// `fc = roundHalfAway(plate·100/menu, 1)`; status compares the ROUNDED
    /// value against `targetBp` (≤target "ok", ≤target+2 "watch", else
    /// "danger" — B4). Port of kernel.js:119-128.
    public static func fcStatus(
        plateCents: Int, menuCents: Int, targetBp: Int
    ) throws -> (fc: String, status: String) {
        if menuCents <= 0 {
            throw KernelError("menu_cents must be positive")
        }
        let plateRat = Rational(n: Int128(plateCents) * 100, d: Int128(menuCents))
        let fc = roundHalfAway(plateRat, places: 1)
        let fcR = try Rational.parseDec(fc)
        let target = Rational(n: Int128(targetBp), d: 100)
        let status: String
        if fcR.cmp(target) <= 0 {
            status = "ok"
        } else if fcR.cmp(target.add(Rational(n: 2, d: 1))) <= 0 {
            status = "watch"
        } else {
            status = "danger"
        }
        return (fc: fc, status: status)
    }
}
