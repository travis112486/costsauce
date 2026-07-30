import Testing
import Foundation
@testable import CostSauceKit

@Suite struct CostingTests {

    private static let ts = "2026-07-29T10:00:00.000000Z"

    private static func ingredient(
        id: String, name: String, baseUnit: String = "lb",
        vendor: String? = nil, category: String? = nil, deletedAt: String? = nil
    ) -> LocalIngredient {
        LocalIngredient(
            id: id, location_id: "loc-1", name: name, base_unit: baseUnit,
            vendor: vendor, category: category, source: nil,
            client_mutated_at: ts, server_seq: 1, updated_at: ts,
            deleted_at: deletedAt, created_at: ts)
    }

    private static func recipe(
        id: String, name: String, menuPrice: String = "10.00", targetFcPct: String = "30.00"
    ) -> LocalRecipe {
        LocalRecipe(
            id: id, location_id: "loc-1", name: name, menu_price: menuPrice,
            target_fc_pct: targetFcPct, client_mutated_at: ts, server_seq: 1,
            updated_at: ts, deleted_at: nil, created_at: ts)
    }

    private static func item(
        id: String, recipeId: String, ingredientId: String, qtyBaseUnits: String
    ) -> LocalRecipeItem {
        LocalRecipeItem(
            id: id, location_id: "loc-1", recipe_id: recipeId, ingredient_id: ingredientId,
            qty_base_units: qtyBaseUnits, client_mutated_at: ts, server_seq: 1,
            updated_at: ts, deleted_at: nil, created_at: ts)
    }

    private static func purchase(
        id: String, ingredientId: String, qty: String = "10", unit: String = "lb",
        qtyBaseUnits: String = "10.0000", totalPrice: String = "20.00", unitPrice: String? = nil,
        purchasedOn: String = "2026-07-29", recordedAt: String = ts, deletedAt: String? = nil
    ) -> LocalPurchase {
        LocalPurchase(
            id: id, location_id: "loc-1", ingredient_id: ingredientId, purchased_on: purchasedOn,
            recorded_at: recordedAt, qty: qty, unit: unit, qty_in_case: nil,
            qty_base_units: qtyBaseUnits, total_price: totalPrice, unit_price: unitPrice,
            source: nil, client_mutated_at: ts, server_seq: 1, updated_at: ts,
            deleted_at: deletedAt, created_at: ts)
    }

    private static func drift(latestPrice: String) -> DriftResult {
        DriftResult(
            latestPrice: latestPrice, latestOn: "2026-07-01", windowStart: "2026-04-02",
            baselineN: 0, trailingAvg: nil, driftPct: nil)
    }

    // MARK: - round each item THEN sum (costing.py:77-79)

    @Test func roundEachItemThenSumDiffersFromSumThenRound() throws {
        let ingredients = [
            Self.ingredient(id: "ing-a", name: "A"),
            Self.ingredient(id: "ing-b", name: "B"),
        ]
        let items = [
            Self.item(id: "item-1", recipeId: "rec-1", ingredientId: "ing-a", qtyBaseUnits: "0.6700"),
            Self.item(id: "item-2", recipeId: "rec-1", ingredientId: "ing-b", qtyBaseUnits: "0.6700"),
        ]
        let recipes = [Self.recipe(id: "rec-1", name: "Two Item")]
        let drift = [
            "ing-a": Self.drift(latestPrice: "1.500000"),
            "ing-b": Self.drift(latestPrice: "1.500000"),
        ]

        let costed = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)
        let recipe = try #require(costed.first)

