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
}
