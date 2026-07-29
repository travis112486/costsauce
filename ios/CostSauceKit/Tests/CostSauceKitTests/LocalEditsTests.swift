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
}
