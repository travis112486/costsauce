// The CostSauce costing kernel, Swift implementation — trailing-price drift.
//
// Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md
// §9-§10, pinned by shared/golden-vectors.json's `drift` class, compared as
// EXACT structs (string/int/nil fields), zero tolerance. Function-for-
// function port of shared/kernel.js:158-188.

import Foundation

/// One purchase-history row as `drift` consumes it. Port of the row shape
/// implied by kernel.js:158-188 (`purchased_on`, `recorded_at`, `id`,
/// `unit_price`, `deleted`).
public struct PurchaseRow: Sendable {
    public let purchasedOn: String
    public let recordedAt: String
    public let id: String
    public let unitPrice: String
    public let deleted: Bool

    public init(purchasedOn: String, recordedAt: String, id: String, unitPrice: String, deleted: Bool) {
        self.purchasedOn = purchasedOn
        self.recordedAt = recordedAt
        self.id = id
        self.unitPrice = unitPrice
        self.deleted = deleted
    }
}

/// Port of the `out` object kernel.js:158-188 builds and returns (or `nil`
/// when there are no live rows at all).
public struct DriftResult: Equatable, Sendable {
    public let latestPrice: String
    public let latestOn: String
    public let windowStart: String
    public let baselineN: Int
    public let trailingAvg: String?
    public let driftPct: String?

    public init(
        latestPrice: String, latestOn: String, windowStart: String,
        baselineN: Int, trailingAvg: String?, driftPct: String?
    ) {
        self.latestPrice = latestPrice
        self.latestOn = latestOn
        self.windowStart = windowStart
        self.baselineN = baselineN
        self.trailingAvg = trailingAvg
        self.driftPct = driftPct
    }
}

extension Kernel {
    /// Below this many baseline rows, `drift_pct` is withheld (a 1- or
    /// 2-row trailing average is too noisy to call a percentage). Port of
    /// api/kernel.py's `MIN_BASELINE_N`.
    private static let minBaselineN = 3

    /// The trailing window's width in days, anchored on the latest row's
    /// `purchased_on`. Port of api/kernel.py's `DRIFT_WINDOW_DAYS`.
    private static let driftWindowDays = 90

    /// spec §10: exclude tombstones; sort live rows by
    /// (purchased_on, recorded_at, id) DESC as plain string comparisons
    /// (same as kernel.js's `<`/`>` on strings); `latest` = the first row;
    /// `windowStart` = latest's purchased_on minus 90 days; `baseline` =
    /// the REST of the ordered rows (positional — never re-filtered by
    /// price, only by falling within the 90-day window); trailing average
    /// at 6dp once baseline is non-empty; `drift_pct` at 1dp only once
    /// baseline reaches `minBaselineN`. Port of kernel.js:158-188.
    public static func drift(_ rows: [PurchaseRow]) -> DriftResult? {
        let live = rows.filter { !$0.deleted }
        guard !live.isEmpty else { return nil }

        let ordered = live.sorted { a, b in
            if a.purchasedOn != b.purchasedOn { return a.purchasedOn > b.purchasedOn }
            if a.recordedAt != b.recordedAt { return a.recordedAt > b.recordedAt }
            return a.id > b.id
        }
        let latest = ordered[0]
        let windowStartDay = dayNumber(latest.purchasedOn) - driftWindowDays
        let windowStart = dayToIso(windowStartDay)
        let baseline = ordered.dropFirst().filter { dayNumber($0.purchasedOn) >= windowStartDay }
        let n = baseline.count

        guard n > 0 else {
            return DriftResult(
                latestPrice: latest.unitPrice, latestOn: latest.purchasedOn,
                windowStart: windowStart, baselineN: n,
                trailingAvg: nil, driftPct: nil)
        }

        // unit_price strings are already-validated decimals (produced by
        // Kernel.unitPrice or echoed back from the server) — a parse
        // failure here would mean corrupted upstream data, not a normal
        // error path, so this mirrors kernel.js's implicit propagation
        // without adding `throws` to this frozen, non-throwing signature.
        //
        // `Rational`'s arithmetic never reduces to lowest terms (by design
        // — it mirrors kernel.js's arbitrary-precision BigInt plumbing, see
        // Rational.swift's doc comment). Summing an unbounded baseline
        // would otherwise compound denominators multiplicatively every
        // iteration and overflow `Int128` (128 bits, unlike BigInt) well
        // within a handful of rows. `reduced(_:)` below cancels the
        // running GCD after each step — a value-preserving simplification,
        // so every `roundHalfAway` digit downstream is unaffected — to
        // keep magnitudes bounded for kernel arithmetic staying on plain,
        // trapping operators (never `&+`/`&*`).
        var sum = Rational(n: 0, d: 1)
        for r in baseline {
            sum = reduced(sum.add(try! Rational.parseDec(r.unitPrice)))
        }
        let avg = reduced(try! sum.div(Rational(n: Int128(n), d: 1)))
        let trailingAvg = roundHalfAway(avg, places: 6)

        var driftPct: String?
        if n >= minBaselineN {
            let latestPrice = try! Rational.parseDec(latest.unitPrice)
            let diff = reduced(latestPrice.sub(avg))
            let ratio = reduced(try! diff.div(avg))
            let pct = ratio.mul(Rational(n: 100, d: 1))
            driftPct = roundHalfAway(pct, places: 1)
        }

        return DriftResult(
            latestPrice: latest.unitPrice, latestOn: latest.purchasedOn,
            windowStart: windowStart, baselineN: n,
            trailingAvg: trailingAvg, driftPct: driftPct)
    }

    /// Euclidean GCD on magnitudes; `b` (a `Rational`'s denominator) is
    /// always positive per `Rational`'s invariant.
    private static func gcd(_ a: Int128, _ b: Int128) -> Int128 {
        var x = a < 0 ? -a : a
        var y = b < 0 ? -b : b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x
    }

    /// Cancels `r`'s GCD — an exact-value-preserving simplification (see
    /// the comment in `drift` above for why this is needed at all).
    private static func reduced(_ r: Rational) -> Rational {
        let g = gcd(r.n, r.d)
        guard g > 1 else { return r }
        return Rational(n: r.n / g, d: r.d / g)
    }
}
