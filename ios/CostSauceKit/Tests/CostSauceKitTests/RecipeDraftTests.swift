import Testing
import Foundation
@testable import CostSauceKit

@Suite struct RecipeDraftTests {

    private func line(_ ingredientId: String = "ing-1", qty: String = "1") -> RecipeDraft.Line {
        RecipeDraft.Line(ingredientId: ingredientId, qty: qty)
    }

    // MARK: - fully valid

    @Test func fullyValidDraftReturnsNoErrors() throws {
        let draft = RecipeDraft(
            name: "Bread", menuPrice: "12.00", targetFcPct: "30.00",
            lines: [line("ing-1", qty: "1"), line("ing-2", qty: "2")])

        #expect(draft.validate() == [])
    }

    // MARK: - name

    @Test func emptyNameReturnsNameEmpty() throws {
        let draft = RecipeDraft(
            name: "", menuPrice: "12.00", targetFcPct: "30.00", lines: [line()])

        #expect(draft.validate() == [.nameEmpty])
    }

    @Test func whitespaceOnlyNameReturnsNameEmpty() throws {
        // normalizeName, not isEmpty -- "   " normalizes to "".
        let draft = RecipeDraft(
            name: "   ", menuPrice: "12.00", targetFcPct: "30.00", lines: [line()])

        #expect(draft.validate() == [.nameEmpty])
    }

    // MARK: - menuPrice

    private func expectMenuPriceInvalid(_ menuPrice: String) {
        let draft = RecipeDraft(
            name: "Bread", menuPrice: menuPrice, targetFcPct: "30.00", lines: [line()])

        #expect(draft.validate() == [.menuPriceInvalid])
    }

    @Test func menuPriceZeroReturnsMenuPriceInvalid() throws { expectMenuPriceInvalid("0") }
    @Test func menuPriceNegativeReturnsMenuPriceInvalid() throws { expectMenuPriceInvalid("-1") }
    @Test func menuPriceNonDecimalReturnsMenuPriceInvalid() throws { expectMenuPriceInvalid("abc") }
    @Test func menuPriceEmptyReturnsMenuPriceInvalid() throws { expectMenuPriceInvalid("") }

    // MARK: - targetFcPct

    private func expectTargetFcPctInvalid(_ targetFcPct: String) {
        let draft = RecipeDraft(
            name: "Bread", menuPrice: "12.00", targetFcPct: targetFcPct, lines: [line()])

        #expect(draft.validate() == [.targetFcPctInvalid])
    }

    @Test func targetFcPctZeroReturnsTargetFcPctInvalid() throws { expectTargetFcPctInvalid("0") }
    @Test func targetFcPctNegativeReturnsTargetFcPctInvalid() throws { expectTargetFcPctInvalid("-1") }
    @Test func targetFcPctNonDecimalReturnsTargetFcPctInvalid() throws { expectTargetFcPctInvalid("abc") }
    @Test func targetFcPctEmptyReturnsTargetFcPctInvalid() throws { expectTargetFcPctInvalid("") }

    // MARK: - lines

    @Test func noLinesReturnsNoLines() throws {
        let draft = RecipeDraft(name: "Bread", menuPrice: "12.00", targetFcPct: "30.00", lines: [])

        #expect(draft.validate() == [.noLines])
    }

    @Test func zeroQtyLineReturnsLineQtyInvalidCarryingThatLinesId() throws {
        let badLine = line("ing-1", qty: "0")
        let draft = RecipeDraft(
            name: "Bread", menuPrice: "12.00", targetFcPct: "30.00", lines: [badLine])

        #expect(draft.validate() == [.lineQtyInvalid(lineId: badLine.id)])
    }

    @Test func duplicateIngredientAcrossTwoLinesReturnsDuplicateIngredient() throws {
        let draft = RecipeDraft(
            name: "Bread", menuPrice: "12.00", targetFcPct: "30.00",
            lines: [line("ing-1", qty: "1"), line("ing-1", qty: "2")])

        #expect(draft.validate() == [.duplicateIngredient(ingredientId: "ing-1")])
    }

    // MARK: - multiple failures, exact order

    @Test func draftWrongInThreeWaysReturnsAllThreeInDeclarationOrder() throws {
        // Wrong in three ways: empty name, invalid menuPrice, no lines.
        // Declaration order is: nameEmpty, menuPriceInvalid, targetFcPctInvalid,
        // noLines, lineQtyInvalid, duplicateIngredient.
        let draft = RecipeDraft(name: "", menuPrice: "0", targetFcPct: "30.00", lines: [])

        #expect(draft.validate() == [.nameEmpty, .menuPriceInvalid, .noLines])
    }

    // MARK: - menuPrice with more decimals than the column

    @Test func menuPriceWithExtraDecimalsIsAcceptedVerbatim() throws {
        // "18.005" has more decimals than the numeric(10,2) column -- validate()
        // accepts it as-is; the server's column is authoritative, matching how
        // purchase totals already behave.
        let draft = RecipeDraft(
            name: "Bread", menuPrice: "18.005", targetFcPct: "30.00", lines: [line()])

        #expect(draft.validate() == [])
    }
}
