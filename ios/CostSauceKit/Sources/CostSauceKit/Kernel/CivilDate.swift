// The CostSauce costing kernel, Swift implementation — civil-date math.
//
// Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md
// §4.3, §9, §10, pinned by shared/golden-vectors.json's `drift` class.
// Days-since-epoch via pure integer civil-date math — NEVER Date/Calendar
// arithmetic (that was the B5 bug: a Date-object timezone slip). Function-
// for-function port of shared/kernel.js:131-156 (Howard Hinnant's
// days-from-civil / civil-from-days algorithm).

import Foundation

extension Kernel {

    /// Days since the Unix epoch (1970-01-01) for an ISO "YYYY-MM-DD"
    /// string, via Hinnant's days_from_civil. Port of kernel.js:131-141.
    /// `Math.floor(a / b)` in the reference becomes `floorDiv` here since
    /// Swift's `/` truncates toward zero rather than flooring.
    public static func dayNumber(_ iso: String) -> Int {
        let parts = iso.split(separator: "-")
        let y = Int(parts[0])!
        let m = Int(parts[1])!
        let d = Int(parts[2])!
        let yy = m <= 2 ? y - 1 : y
        let era = floorDiv(yy, 400)
        let yoe = yy - era * 400
        let doy = floorDiv(153 * (m + (m > 2 ? -3 : 9)) + 2, 5) + d - 1
        let doe = yoe * 365 + floorDiv(yoe, 4) - floorDiv(yoe, 100) + doy
        return era * 146097 + doe - 719468
    }

    /// Inverse of `dayNumber`: days-since-epoch → zero-padded "YYYY-MM-DD".
    /// Port of kernel.js:142-156.
    public static func dayToIso(_ z: Int) -> String {
        let zz = z + 719468
        let era = floorDiv(zz, 146097)
        let doe = zz - era * 146097
        let yoe = floorDiv(
            doe - floorDiv(doe, 1460) + floorDiv(doe, 36524) - floorDiv(doe, 146096),
            365)
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + floorDiv(yoe, 4) - floorDiv(yoe, 100))
        let mp = floorDiv(5 * doy + 2, 153)
        let d = doy - floorDiv(153 * mp + 2, 5) + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let yy = m <= 2 ? y + 1 : y
        return "\(zeroPadded(yy, 4))-\(zeroPadded(m, 2))-\(zeroPadded(d, 2))"
    }

    /// `Math.floor(a / b)` for integers, matching JS's floor-toward-negative-
    /// -infinity division (Swift's `/` truncates toward zero instead). Every
    /// divisor used by `dayNumber`/`dayToIso` is positive.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    /// `String(n).padStart(width, "0")` — left-pads with zeros to at least
    /// `width` characters (never truncates a longer number). Shared by
    /// `dayToIso` and `Timestamps.swift`'s canonical formatting.
    static func zeroPadded(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        if s.count >= width { return s }
        return String(repeating: "0", count: width - s.count) + s
    }
}
