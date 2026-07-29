import Testing
@testable import CostSauceKit

@Suite struct RationalTests {

    @Test func parseDecInvalidThrows() {
        #expect(throws: KernelError.self) {
            try Rational.parseDec("x")
        }
    }

    @Test func divByZeroThrows() {
        #expect(throws: KernelError.self) {
            try Rational.parseDec("1").div(Rational.parseDec("0"))
        }
    }

    @Test func divNormalizesNegativeDenominator() throws {
        let result = try Rational.parseDec("1").div(Rational.parseDec("-2"))
        let expected = try Rational.parseDec("-0.5")
        #expect(result.cmp(expected) == 0)
    }

    @Test func roundHalfAwayPositiveHalf() throws {
        #expect(Kernel.roundHalfAway(try Rational.parseDec("2.5"), places: 0) == "3")
    }

    @Test func roundHalfAwayNegativeHalf() throws {
        #expect(Kernel.roundHalfAway(try Rational.parseDec("-2.5"), places: 0) == "-3")
    }

    @Test func roundHalfAwayZeroDropsSign() throws {
        #expect(Kernel.roundHalfAway(try Rational.parseDec("-0.0004"), places: 3) == "0.000")
    }

    @Test func roundHalfAwayPadsFraction() throws {
        #expect(Kernel.roundHalfAway(try Rational.parseDec("1.5"), places: 4) == "1.5000")
    }
}
