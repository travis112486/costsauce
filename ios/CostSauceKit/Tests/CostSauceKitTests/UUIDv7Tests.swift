import Testing
@testable import CostSauceKit

@Suite struct UUIDv7Tests {

    @Test func versionNibbleIsSeven() {
        let id = UUIDv7.generate()
        let versionChar = id[id.index(id.startIndex, offsetBy: 14)]
        #expect(versionChar == "7")
    }

    @Test func variantCharIsInExpectedRange() {
        let id = UUIDv7.generate()
        let variantChar = id[id.index(id.startIndex, offsetBy: 19)]
        #expect(["8", "9", "a", "b"].contains(String(variantChar)))
    }

    @Test func lowercaseThirtySixCharHyphenatedFormat() {
        let id = UUIDv7.generate()
        #expect(id.count == 36)
        #expect(id == id.lowercased())
        let pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
        #expect(id.wholeMatch(of: pattern) != nil)
    }

    @Test func idsMintedWithPinnedMillisOneApartOrderLexicographically() {
        let a = UUIDv7.generate(millis: 1_753_000_000_000, randomA: 0, randomB: 0)
        let b = UUIDv7.generate(millis: 1_753_000_000_001, randomA: 0, randomB: 0)
        #expect(a < b)
    }
}
