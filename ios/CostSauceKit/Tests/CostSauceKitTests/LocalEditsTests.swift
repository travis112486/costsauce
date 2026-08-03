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

    @Test func createPurchaseCarriesTheInvoicePageItWasKeyedFrom() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", baseUnit: "lb", serverSeq: 1),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        let id = try edits.createPurchase(
            ingredientId: "ing-1", purchasedOn: "2026-08-03", qty: "10", unit: "lb",
            qtyInCase: nil, totalPrice: "55.10", invoicePageId: "pg-1")

        let op = try #require(try store.pendingOps(state: .queued).first { $0.row_id == id })
        #expect(fieldValue(op, "invoice_page_id") == "pg-1")
        // 3a-D5: a human keyed this while looking at a photo -- it is
        // manual. The op omits `source` entirely (the same convention every
        // other server-defaulted column follows), and the schema's
        // NOT NULL DEFAULT 'manual' is what makes that the recorded value.
        #expect(!op.fields.keys.contains("source"))
    }

    /// The parameter is defaulted, so every pre-3a call site is unchanged --
    /// and must not start sending an explicit null.
    @Test func createPurchaseWithoutAPageOmitsTheKeyEntirely() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", baseUnit: "lb", serverSeq: 1),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")

        let id = try edits.createPurchase(
            ingredientId: "ing-1", purchasedOn: "2026-08-03", qty: "10", unit: "lb",
            qtyInCase: nil, totalPrice: "55.10")

        let op = try #require(try store.pendingOps(state: .queued).first { $0.row_id == id })
        #expect(!op.fields.keys.contains("invoice_page_id"))
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

    /// Spec §3 ("the server orders by ingredient name") and §6 ("every
    /// stored read orders by ingredient name ... a saved recipe therefore
    /// reopens alphabetically"). The server's own query is literally
    /// `ORDER BY i.name, ri.id` (api/services/costing.py:62); this is its
    /// local mirror. The line ids here run in the OPPOSITE order to the
    /// ingredient names on purpose, so the previous `ORDER BY id` cannot
    /// pass by coincidence.
    @Test func liveRecipeItemsScopedOrdersByIngredientName() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-a", name: "Zucchini", serverSeq: 1),
            StoreTests.ingredientChange(id: "ing-b", name: "Apple", serverSeq: 2),
            StoreTests.ingredientChange(id: "ing-c", name: "Milk", serverSeq: 3),
            StoreTests.recipeChange(id: "rec-1", name: "Bread", serverSeq: 4),
            StoreTests.recipeItemChange(
                id: "ri-1", recipeId: "rec-1", ingredientId: "ing-a", serverSeq: 5),
            StoreTests.recipeItemChange(
                id: "ri-2", recipeId: "rec-1", ingredientId: "ing-b", serverSeq: 6),
            StoreTests.recipeItemChange(
                id: "ri-3", recipeId: "rec-1", ingredientId: "ing-c", serverSeq: 7),
        ])

        let items = try store.liveRecipeItems(recipeId: "rec-1")

        // Apple (ri-2), Milk (ri-3), Zucchini (ri-1).
        #expect(items.map(\.id) == ["ri-2", "ri-3", "ri-1"])
    }

    /// The `ri.id` half of the server's `ORDER BY i.name, ri.id`. Two
    /// ingredients CAN share a name (nothing constrains it -- the duplicate
    /// check `createIngredient` runs is a fuzzy pre-empt, not a schema
    /// UNIQUE), and both can sit on one recipe, since the per-recipe
    /// uniqueness constraint is on ingredient id. Without the tiebreak that
    /// pair's order would be whatever SQLite happened to return.
    ///
    /// Honest caveat: this one is a determinism PIN, not a test that drove
    /// the change -- with the names tied, the old `ORDER BY id` produced
    /// this same result, so it passed before the fix as well as after. It
    /// earns its place by catching a future rewrite that drops the
    /// tiebreak (e.g. a plain Swift `.sorted { $0.name < $1.name }`), which
    /// would leave same-name lines unordered again.
    @Test func liveRecipeItemsScopedTiesOnNameBreakByItemId() throws {
        let store = try seededStore([
            StoreTests.ingredientChange(id: "ing-a", name: "Basil", serverSeq: 1),
            StoreTests.ingredientChange(id: "ing-b", name: "Basil", serverSeq: 2),
            StoreTests.recipeChange(id: "rec-1", name: "Pesto", serverSeq: 3),
            StoreTests.recipeItemChange(
                id: "ri-9", recipeId: "rec-1", ingredientId: "ing-a", serverSeq: 4),
            StoreTests.recipeItemChange(
                id: "ri-1", recipeId: "rec-1", ingredientId: "ing-b", serverSeq: 5),
        ])

        let items = try store.liveRecipeItems(recipeId: "rec-1")

        #expect(items.map(\.id) == ["ri-1", "ri-9"])
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

    /// The liveness guard every OTHER recipe mutation already has
    /// (`addRecipeLine`/`tombstoneRecipe` check `recipe.deleted_at == nil`,
    /// `updateRecipeLineQty`/`tombstoneRecipeLine` check the line is live).
    /// Without it, editing a recipe tombstoned from another device enqueues
    /// an op the server refuses as `deleted`, which only Task 12's
    /// rejection-reason handling then parks as `needs_attention` -- correct,
    /// but a server round trip and a parked op for something knowable
    /// locally.
    @Test func updateRecipeFieldsOnTombstonedRecipeThrowsAndEnqueuesNothing() throws {
        let store = try seededStore([
            StoreTests.recipeChange(
                id: "rec-dead", name: "Bread", serverSeq: 1,
                deletedAt: "2026-07-29 10:00:00+00"),
        ])
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let before = try store.pendingCount()

        #expect(throws: KernelError.self) {
            try edits.updateRecipeFields(
                id: "rec-dead", name: "Renamed", menuPrice: nil, targetFcPct: nil)
        }

        #expect(try store.pendingCount() == before)
    }

    /// The same guard's other half: an id with no row at all (never pulled,
    /// or pruned) is not live either.
    @Test func updateRecipeFieldsOnUnknownRecipeThrowsAndEnqueuesNothing() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let before = try store.pendingCount()

        #expect(throws: KernelError.self) {
            try edits.updateRecipeFields(
                id: "rec-nope", name: "Renamed", menuPrice: nil, targetFcPct: nil)
        }

        #expect(try store.pendingCount() == before)
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

    // MARK: - tombstoneRecipe

    /// A live recipe ("Bread") with THREE live lines plus a fourth,
    /// already-tombstoned line, and a second recipe ("Other") with its own
    /// single live line -- the exact scenario the brief specifies, distinct
    /// from `recipeFixture()` (which only has two live lines on rec-1 and
    /// is shared by the other recipe-mutation tests above).
    private func tombstoneRecipeFixture() throws -> LocalStore {
        try seededStore([
            StoreTests.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
            StoreTests.ingredientChange(id: "ing-2", name: "Water", serverSeq: 2),
            StoreTests.ingredientChange(id: "ing-3", name: "Salt", serverSeq: 3),
            StoreTests.ingredientChange(id: "ing-4", name: "Yeast", serverSeq: 4),
            StoreTests.recipeChange(id: "rec-1", name: "Bread", serverSeq: 5),
            StoreTests.recipeChange(id: "rec-2", name: "Other", serverSeq: 6),
            StoreTests.recipeItemChange(id: "ri-1", recipeId: "rec-1", ingredientId: "ing-1", serverSeq: 7),
            StoreTests.recipeItemChange(id: "ri-2", recipeId: "rec-1", ingredientId: "ing-2", serverSeq: 8),
            StoreTests.recipeItemChange(id: "ri-3", recipeId: "rec-1", ingredientId: "ing-3", serverSeq: 9),
            StoreTests.recipeItemChange(
                id: "ri-4", recipeId: "rec-1", ingredientId: "ing-4", serverSeq: 10,
                deletedAt: "2026-07-29 10:00:00+00"),
            StoreTests.recipeItemChange(id: "ri-5", recipeId: "rec-2", ingredientId: "ing-1", serverSeq: 11),
        ])
    }

    @Test func tombstoneRecipeFansOutOneOpPerLiveLinePlusTheRecipeItselfInOneSharedTimestamp() throws {
        let store = try tombstoneRecipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try edits.tombstoneRecipe(id: "rec-1", now: now)

        let opsData = try store.exportPendingOps()
        let ops = try JSONDecoder().decode([PendingOp].self, from: opsData)
        #expect(ops.count == 4)

        let mutatedAt = Kernel.canonicalTimestamp(now)
        for op in ops {
            #expect(op.kind == .update)
            #expect(Set(op.fields.keys) == ["deleted_at"])
            #expect(fieldValue(op, "deleted_at") == mutatedAt)
        }
        // All four share the identical timestamp string.
        #expect(Set(ops.map { fieldValue($0, "deleted_at") }).count == 1)

        // (table, row_id) pairs are exactly the 3 live line ids on
        // recipe_items plus the recipe id on recipes -- the already-
        // tombstoned line (ri-4) gets no op (no double-tombstone), and the
        // second recipe (rec-2) plus its line (ri-5) are untouched.
        let pairs = Set(ops.map { "\($0.table):\($0.row_id)" })
        #expect(pairs == ["recipe_items:ri-1", "recipe_items:ri-2", "recipe_items:ri-3", "recipes:rec-1"])

        #expect(try store.liveRecipeItems(recipeId: "rec-1").isEmpty)
        #expect(try store.recipe(id: "rec-1")?.deleted_at == mutatedAt)
        #expect(try store.liveRecipes().map(\.id) == ["rec-2"])

        // The second recipe and its line are untouched: still live, no ops.
        #expect(try store.recipe(id: "rec-2")?.deleted_at == nil)
        #expect(try store.liveRecipeItems(recipeId: "rec-2").count == 1)

        // Calling tombstoneRecipe again throws KernelError and enqueues nothing.
        let before = try store.pendingCount()
        #expect(throws: KernelError.self) {
            try edits.tombstoneRecipe(id: "rec-1")
        }
        #expect(try store.pendingCount() == before)
    }

    @Test func tombstoneRecipeOnUnknownIdThrowsKernelErrorAndEnqueuesNothing() throws {
        let store = try tombstoneRecipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let before = try store.pendingCount()

        #expect(throws: KernelError.self) {
            try edits.tombstoneRecipe(id: "nope")
        }

        #expect(try store.pendingCount() == before)
    }

    /// Robust to future seeding changes: for a recipe seeded with N live
    /// lines, `tombstoneRecipe` must enqueue exactly N + 1 ops (one per
    /// live line, plus the recipe's own), regardless of what N is.
    @Test func tombstoneRecipeFanOutCompletenessForFiveLiveLines() throws {
        let n = 5
        var changes: [PullChange] = [
            StoreTests.recipeChange(id: "rec-big", name: "Big Recipe", serverSeq: 1),
        ]
        for i in 0..<n {
            changes.append(StoreTests.ingredientChange(id: "ing-big-\(i)", name: "Ing \(i)", serverSeq: Int64(2 + i)))
            changes.append(StoreTests.recipeItemChange(
                id: "ri-big-\(i)", recipeId: "rec-big", ingredientId: "ing-big-\(i)",
                serverSeq: Int64(2 + n + i)))
        }
        let store = try seededStore(changes)
        let edits = LocalEdits(store: store, locationId: "loc-1")

        try edits.tombstoneRecipe(id: "rec-big")

        let ops = try store.pendingOps(state: .queued)
        #expect(ops.count == n + 1)
    }

    // MARK: - saveNewRecipe

    @Test func saveNewRecipeWithTwoLinesEnqueuesThreeOpsInOneSharedTimestamp() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = RecipeDraft(
            name: "  Carbonara  ", menuPrice: "18.00", targetFcPct: "28.00",
            lines: [
                RecipeDraft.Line(ingredientId: "ing-1", qty: "2.0000"),
                RecipeDraft.Line(ingredientId: "ing-2", qty: "1.0000"),
            ])

        let recipeId = try edits.saveNewRecipe(draft, now: now)

        let opsData = try store.exportPendingOps()
        let ops = try JSONDecoder().decode([PendingOp].self, from: opsData)
        #expect(ops.count == 3)

        let recipeOp = try #require(ops.first { $0.table == "recipes" })
        #expect(recipeOp.row_id == recipeId)
        #expect(recipeOp.kind == .insert)
        #expect(Set(recipeOp.fields.keys) == ["name", "menu_price", "target_fc_pct"])
        #expect(fieldValue(recipeOp, "name") == "Carbonara")
        #expect(fieldValue(recipeOp, "menu_price") == "18.00")
        #expect(fieldValue(recipeOp, "target_fc_pct") == "28.00")

        let lineOps = ops.filter { $0.table == "recipe_items" }
        #expect(lineOps.count == 2)
        for lineOp in lineOps {
            #expect(lineOp.kind == .insert)
            #expect(Set(lineOp.fields.keys) == ["recipe_id", "ingredient_id", "qty_base_units"])
            #expect(fieldValue(lineOp, "recipe_id") == recipeId)
        }

        // All 3 ops share one timestamp.
        let mutatedAt = Kernel.canonicalTimestamp(now)
        #expect(Set(ops.map(\.client_mutated_at)) == [mutatedAt])
        #expect(Set(ops.map(\.created_at)) == [mutatedAt])

        // Immediately readable locally.
        #expect(try store.liveRecipes().contains { $0.id == recipeId })
        #expect(try store.liveRecipeItems(recipeId: recipeId).count == 2)
    }

    @Test func saveNewRecipeNamingTombstonedIngredientThrowsAndEnqueuesNothing() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let before = try store.pendingCount()
        let draft = RecipeDraft(
            name: "Sourdough", menuPrice: "10.00", targetFcPct: "30.00",
            lines: [
                RecipeDraft.Line(ingredientId: "ing-1", qty: "1"),
                RecipeDraft.Line(ingredientId: "ing-4", qty: "1"), // ing-4 (Yeast) is tombstoned
            ])

        #expect(throws: KernelError.self) {
            _ = try edits.saveNewRecipe(draft)
        }

        // The transaction rolled back: no op, and no recipe row, was left behind.
        #expect(try store.pendingCount() == before)
        #expect(try store.liveRecipes().map(\.name) == ["Bread", "Other"])
    }

    @Test func saveNewRecipeInvalidDraftThrowsFirstDraftErrorAndEnqueuesNothing() throws {
        let store = try recipeFixture()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let before = try store.pendingCount()
        // Wrong in two ways -- name empty AND no lines -- validate()'s first
        // error (declaration order) is nameEmpty.
        let draft = RecipeDraft(name: "", menuPrice: "10.00", targetFcPct: "30.00", lines: [])

        do {
            _ = try edits.saveNewRecipe(draft)
            Issue.record("expected saveNewRecipe to throw")
        } catch let error as RecipeDraft.DraftError {
            #expect(error == .nameEmpty)
        } catch {
            Issue.record("expected DraftError, got \(error)")
        }

        #expect(try store.pendingCount() == before)
    }
}

