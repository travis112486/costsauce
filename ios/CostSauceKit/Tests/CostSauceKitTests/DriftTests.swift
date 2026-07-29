import Testing
@testable import CostSauceKit

/// Deterministically reorders `array`: reverse, then swap each adjacent
/// pair. The `drift` golden vectors' `rows` are an unordered set (spec
/// §9.2 — row SELECTION is unordered, not row ORDER), so tests must not
/// depend on the on-disk row order; this shuffle exercises the function's
/// own (purchased_on, recorded_at, id) DESC sort rather than accidentally
/// relying on JSON array order already being sorted.
private func deterministicallyShuffled<T>(_ array: [T]) -> [T] {
    var result = Array(array.reversed())
    var i = 0
    while i + 1 < result.count {
        result.swapAt(i, i + 1)
        i += 2
    }
    return result
}

@Suite struct DriftGoldenTests {

    @Test func driftGolden() throws {
        let vectors = try goldenVectors()
        for c in vectors.drift {
            let rows = deterministicallyShuffled(c.rows).map {
                PurchaseRow(
                    purchasedOn: $0.purchasedOn, recordedAt: $0.recordedAt,
                    id: $0.id, unitPrice: $0.unitPrice, deleted: $0.deleted)
            }
            let result = Kernel.drift(rows)
            if let expect = c.expect {
                let expected = DriftResult(
                    latestPrice: expect.latestPrice, latestOn: expect.latestOn,
                    windowStart: expect.windowStart, baselineN: expect.baselineN,
                    trailingAvg: expect.trailingAvg, driftPct: expect.driftPct)
                #expect(result == expected, "case: \(c.name)")
            } else {
                #expect(result == nil, "case: \(c.name)")
            }
        }
    }
}

@Suite struct CivilDateTests {

    @Test func leapYearFebruaryIsTwoDaysBeforeMarch() {
        #expect(Kernel.dayNumber("2024-03-01") - Kernel.dayNumber("2024-02-28") == 2)
    }

    @Test func nonLeapYearFebruaryIsOneDayBeforeMarch() {
        #expect(Kernel.dayNumber("2026-03-01") - Kernel.dayNumber("2026-02-28") == 1)
    }

    @Test func dayToIsoRoundTripsThroughDayNumber() {
        #expect(Kernel.dayToIso(Kernel.dayNumber("2026-07-29")) == "2026-07-29")
    }

    @Test func roundTripsAcrossAYearBoundary() {
        let nextDay = Kernel.dayNumber("2025-12-31") + 1
        #expect(Kernel.dayToIso(nextDay) == "2026-01-01")
    }
}