        // Each item's exact cost is 0.6700 * 1.500000 = 1.005 -- exactly
        // halfway, rounds half-away-from-zero UP to "1.01" per item.
        #expect(recipe.items.map(\.cost) == ["1.01", "1.01"])
        // Round-then-sum: 1.01 + 1.01 = "2.02". Sum-then-round of the exact
        // products (1.005 + 1.005 = 2.010) would instead read "2.01" -- this
        // proves the implementation rounds each item BEFORE summing.
        #expect(recipe.plateCost == "2.02")
    }

    // MARK: - completeness (spec §10.1)

    @Test func tombstonedIngredientItemIsUnresolvableButOtherItemStillCosted() throws {
        let ingredients = [
            Self.ingredient(id: "ing-a", name: "Live One"),
            Self.ingredient(id: "ing-b", name: "Gone", deletedAt: Self.ts),
        ]
        let items = [
            Self.item(id: "item-1", recipeId: "rec-1", ingredientId: "ing-a", qtyBaseUnits: "2.0000"),
            Self.item(id: "item-2", recipeId: "rec-1", ingredientId: "ing-b", qtyBaseUnits: "1.0000"),
        ]
        let recipes = [Self.recipe(id: "rec-1", name: "Partial")]
        // Both ingredients have drift entries -- proves the tombstoned
        // item is unresolvable because of liveness, not a missing drift.
        let drift = [
            "ing-a": Self.drift(latestPrice: "3.000000"),
            "ing-b": Self.drift(latestPrice: "9.000000"),
        ]

        let costed = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)
        let recipe = try #require(costed.first)

        #expect(recipe.complete == false)
        #expect(recipe.fcPct == nil)
        #expect(recipe.status == nil)
        #expect(recipe.suggestedPrice == nil)

        let liveItem = try #require(recipe.items.first { $0.ingredientId == "ing-a" })
        #expect(liveItem.isResolvable == true)
        #expect(liveItem.cost == "6.00")

        let tombstonedItem = try #require(recipe.items.first { $0.ingredientId == "ing-b" })
        #expect(tombstonedItem.isResolvable == false)
        #expect(tombstonedItem.cost == nil)
        #expect(tombstonedItem.unitPrice == nil)
        // Server parity: the LEFT JOIN still surfaces name/base_unit for a
        // tombstoned ingredient row -- only is_resolvable flips.
        #expect(tombstonedItem.name == "Gone")

        // Partial plate: only the resolvable item's cost counts.
        #expect(recipe.plateCost == "6.00")
    }

    @Test func ingredientWithZeroPurchasesIsUnresolvable() throws {
        let ingredients = [Self.ingredient(id: "ing-c", name: "No Purchases")]
        let items = [
            Self.item(id: "item-1", recipeId: "rec-1", ingredientId: "ing-c", qtyBaseUnits: "1.0000"),
        ]
        let recipes = [Self.recipe(id: "rec-1", name: "Empty History")]
        let drift: [String: DriftResult] = [:]   // no purchases -> no drift entry at all

        let costed = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)
        let recipe = try #require(costed.first)
        let item = try #require(recipe.items.first)

        #expect(item.isResolvable == false)
        #expect(item.cost == nil)
        #expect(item.unitPrice == nil)
        #expect(recipe.complete == false)
    }

    // MARK: - suggestedPrice formatting

    @Test func suggestedPriceFormatsViaMoneyFromCentsNeverOneDecimalPlace() throws {
        let ingredients = [Self.ingredient(id: "ing-d", name: "D")]
        let items = [
            Self.item(id: "item-1", recipeId: "rec-1", ingredientId: "ing-d", qtyBaseUnits: "1.0000"),
        ]
        // qty 1.0000 * price 1.200000 = 1.20 -> plateCents 120 -> target
        // 30.00% -> ceil(120*10000 / (3000*50))*50 = 400 cents exactly.
        let recipes = [Self.recipe(id: "rec-1", name: "Whole Dollar", menuPrice: "5.00", targetFcPct: "30.00")]
        let drift = ["ing-d": Self.drift(latestPrice: "1.200000")]

        let costed = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)
        let recipe = try #require(costed.first)

        #expect(recipe.complete == true)
        #expect(recipe.suggestedPrice == "4.00")
    }

    // MARK: - driftByIngredient: unsynced vs synced pricing parity

    @Test func unsyncedPurchasePricesIdenticallyToSyncedPurchase() throws {
        let unsynced = Self.purchase(
            id: "pu-unsynced", ingredientId: "ing-x", qty: "10", unit: "lb",
            qtyBaseUnits: "10.0000", totalPrice: "20.00", unitPrice: nil)
        let synced = Self.purchase(
            id: "pu-synced", ingredientId: "ing-y", qty: "10", unit: "lb",
            qtyBaseUnits: "10.0000", totalPrice: "20.00", unitPrice: "2.000000")

        let drift = Costing.driftByIngredient(purchases: [unsynced, synced])

        let unsyncedPrice = try #require(drift["ing-x"]?.latestPrice)
        let syncedPrice = try #require(drift["ing-y"]?.latestPrice)
        #expect(unsyncedPrice == syncedPrice)
        #expect(unsyncedPrice == "2.000000")
    }

    // MARK: - previewPlate: parity with costRecipes (transitive pinning)

    /// Same round-then-sum fixture as
    /// `roundEachItemThenSumDiffersFromSumThenRound`, driven through
    /// `previewPlate` instead of stored rows. This is the case that fails
    /// if the implementation sums first: sum-then-round of the exact
    /// products (1.005 + 1.005 = 2.010) would read "2.01".
    @Test func previewPlateMatchesCostRecipesRoundThenSumFixture() throws {
        let ingredients = [
            Self.ingredient(id: "ing-a", name: "A"),
            Self.ingredient(id: "ing-b", name: "B"),
        ]
        let items = [
            Self.item(id: "item-1", recipeId: "rec-1", ingredientId: "ing-a", qtyBaseUnits: "0.6700"),
            Self.item(id: "item-2", recipeId: "rec-1", ingredientId: "ing-b", qtyBaseUnits: "0.6700"),
        ]
        let recipes = [Self.recipe(id: "rec-1", name: "Two Item")]
        let drift = [
            "ing-a": Self.drift(latestPrice: "1.500000"),
            "ing-b": Self.drift(latestPrice: "1.500000"),
        ]

        let costed = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)
        let expected = try #require(costed.first)

        let lines = items.map { (ingredientId: $0.ingredient_id, qty: $0.qty_base_units) }
        let preview = try Costing.previewPlate(
            lines: lines, menuPrice: nil, targetFcPct: nil,
            ingredients: ingredients, drift: drift)

        #expect(preview.plateCost == expected.plateCost)
        #expect(preview.complete == expected.complete)
        #expect(preview.plateCost == "2.02")
    }

    /// Same tombstoned-ingredient fixture as
    /// `tombstonedIngredientItemIsUnresolvableButOtherItemStillCosted`:
    /// the unresolvable line contributes nothing to `plateCost`, and
    /// `complete` flips false without repricing the resolvable remainder.
    @Test func previewPlateMatchesCostRecipesTombstonedIngredientFixture() throws {
        let ingredients = [
            Self.ingredient(id: "ing-a", name: "Live One"),
            Self.ingredient(id: "ing-b", name: "Gone", deletedAt: Self.ts),
        ]
        let items = [
            Self.item(id: "item-1", recipeId: "rec-1", ingredientId: "ing-a", qtyBaseUnits: "2.0000"),
            Self.item(id: "item-2", recipeId: "rec-1", ingredientId: "ing-b", qtyBaseUnits: "1.0000"),
        ]
        let recipes = [Self.recipe(id: "rec-1", name: "Partial")]
        let drift = [
            "ing-a": Self.drift(latestPrice: "3.000000"),
            "ing-b": Self.drift(latestPrice: "9.000000"),
        ]

        let costed = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)
        let expected = try #require(costed.first)

        let lines = items.map { (ingredientId: $0.ingredient_id, qty: $0.qty_base_units) }
        let preview = try Costing.previewPlate(
            lines: lines, menuPrice: recipes[0].menu_price, targetFcPct: recipes[0].target_fc_pct,
            ingredients: ingredients, drift: drift)

        #expect(preview.plateCost == expected.plateCost)
        #expect(preview.complete == expected.complete)
        #expect(preview.plateCost == "6.00")
        #expect(preview.complete == false)
        #expect(preview.fcPct == nil)
        #expect(preview.status == nil)
        #expect(preview.suggestedPrice == nil)
    }

    /// Same no-drift-entry fixture as
    /// `ingredientWithZeroPurchasesIsUnresolvable`: an ingredient with no
    /// purchase history is unresolvable, same as a tombstoned one.
    @Test func previewPlateMatchesCostRecipesNoDriftEntryFixture() throws {
        let ingredients = [Self.ingredient(id: "ing-c", name: "No Purchases")]
        let items = [
            Self.item(id: "item-1", recipeId: "rec-1", ingredientId: "ing-c", qtyBaseUnits: "1.0000"),
        ]
        let recipes = [Self.recipe(id: "rec-1", name: "Empty History")]
        let drift: [String: DriftResult] = [:]

        let costed = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)
        let expected = try #require(costed.first)

        let lines = items.map { (ingredientId: $0.ingredient_id, qty: $0.qty_base_units) }
        let preview = try Costing.previewPlate(
            lines: lines, menuPrice: recipes[0].menu_price, targetFcPct: recipes[0].target_fc_pct,
            ingredients: ingredients, drift: drift)

        #expect(preview.plateCost == expected.plateCost)
        #expect(preview.complete == expected.complete)
        #expect(preview.plateCost == "0.00")
        #expect(preview.complete == false)
    }

    /// Same whole-dollar fixture as
    /// `suggestedPriceFormatsViaMoneyFromCentsNeverOneDecimalPlace`: proves
    /// `previewPlate`'s `suggestedPrice` matches `costRecipes`' exactly,
    /// including formatting as "4.00" and never "4.0".
    @Test func previewPlateMatchesCostRecipesSuggestedPriceWholeDollarFixture() throws {
        let ingredients = [Self.ingredient(id: "ing-d", name: "D")]
        let items = [
            Self.item(id: "item-1", recipeId: "rec-1", ingredientId: "ing-d", qtyBaseUnits: "1.0000"),
        ]
        let recipes = [Self.recipe(id: "rec-1", name: "Whole Dollar", menuPrice: "5.00", targetFcPct: "30.00")]
        let drift = ["ing-d": Self.drift(latestPrice: "1.200000")]

        let costed = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)
        let expected = try #require(costed.first)

        let lines = items.map { (ingredientId: $0.ingredient_id, qty: $0.qty_base_units) }
        let preview = try Costing.previewPlate(
            lines: lines, menuPrice: recipes[0].menu_price, targetFcPct: recipes[0].target_fc_pct,
            ingredients: ingredients, drift: drift)

        #expect(preview.plateCost == expected.plateCost)
        #expect(preview.complete == expected.complete)
        #expect(preview.fcPct == expected.fcPct)
        #expect(preview.status == expected.status)
        #expect(preview.suggestedPrice == expected.suggestedPrice)
        #expect(preview.suggestedPrice == "4.00")
    }

    /// A resolvable line alongside one whose ingredient has no drift entry
    /// (distinct from tombstoning -- the ingredient is live, it simply has
    /// no purchase history yet): `complete` is false, and `plateCost` is
    /// the resolvable line's cost alone, not zero.
    @Test func lineWithNoDriftEntryIsUnresolvableButResolvableLineStillCounted() throws {
        let ingredients = [
            Self.ingredient(id: "ing-g", name: "Has History"),
            Self.ingredient(id: "ing-h", name: "No History"),
        ]
        let lines: [(ingredientId: String, qty: String)] = [
            (ingredientId: "ing-g", qty: "2.0000"),
            (ingredientId: "ing-h", qty: "5.0000"),
        ]
        let drift = ["ing-g": Self.drift(latestPrice: "3.000000")]  // no entry for ing-h

        let preview = try Costing.previewPlate(
            lines: lines, menuPrice: "18.00", targetFcPct: "30.00",
            ingredients: ingredients, drift: drift)

        #expect(preview.complete == false)
        #expect(preview.plateCost == "6.00")
        #expect(preview.fcPct == nil)
        #expect(preview.status == nil)
        #expect(preview.suggestedPrice == nil)
    }

    // MARK: - previewPlate: draft-only behaviors costRecipes has no equivalent for

    @Test func zeroLinesProduceZeroPlateCostAndIncompleteWithNilOptionals() throws {
        let preview = try Costing.previewPlate(
            lines: [], menuPrice: "18.00", targetFcPct: "30.00",
            ingredients: [], drift: [:])

        #expect(preview.plateCost == "0.00")
        #expect(preview.complete == false)
        #expect(preview.fcPct == nil)
        #expect(preview.status == nil)
        #expect(preview.suggestedPrice == nil)
    }

    /// Complete lines with a menu price and target: `fcPct`/`status`/
    /// `suggestedPrice` must equal what `Kernel.fcStatus`/
    /// `Kernel.suggestedPriceCents` themselves return for the same cents --
    /// computed here from the kernel, not hardcoded, so this can't silently
    /// decouple from the pinned primitives.
    @Test func completeLinesWithMenuPriceProduceFcFieldsMatchingKernelDirectly() throws {
        let ingredients = [Self.ingredient(id: "ing-e", name: "E")]
        let lines: [(ingredientId: String, qty: String)] = [(ingredientId: "ing-e", qty: "2.0000")]
        let drift = ["ing-e": Self.drift(latestPrice: "3.000000")]

        let preview = try Costing.previewPlate(
            lines: lines, menuPrice: "18.00", targetFcPct: "30.00",
            ingredients: ingredients, drift: drift)

        #expect(preview.complete == true)
        #expect(preview.plateCost == "6.00")

        let plateCents = try Kernel.centsFromString(preview.plateCost)
        let menuCents = try Kernel.centsFromString("18.00")
        let targetBp = try Kernel.bpFromString("30.00")
        let (expectedFc, expectedStatus) = try Kernel.fcStatus(
            plateCents: plateCents, menuCents: menuCents, targetBp: targetBp)
        let expectedSuggested = Kernel.moneyFromCents(
            try Kernel.suggestedPriceCents(plateCents: plateCents, targetBp: targetBp))

        #expect(preview.fcPct == expectedFc)
        #expect(preview.status == expectedStatus)
        #expect(preview.suggestedPrice == expectedSuggested)
    }

    /// `menuPrice: nil` (with `targetFcPct` also unset) leaves the plate
    /// cost visible but never reprices -- §10.1 applies to missing pricing
    /// inputs, not just unresolvable lines.
    @Test func completeLinesWithNilMenuPriceLeaveFcFieldsNil() throws {
        let ingredients = [Self.ingredient(id: "ing-f", name: "F")]
        let lines: [(ingredientId: String, qty: String)] = [(ingredientId: "ing-f", qty: "1.0000")]
        let drift = ["ing-f": Self.drift(latestPrice: "2.500000")]

        let preview = try Costing.previewPlate(
            lines: lines, menuPrice: nil, targetFcPct: nil,
            ingredients: ingredients, drift: drift)

        #expect(preview.complete == true)
        #expect(preview.plateCost == "2.50")
        #expect(preview.fcPct == nil)
        #expect(preview.status == nil)
        #expect(preview.suggestedPrice == nil)
    }
}
