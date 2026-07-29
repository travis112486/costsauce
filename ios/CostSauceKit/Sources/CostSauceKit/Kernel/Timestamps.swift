// The CostSauce costing kernel, Swift implementation — timestamps and
// decimal/money string helpers.
//
// Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md,
// api/kernel.py:152's `canonical_recorded_at`, web/js/lib.mjs's
// `todayLocalISO`/`centsFromString`/`moneyFromCents`. `canonicalTimestamp`
// and `parsePostgresTimestamp` read a `Date`'s instant via
// `timeIntervalSince1970` exactly once (Foundation's Date is fundamentally
// a Double) and round immediately to integer epoch-microseconds; every
// other step — splitting into civil day + time-of-day, day ↔ Y-M-D — is
// plain integer math via `Kernel.dayNumber`/`dayToIso`, never further
// Date/Calendar arithmetic. `todayLocalISO` is the one place `Calendar` is
// used at all, and only to READ local Y/M/D components (never to add or
// subtract dates — that was the B5 bug).

import Foundation

extension Kernel {
    private static let microsPerSecond: Int128 = 1_000_000
    private static let microsPerDay: Int128 = 86_400_000_000

    /// UTC "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'" — the same string
    /// api/kernel.py:152's `canonical_recorded_at` emits.
    public static func canonicalTimestamp(_ d: Date) -> String {
        let totalMicros = Int128((d.timeIntervalSince1970 * Double(microsPerSecond)).rounded())
        return canonicalTimestamp(epochMicros: totalMicros)
    }

    static func canonicalTimestamp(epochMicros totalMicros: Int128) -> String {
        var days = totalMicros / microsPerDay
        var micros = totalMicros % microsPerDay
        if micros < 0 {
            micros += microsPerDay
            days -= 1
        }
        let iso = dayToIso(Int(days))

        let hours = micros / 3_600_000_000
        micros %= 3_600_000_000
        let minutes = micros / 60_000_000
        micros %= 60_000_000
        let seconds = micros / microsPerSecond
        let frac = micros % microsPerSecond

        return "\(iso)T\(zeroPadded(Int(hours), 2)):\(zeroPadded(Int(minutes), 2)):"
            + "\(zeroPadded(Int(seconds), 2)).\(zeroPadded(Int(frac), 6))Z"
    }

    /// Accepts two shapes:
    /// - the Postgres `timestamptz::text` rendering pull payloads use,
    ///   "YYYY-MM-DD HH:MM:SS[.ffffff]+00" (fraction optional, offset
    ///   always present as a whole-hour "+HH"/"-HH");
    /// - the canonical "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'" form emitted by
    ///   `canonicalTimestamp` (device-minted rows echo this back).
    ///
    /// Junk throws `KernelError`.
    public static func parsePostgresTimestamp(_ s: String) throws -> Date {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

        if let m = trimmed.wholeMatch(
            of: /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{6})Z/
        ) {
            let iso = "\(m.output.1)-\(m.output.2)-\(m.output.3)"
            let micros = Int(m.output.7)!
            return makeDate(
                iso: iso, hour: Int(m.output.4)!, minute: Int(m.output.5)!,
                second: Int(m.output.6)!, micros: micros, offsetMinutes: 0)
        }

        if let m = trimmed.wholeMatch(
            of: /(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?([+-]\d{2})/
        ) {
            let iso = "\(m.output.1)-\(m.output.2)-\(m.output.3)"
            let micros = microsFromFraction(m.output.7.map(String.init) ?? "")
            let offsetHours = Int(m.output.8)!
            return makeDate(
                iso: iso, hour: Int(m.output.4)!, minute: Int(m.output.5)!,
                second: Int(m.output.6)!, micros: micros, offsetMinutes: offsetHours * 60)
        }

        throw KernelError("not a timestamp: \(s)")
    }

    /// `parsePostgresTimestamp` → `canonicalTimestamp`, i.e. reformat
    /// whatever timestamp shape arrived on the wire into the one canonical
    /// encoding used everywhere else.
    public static func canonicalize(_ timestamp: String) throws -> String {
        canonicalTimestamp(try parsePostgresTimestamp(timestamp))
    }