// MARK: - Phase 3a invoice helpers

@Suite struct InvoiceEditsTests {

    private func store() throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        return store
    }

    private func fieldValue(_ op: PendingOp, _ key: String) -> String? {
        op.fields[key] ?? nil
    }

    @Test func createInvoiceEnqueuesInsertWithCapturedAtAndUnparsedStatus() throws {
        let store = try store()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let id = try edits.createInvoice(now: now)

        let op = try #require(try store.pendingOps(state: .queued).first { $0.row_id == id })
        #expect(op.table == "invoices")
        #expect(op.kind == .insert)
        #expect(Set(op.fields.keys) == ["captured_at", "parse_status"])
        // 'unparsed' is the only status a device can produce; the schema
        // CHECK admits 'failed' too but only 3b's parser sets it.
        #expect(fieldValue(op, "parse_status") == "unparsed")
        #expect(fieldValue(op, "captured_at") == Kernel.canonicalTimestamp(now))
    }

    @Test func addInvoicePageDerivesTheSameStoragePathTheServerWill() throws {
        let store = try store()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let invoiceId = try edits.createInvoice()

        let (pageId, path) = try edits.addInvoicePage(
            invoiceId: invoiceId, pageNo: 1, orgId: "org-1")

        #expect(path == StoragePath.forPage(orgId: "org-1", invoiceId: invoiceId, pageNo: 1))
        let op = try #require(try store.pendingOps(state: .queued).first { $0.row_id == pageId })
        #expect(op.table == "invoice_pages")
        #expect(op.kind == .insert)
        #expect(Set(op.fields.keys) == ["invoice_id", "page_no", "storage_path"])
        #expect(fieldValue(op, "page_no") == "1")
    }

    /// The same liveness guard every other mutation runs. Without it, a page
    /// added to an invoice tombstoned on another device queues an op the
    /// server refuses, for something knowable locally.
    @Test func addInvoicePageOnTombstonedInvoiceThrowsAndEnqueuesNothing() throws {
        let store = try store()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let invoiceId = try edits.createInvoice()
        try edits.tombstoneInvoice(id: invoiceId)
        let before = try store.pendingCount()

        #expect(throws: KernelError.self) {
            _ = try edits.addInvoicePage(invoiceId: invoiceId, pageNo: 2, orgId: "org-1")
        }

        #expect(try store.pendingCount() == before)
    }

    @Test func addInvoicePageRefusesANonPositivePageNumber() throws {
        let store = try store()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let invoiceId = try edits.createInvoice()

        #expect(throws: KernelError.self) {
            _ = try edits.addInvoicePage(invoiceId: invoiceId, pageNo: 0, orgId: "org-1")
        }
    }

    /// Same fan-out shape as tombstoneRecipe: one deleted_at op per live
    /// page plus one for the invoice, all sharing a single timestamp, in one
    /// transaction. A tombstone op does not cascade server-side, so skipping
    /// the fan-out would strand live pages against a dead invoice.
    @Test func tombstoneInvoiceFansOutToEveryLivePage() throws {
        let store = try store()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let invoiceId = try edits.createInvoice()
        _ = try edits.addInvoicePage(invoiceId: invoiceId, pageNo: 1, orgId: "org-1")
        _ = try edits.addInvoicePage(invoiceId: invoiceId, pageNo: 2, orgId: "org-1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try edits.tombstoneInvoice(id: invoiceId, now: now)

        let stamp = Kernel.canonicalTimestamp(now)
        let tombstones = try store.pendingOps(state: .queued).filter {
            $0.kind == .update && (($0.fields["deleted_at"] ?? nil) == stamp)
        }
        #expect(tombstones.count == 3)  // two pages plus the invoice
        #expect(try store.livePages(invoiceId: invoiceId).isEmpty)
        #expect(try store.invoice(id: invoiceId)?.deleted_at == stamp)
    }

    @Test func tombstoneInvoiceOnAnAlreadyDeadInvoiceThrows() throws {
        let store = try store()
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let invoiceId = try edits.createInvoice()
        try edits.tombstoneInvoice(id: invoiceId)

        #expect(throws: KernelError.self) {
            try edits.tombstoneInvoice(id: invoiceId)
        }
    }
}
