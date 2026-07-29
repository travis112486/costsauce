import Testing
import Foundation
@testable import CostSauceKit

@Suite struct TimestampTests {

    @Test func canonicalizesFractionalPostgresTimestamp() throws {
        #expect(try Kernel.canonicalize("2026-07-29 12:34:56.789+00") == "2026-07-29T12:34:56.789000Z")
    }

    @Test func canonicalizesWholeSecondPostgresTimestamp() throws {
        #expect(try Kernel.canonicalize("2026-07-29 12:34:56+00") == "2026-07-29T12:34:56.000000Z")
    }

    @Test func canonicalInputRoundTripsUnchanged() throws {
        let canonical = "2026-07-29T12:34:56.789000Z"
        #expect(try Kernel.canonicalize(canonical) == canonical)
    }

    @Test func junkThrows() {
        #expect(throws: KernelError.self) {
            try Kernel.canonicalize("not a timestamp")
        }
    }

    @Test func todayLocalISOUsesLocalDateNotUTC() {
        // 2026-07-28 01:00 UTC is still 2026-07-27 in America/Los_Angeles — the
        // B5 bug this function exists to fix (never toISOString()/UTC slicing).
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 28
        comps.hour = 1
        let now = utcCalendar.date(from: comps)!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        #expect(Kernel.todayLocalISO(now: now, timeZone: losAngeles) == "2026-07-27")
    }

    @Test func centsFromStringRejectsMoreThanTwoDecimalPlaces() {
        #expect(throws: KernelError.self) {
            try Kernel.centsFromString("14.005")
        }
    }

    @Test func moneyFromCentsFormatsWholeDollarAmount() {
        #expect(Kernel.moneyFromCents(400) == "4.00")
    }

    @Test func bpFromStringParsesPercentStringToBasisPoints() throws {
        #expect(try Kernel.bpFromString("30.00") == 3000)
    }
}
