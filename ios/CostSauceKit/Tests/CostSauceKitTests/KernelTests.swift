import Testing
@testable import CostSauceKit

@Suite struct KernelGoldenValueTests {

    @Test func normalizePurchaseGolden() throws {
        let vectors = try goldenVectors()
        for c in vectors.normalizePurchase {
            if c.expectError == true {
                #expect(throws: KernelError.self, "case: \(c.name)") {
                    _ = try Kernel.normalizePurchase(
                        baseUnit: c.baseUnit, qty: c.qty, unit: c.unit,
                        totalPrice: c.totalPrice, qtyInCase: c.qtyInCase)
                }
            } else {
                let result = try Kernel.normalizePurchase(
                    baseUnit: c.baseUnit, qty: c.qty, unit: c.unit,
                    totalPrice: c.totalPrice, qtyInCase: c.qtyInCase)
                #expect(result == c.expect, "case: \(c.name)")
            }
        }
    }

    @Test func unitPriceGolden() throws {
        let vectors = try goldenVectors()
        for (i, c) in vectors.unitPrice.enumerated() {
            let result = try Kernel.unitPrice(totalPrice: c.totalPrice, qtyBaseUnits: c.qtyBaseUnits)
            #expect(result == c.expect, "case index \(i)")
        }
    }

    @Test func suggestedPriceCentsGolden() throws {
        let vectors = try goldenVectors()
        for (i, c) in vectors.suggestedPriceCents.enumerated() {
            let result = try Kernel.suggestedPriceCents(plateCents: c.plateCents, targetBp: c.targetBp)
            #expect(result == c.expect, "case index \(i)")
        }
    }

    @Test func fcStatusGolden() throws {
        let vectors = try goldenVectors()
        for (i, c) in vectors.fcStatus.enumerated() {
            let result = try Kernel.fcStatus(plateCents: c.plateCents, menuCents: c.menuCents, targetBp: c.targetBp)
            #expect(result.fc == c.expectFc, "case index \(i) fc")
            #expect(result.status == c.expectStatus, "case index \(i) status")
        }
    }
}

@Suite struct KernelNameTests {

    @Test func stripsTrailingSAboveLengthGuard() {
        #expect(Kernel.normalizeName("Chicken Breasts") == "chicken breast")
    }

    @Test func ssGuardLeavesDoubleSAlone() {
        #expect(Kernel.normalizeName("grass") == "grass")
    }

    @Test func lengthGuardLeavesShortWordAlone() {
        #expect(Kernel.normalizeName("abs") == "abs")
    }

    @Test func dropsPunctuationAndCollapsesWhitespace() {
        #expect(Kernel.normalizeName("Chkn  Brst!!") == "chkn brst")
    }
}

@Suite struct KernelMatchIngredientTests {

    @Test func exactBeatsFuzzyEvenWhenFuzzyCandidateComesFirst() {
        let candidates = [
            Kernel.Candidate(id: "fuzzy-1", name: "chicken breast tender"),
            Kernel.Candidate(id: "exact-1", name: "chicken breast"),
        ]
        let match = Kernel.matchIngredient(name: "chicken breast", candidates: candidates)
        #expect(match?.id == "exact-1")
        #expect(match?.type == .exact)
    }

    @Test func firstMatchWinsWithinAPass() {
        let candidates = [
            Kernel.Candidate(id: "first", name: "chicken breast"),
            Kernel.Candidate(id: "second", name: "chicken breast"),
        ]
        let match = Kernel.matchIngredient(name: "chicken breast", candidates: candidates)
        #expect(match?.id == "first")
    }

    @Test func noCandidatesReturnsNil() {
        #expect(Kernel.matchIngredient(name: "chicken breast", candidates: []) == nil)
    }
}

@Suite struct KernelNearMatchesTests {

    @Test func returnsUpToThreeInCandidateOrderWithBidirectionalContainment() {
        let candidates = [
            Kernel.Candidate(id: "1", name: "chicken breast"),
            Kernel.Candidate(id: "2", name: "chicken"),
            Kernel.Candidate(id: "3", name: "chicken thigh"),
            Kernel.Candidate(id: "4", name: "chicken wing"),
        ]
        let result = Kernel.nearMatches(name: "chicken", candidates: candidates)
        #expect(result.map(\.id) == ["1", "2", "3"])
    }

    @Test func emptyNameReturnsEmpty() {
        let candidates = [Kernel.Candidate(id: "1", name: "chicken")]
        #expect(Kernel.nearMatches(name: "", candidates: candidates).isEmpty)
    }
}
