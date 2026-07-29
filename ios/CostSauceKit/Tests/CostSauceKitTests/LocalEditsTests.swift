import Testing
import Foundation
@testable import CostSauceKit

@Suite struct LocalEditsTests {

    /// Asserts `body` throws a `LocalEdits.EditError` equal to `expected`.
    private func expectEditError(_ expected: LocalEdits.EditError, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected to throw EditError \(expected)")
        } catch let error as LocalEdits.EditError {
            #expect(error == expected)
        } catch {
            Issue.record("expected EditError, got \(error)")
        }
    }

    private func seededStore(_ changes: [PullChange]) throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage(changes, cursor: 1)
        return store
    }

    /// `fields`' values are `String??` at the subscript (the dictionary is
    /// `[String: String?]`) -- flatten one level so callers can compare
    /// against a plain `String?` without nested-optional literal inference.
    private func fieldValue(_ op: PendingOp, _ key: String) -> String? {
        op.fields[key] ?? nil
    }

    // MARK: - createPurchase

    @Test func createPurchaseWritesRowWithAllowlistedOpFieldsAndGoldenQtyBaseUnits() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", baseUnit: "lb", serverSeq: 1),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let id = try edits.createPurchase(
            ingredientId: "ing-1", purchasedOn: "2026-07-29", qty: "10", unit: "kg",
            qtyInCase: nil, totalPrice: "55.10", now: now)

        // The row is genuinely written -- visible to a local read immediately.
        let purchase = try #require(try store.livePurchases(ingredientId: "ing-1").first)
        #expect(purchase.id == id)
        #expect(purchase.ingredient_id == "ing-1")
        // golden `normalize_purchase` "kg to lb" expectation.
        #expect(purchase.qty_base_units == "22.0462")
        #expect(purchase.recorded_at == Kernel.canonicalTimestamp(now))
        #expect(purchase.client_mutated_at == Kernel.canonicalTimestamp(now))

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == id })
        #expect(op.table == "purchases")
        #expect(op.kind == .insert)
        #expect(Set(op.fields.keys) == [
            "ingredient_id", "purchased_on", "recorded_at", "qty", "unit",
            "qty_base_units", "total_price",
        ])
        #expect(!op.fields.keys.contains("qty_in_case"), "qty_in_case key must be absent for unit lb")
    }

    @Test func createPurchaseCaseUnitIncludesQtyInCaseAndLowercasesUnit() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Eggs", baseUnit: "each", serverSeq: 1),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        let id = try edits.createPurchase(
            ingredientId: "ing-1", purchasedOn: "2026-07-29", qty: "2", unit: "  CASE  ",
            qtyInCase: "12", totalPrice: "24.00")

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == id })
        #expect(Set(op.fields.keys) == [
            "ingredient_id", "purchased_on", "recorded_at", "qty", "unit",
            "qty_in_case", "qty_base_units", "total_price",
        ])
        #expect(fieldValue(op, "unit") == "case")
        #expect(fieldValue(op, "qty_in_case") == "12")
    }

    // MARK: - createIngredient

    @Test func createIngredientWritesRowWithAllowlistedOpFields() throws {
        let store = try seededStore([])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        let id = try edits.createIngredient(
            name: "  Sugar  ", baseUnit: "lb", vendor: "Acme", category: nil)

        let ingredient = try #require(try store.ingredient(id: id))
        #expect(ingredient.name == "Sugar")
        #expect(ingredient.base_unit == "lb")
        #expect(ingredient.vendor == "Acme")
        #expect(ingredient.category == nil)

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == id })
        #expect(op.table == "ingredients")
        #expect(op.kind == .insert)
        #expect(Set(op.fields.keys) == ["name", "base_unit", "vendor"])
        #expect(fieldValue(op, "name") == "Sugar")
    }

    @Test func createIngredientDuplicateNameThrowsWithExistingId() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        expectEditError(.duplicate(existingId: "ing-1", name: "Flour")) {
            _ = try edits.createIngredient(name: "flour", baseUnit: "lb", vendor: nil, category: nil)
        }
    }

    @Test func createIngredientEmptyNormalizedNameThrowsKernelError() throws {
        let store = try seededStore([])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        #expect(throws: KernelError.self) {
            _ = try edits.createIngredient(name: "!!!", baseUnit: "lb", vendor: nil, category: nil)
        }
    }

    // MARK: - tombstoneIngredient

    @Test func tombstoneIngredientWithLiveRecipeLineThrowsInUse() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
            StoreTests.recipeChange(id: "rec-1", name: "Bread", serverSeq: 2),
            StoreTests.recipeItemChange(id: "ri-1", recipeId: "rec-1", ingredientId: "ing-1", serverSeq: 3),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        expectEditError(.inUse(count: 1)) {
            try edits.tombstoneIngredient(id: "ing-1")
        }
        // No op was queued for the rejected tombstone.
        #expect(try store.pendingOps(state: .queued).isEmpty)
    }

    @Test func tombstoneIngredientWithNoLiveRecipeLinesQueuesDeletedAtOp() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try edits.tombstoneIngredient(id: "ing-1", now: now)

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == "ing-1" })
        #expect(op.kind == .update)
        #expect(Set(op.fields.keys) == ["deleted_at"])
        #expect(fieldValue(op, "deleted_at") == Kernel.canonicalTimestamp(now))
        #expect(try store.liveIngredients().isEmpty)
    }

    // MARK: - unitChoices

    @Test func unitChoicesForEachTrackedBaseUnit() throws {
        let store = try seededStore([])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        #expect(edits.unitChoices(baseUnit: "each") == ["each", "case"])
    }

    @Test func unitChoicesForWeightTrackedBaseUnit() throws {
        let store = try seededStore([])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        // Every weight `base_unit` (lb/oz/kg/g) offers the same full weight
        // vocabulary plus "case" -- a purchase's `unit` need not match the
        // ingredient's own tracked `base_unit` (`Kernel.normalizePurchase`'s
        // cross-unit conversion handles e.g. buying oz against an lb-tracked
        // ingredient).
        #expect(edits.unitChoices(baseUnit: "lb") == ["lb", "oz", "kg", "g", "case"])
        #expect(edits.unitChoices(baseUnit: "oz") == ["lb", "oz", "kg", "g", "case"])
        #expect(edits.unitChoices(baseUnit: "kg") == ["lb", "oz", "kg", "g", "case"])
        #expect(edits.unitChoices(baseUnit: "g") == ["lb", "oz", "kg", "g", "case"])
    }

    // MARK: - tombstonePurchase

    @Test func tombstonePurchaseOpCarriesOnlyDeletedAt() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
            StoreTests.purchaseChange(id: "pu-1", ingredientId: "ing-1", serverSeq: 2),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try edits.tombstonePurchase(id: "pu-1", now: now)

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == "pu-1" })
        #expect(op.table == "purchases")
        #expect(op.kind == .update)
        #expect(Set(op.fields.keys) == ["deleted_at"])
        #expect(fieldValue(op, "deleted_at") == Kernel.canonicalTimestamp(now))
        #expect(try store.livePurchases(ingredientId: "ing-1").isEmpty)
    }

    // MARK: - recipe fixtures + reads

    /// One live recipe ("Bread") with two live lines (Flour, Water) over two
    /// live ingredients, plus a third live ingredient (Salt, unused by the
    /// recipe) and a fourth tombstoned one (Yeast) -- covers every guard
    /// path the recipe-mutation tests below exercise.
    private func recipeFixture() throws -> LocalStore {
        try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
            StoreTests.ingredientChange(id: "ing-2", name: "Water", serverSeq: 2),
            StoreTests.ingredientChange(id: "ing-3", name: "Salt", serverSeq: 3),
            StoreTests.ingredientChange(
                id: "ing-4", name: "Yeast", serverSeq: 4, deletedAt: "2026-07-29 10:00:00+00"),
            StoreTests.recipeChange(id: "rec-1", name: "Bread", serverSeq: 5),
            StoreTests.recipeChange(id: "rec-2", name: "Other", serverSeq: 6),
            StoreTests.recipeItemChange(id: "ri-1", recipeId: "rec-1", ingredientId: "ing-1", serverSeq: 7),
            StoreTests.recipeItemChange(id: "ri-2", recipeId: "rec-1", ingredientId: "ing-2", serverSeq: 8),
            StoreTests.recipeItemChange(
                id: "ri-3", recipeId: "rec-1", ingredientId: "ing-3", serverSeq: 9,
                deletedAt: "2026-07-29 10:00:00+00"),
            StoreTests.recipeItemChange(id: "ri-4", recipeId: "rec-2", ingredientId: "ing-1", serverSeq: 10),
        ])
    }

    @Test func recipeReturnsNilForUnknownId() throws {
        let store = try recipeFixture()
        #expect(try store.recipe(id: "nope") == nil)
    }

    @Test func liveRecipeItemsScopedExcludesTombstonedLineAndOtherRecipe() throws {
        let store = try recipeFixture()

        let items = try store.liveRecipeItems(recipeId: "rec-1")

        #expect(Set(items.map(\.id)) == ["ri-1", "ri-2"])
    }

    // MARK: - updateRecipeFields

    @Test func updateRecipeFieldsNameOnlyTrimsAndEnqueuesSingleOp() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")

        try edits.updateRecipeFields(id: "rec-1", name: "  Carbonara  ", menuPrice: nil, targetFcPct: nil)

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == "rec-1" })
        #expect(op.table == "recipes")
        #expect(op.kind == .update)
        #expect(Set(op.fields.keys) == ["name"])
        #expect(fieldValue(op, "name") == "Carbonara")
    }

    @Test func updateRecipeFieldsAllNilEnqueuesNothing() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let before = try store.pendingCount()

        try edits.updateRecipeFields(id: "rec-1", name: nil, menuPrice: nil, targetFcPct: nil)

        #expect(try store.pendingCount() == before)
        #expect(try store.pendingOps(state: .queued).allSatisfy { $0.row_id != "rec-1" })
    }

    @Test func updateRecipeFieldsZeroMenuPriceThrowsKernelError() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")

        #expect(throws: KernelError.self) {
            try edits.updateRecipeFields(id: "rec-1", name: nil, menuPrice: "0", targetFcPct: nil)
        }
    }

    // MARK: - addRecipeLine

    @Test func addRecipeLineWritesLiveRowAndEnqueuesInsertOp() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")

        let id = try edits.addRecipeLine(recipeId: "rec-1", ingredientId: "ing-3", qty: "2.5000")

        #expect(id.count == 36)
        #expect(id == id.lowercased())
        let items = try store.liveRecipeItems(recipeId: "rec-1")
        #expect(items.count == 3)
        #expect(items.contains { $0.id == id && $0.ingredient_id == "ing-3" })

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == id })
        #expect(op.table == "recipe_items")
        #expect(op.kind == .insert)
        #expect(Set(op.fields.keys) == ["recipe_id", "ingredient_id", "qty_base_units"])
    }

    @Test func addRecipeLineDuplicateIngredientThrowsWithExistingLineId() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")

        expectEditError(.duplicate(existingId: "ri-1", name: "Flour")) {
            _ = try edits.addRecipeLine(recipeId: "rec-1", ingredientId: "ing-1", qty: "1")
        }
    }

    @Test func addRecipeLineTombstonedIngredientThrowsKernelError() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")

        #expect(throws: KernelError.self) {
            _ = try edits.addRecipeLine(recipeId: "rec-1", ingredientId: "ing-4", qty: "1")
        }
    }

    // MARK: - updateRecipeLineQty

    @Test func updateRecipeLineQtyEnqueuesQtyOnlyOp() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")

        try edits.updateRecipeLineQty(itemId: "ri-1", qty: "3.0000")

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == "ri-1" })
        #expect(op.table == "recipe_items")
        #expect(op.kind == .update)
        #expect(Set(op.fields.keys) == ["qty_base_units"])
        #expect(fieldValue(op, "qty_base_units") == "3.0000")
    }

    // MARK: - tombstoneRecipeLine

    @Test func tombstoneRecipeLineLeavesOneLiveLine() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try edits.tombstoneRecipeLine(itemId: "ri-2", now: now)

        let ops = try store.pendingOps(state: .queued)
        let op = try #require(ops.first { $0.row_id == "ri-2" })
        #expect(op.table == "recipe_items")
        #expect(op.kind == .update)
        #expect(Set(op.fields.keys) == ["deleted_at"])
        #expect(fieldValue(op, "deleted_at") == Kernel.canonicalTimestamp(now))
        #expect(try store.liveRecipeItems(recipeId: "rec-1").count == 1)
    }

    @Test func tombstoneRecipeLineOnLastLineThrowsLastLineAndEnqueuesNothing() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        try edits.tombstoneRecipeLine(itemId: "ri-2")
        let before = try store.pendingCount()

        expectEditError(.lastLine) {
            try edits.tombstoneRecipeLine(itemId: "ri-1")
        }

        #expect(try store.pendingCount() == before)
        #expect(try store.liveRecipeItems(recipeId: "rec-1").count == 1)
    }
}