    /// Local "YYYY-MM-DD" via `Calendar` components read from `now` in
    /// `timeZone` — deliberately NOT `now.timeIntervalSince1970` sliced
    /// through UTC day math, because the local calendar date depends on
    /// the viewer's offset, which integer civil-date math has no way to
    /// know. This is the one sanctioned `Calendar` use in the kernel; it
    /// only reads components, never adds or subtracts. Port of
    /// web/js/lib.mjs's `todayLocalISO` (the B5 fix).
    public static func todayLocalISO(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        return "\(zeroPadded(comps.year!, 4))-\(zeroPadded(comps.month!, 2))-\(zeroPadded(comps.day!, 2))"
    }

    /// "12.34" → 1234, exact via string parsing — never `Double(s) * 100`,
    /// which is subject to float error. At most 2 decimal places are
    /// accepted; anything finer (e.g. "14.005") throws rather than
    /// silently truncating or rounding. Negatives are allowed (refunds/
    /// corrections). Port of web/js/lib.mjs's `centsFromString`.
    public static func centsFromString(_ s: String) throws -> Int {
        try twoDecimalPlacesToInt(s)
    }

    /// 1234 → "12.34" from an EXACT integer cent count. Pure integer
    /// arithmetic. Port of web/js/lib.mjs's `moneyFromCents`.
    public static func moneyFromCents(_ c: Int) -> String {
        let neg = c < 0
        let magnitude = neg ? -c : c
        let dollars = magnitude / 100
        let cents = magnitude % 100
        return "\(neg ? "-" : "")\(dollars).\(zeroPadded(cents, 2))"
    }

    /// "30.00" → 3000 (a target/threshold expressed as basis points — target
    /// percent × 100, mirroring api/services/costing.py's
    /// `target_bp = int(Decimal(target) * 100)`). Same string-exact,
    /// at-most-2dp parsing contract as `centsFromString`.
    public static func bpFromString(_ s: String) throws -> Int {
        try twoDecimalPlacesToInt(s)
    }

    /// Shared parser behind `centsFromString`/`bpFromString`: `^(-?)(\d+)
    /// (?:\.(\d+))?$` on the trimmed input, at most 2 fractional digits
    /// (right-padded to 2 when shorter), combined as `ip*100 + fp`.
    private static func twoDecimalPlacesToInt(_ s: String) throws -> Int {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = trimmed.wholeMatch(of: /(-?)(\d+)(?:\.(\d+))?/) else {
            throw KernelError("not a decimal string: \(s)")
        }
        let sign = m.output.1
        let intPart = m.output.2
        let fracPart = m.output.3 ?? ""
        guard fracPart.count <= 2 else {
            throw KernelError("more than 2 decimal places: \(s)")
        }
        var paddedFrac = String(fracPart)
        while paddedFrac.count < 2 { paddedFrac += "0" }
        guard let intValue = Int(intPart), let fracValue = Int(paddedFrac) else {
            throw KernelError("not a decimal string: \(s)")
        }
        let cents = intValue * 100 + fracValue
        return sign == "-" ? -cents : cents
    }

    /// Right-pads (or truncates) a fractional-seconds digit string to
    /// exactly 6 digits and parses it as integer microseconds — ".7" → 7e5,
    /// ".789" → 789000, ".123456" → 123456, "" → 0.
    private static func microsFromFraction(_ frac: String) -> Int {
        var padded = frac.count > 6 ? String(frac.prefix(6)) : frac
        while padded.count < 6 { padded += "0" }
        return Int(padded) ?? 0
    }

    /// Builds the `Date` for a civil date + time-of-day + microseconds in a
    /// fixed whole-hour-offset zone, entirely via integer arithmetic; the
    /// single Double touch is the final `Date(timeIntervalSince1970:)`
    /// call, which the API requires.
    private static func makeDate(
        iso: String, hour: Int, minute: Int, second: Int, micros: Int, offsetMinutes: Int
    ) -> Date {
        let days = Int128(dayNumber(iso))
        let daySeconds = Int128(hour) * 3600 + Int128(minute) * 60 + Int128(second)
        let totalSeconds = days * 86_400 + daySeconds - Int128(offsetMinutes) * 60
        let totalMicros = totalSeconds * microsPerSecond + Int128(micros)
        return Date(timeIntervalSince1970: Double(totalMicros) / Double(microsPerSecond))
    }
}
