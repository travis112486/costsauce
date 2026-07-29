import Testing
import Foundation
@testable import CostSauceKit

@Suite struct DashboardTests {

    private static let ts = "2026-07-29T10:00:00.000000Z"

    private static func ingredient(id: String, name: String, deletedAt: String? = nil) -> LocalIngredient {
        LocalIngredient(
            id: id, location_id: "loc-1", name: name, base_unit: "lb",
            vendor: nil, category: nil, source: nil,
            client_mutated_at: ts, server_seq: 1, updated_at: ts,
            deleted_at: deletedAt, created_at: ts)
    }

    private static func recipe(id: String, name: String, menuPrice: String = "10.00", targetFcPct: String = "30.00") -> LocalRecipe {
        LocalRecipe(
            id: id, location_id: "loc-1", name: name, menu_price: menuPrice,
            target_fc_pct: targetFcPct, client_mutated_at: ts, server_seq: 1,
            updated_at: ts, deleted_at: nil, created_at: ts)
    }

    private static func item(id: String, recipeId: String, ingredientId: String, qtyBaseUnits: String = "1.0000") -> LocalRecipeItem {
        LocalRecipeItem(
            id: id, location_id: "loc-1", recipe_id: recipeId, ingredient_id: ingredientId,
            qty_base_units: qtyBaseUnits, client_mutated_at: ts, server_seq: 1,
            updated_at: ts, deleted_at: nil, created_at: ts)
    }

    /// `qtyBaseUnits`/`totalPrice` are chosen so the row's unit price is
    /// `totalPrice` (qty_base_units "1.0000" -- unit price = total_price
    /// rounded to 6dp).
    private static func purchase(
        id: String, ingredientId: String, purchasedOn: String, totalPrice: String
    ) -> LocalPurchase {
        LocalPurchase(
            id: id, location_id: "loc-1", ingredient_id: ingredientId, purchased_on: purchasedOn,
            recorded_at: "\(purchasedOn)T10:00:00.000000Z", qty: "1", unit: "lb", qty_in_case: nil,
            qty_base_units: "1.0000", total_price: totalPrice, unit_price: nil, source: nil,
            client_mutated_at: ts, server_seq: 1, updated_at: ts, deleted_at: nil, created_at: ts)
    }

    // MARK: - movers: baseline floor

    @Test func moverOmittedWhenBaselineNBelowThree() throws {
        let ingredients = [Self.ingredient(id: "ing-1", name: "Thin History")]
        let purchases = [
            Self.purchase(id: "pu-latest", ingredientId: "ing-1", purchasedOn: "2026-07-29", totalPrice: "3.00"),
            Self.purchase(id: "pu-baseline-1", ingredientId: "ing-1", purchasedOn: "2026-07-20", totalPrice: "2.00"),
        ]
        let model = try DashboardModel.build(
            ingredients: ingredients, purchases: purchases, recipes: [], items: [],
            driftThresholdPct: "10.00")

        #expect(model.topMovers.isEmpty)
        #expect(model.alerts.isEmpty)
    }

    // MARK: - movers: direction

    @Test func directionIsDownForZeroDriftPct() throws {
        let ingredients = [Self.ingredient(id: "ing-1", name: "Flat")]
        let purchases = [
            Self.purchase(id: "pu-latest", ingredientId: "ing-1", purchasedOn: "2026-07-29", totalPrice: "2.00"),
            Self.purchase(id: "pu-b1", ingredientId: "ing-1", purchasedOn: "2026-07-20", totalPrice: "2.00"),
            Self.purchase(id: "pu-b2", ingredientId: "ing-1", purchasedOn: "2026-07-10", totalPrice: "2.00"),
            Self.purchase(id: "pu-b3", ingredientId: "ing-1", purchasedOn: "2026-06-30", totalPrice: "2.00"),
        ]
        let model = try DashboardModel.build(
            ingredients: ingredients, purchases: purchases, recipes: [], items: [],
            driftThresholdPct: "10.00")

        let mover = try #require(model.topMovers.first)
        #expect(mover.driftPct == "0.0")
        #expect(mover.direction == "down")
    }

    // MARK: - movers: tombstoned ingredients excluded (dashboard.py:26-27 parity)

    @Test func tombstonedIngredientExcludedFromMoversEvenWithDriftWorthyHistory() throws {
        // Same +50.0% drift-worthy history as `tieSortByNameThenIngredientId`
        // below -- proves exclusion is driven by liveness, not by a missing
        // drift entry.
        let ingredients = [
            Self.ingredient(id: "ing-gone", name: "Tombstoned", deletedAt: Self.ts),
        ]
        let purchases = [
            Self.purchase(id: "pu-latest", ingredientId: "ing-gone", purchasedOn: "2026-07-29", totalPrice: "3.00"),
            Self.purchase(id: "pu-b1", ingredientId: "ing-gone", purchasedOn: "2026-07-20", totalPrice: "2.00"),
            Self.purchase(id: "pu-b2", ingredientId: "ing-gone", purchasedOn: "2026-07-10", totalPrice: "2.00"),
            Self.purchase(id: "pu-b3", ingredientId: "ing-gone", purchasedOn: "2026-06-30", totalPrice: "2.00"),
        ]
        let model = try DashboardModel.build(
            ingredients: ingredients, purchases: purchases, recipes: [], items: [],
            driftThresholdPct: "0.00")

        #expect(model.topMovers.isEmpty)
        #expect(model.alerts.isEmpty)
    }

    // MARK: - menuItems: tombstoned ingredient keeps its real name (LEFT-JOIN parity)

    @Test func menuItemForTombstonedIngredientKeepsRealNameAndBaseUnitButIsIncomplete() throws {
        // `ingredients` is the UNFILTERED (LocalStore.allIngredients()) set
        // build's contract now requires: it must include the tombstoned
        // row for costRecipes to resolve its name/base_unit, while the
        // movers loop filters it out internally (covered above).
        let ingredients = [
            Self.ingredient(id: "ing-live", name: "Live One"),
            Self.ingredient(id: "ing-gone", name: "Discontinued Ingredient", deletedAt: Self.ts),
        ]
        let purchases = [
            Self.purchase(id: "pu-live", ingredientId: "ing-live", purchasedOn: "2026-07-29", totalPrice: "3.00"),
            Self.purchase(id: "pu-gone", ingredientId: "ing-gone", purchasedOn: "2026-07-29", totalPrice: "9.00"),
        ]
        let recipes = [Self.recipe(id: "rec-1", name: "Broken Recipe")]
        let items = [
            Self.item(id: "item-live", recipeId: "rec-1", ingredientId: "ing-live"),
            Self.item(id: "item-gone", recipeId: "rec-1", ingredientId: "ing-gone"),
        ]

        let model = try DashboardModel.build(
            ingredients: ingredients, purchases: purchases, recipes: recipes, items: items,
            driftThresholdPct: "10.00")

        let recipe = try #require(model.menuItems.first)
        #expect(recipe.complete == false)

        let brokenItem = try #require(recipe.items.first { $0.ingredientId == "ing-gone" })
        #expect(brokenItem.isResolvable == false)
        #expect(brokenItem.name == "Discontinued Ingredient")
        #expect(brokenItem.baseUnit == "lb")

        // And the tombstoned ingredient still doesn't leak into movers.
        #expect(model.topMovers.allSatisfy { $0.ingredientId != "ing-gone" })
    }

    // MARK: - movers: sort tie-break

    @Test func tieSortByNameThenIngredientId() throws {
        // Three ingredients, each with an identical +50.0% drift: avg
        // 2.000000 from three baseline rows, latest 3.000000.
        func fiftyPercentUpHistory(ingredientId: String) -> [LocalPurchase] {
            [
                Self.purchase(id: "\(ingredientId)-latest", ingredientId: ingredientId, purchasedOn: "2026-07-29", totalPrice: "3.00"),
                Self.purchase(id: "\(ingredientId)-b1", ingredientId: ingredientId, purchasedOn: "2026-07-20", totalPrice: "2.00"),
                Self.purchase(id: "\(ingredientId)-b2", ingredientId: ingredientId, purchasedOn: "2026-07-10", totalPrice: "2.00"),
                Self.purchase(id: "\(ingredientId)-b3", ingredientId: ingredientId, purchasedOn: "2026-06-30", totalPrice: "2.00"),
            ]
        }
        let ingredients = [
            Self.ingredient(id: "z-2", name: "Same Name"),
            Self.ingredient(id: "z-1", name: "Same Name"),
            Self.ingredient(id: "a-1", name: "Alpha"),
        ]
        let purchases = fiftyPercentUpHistory(ingredientId: "z-2")
            + fiftyPercentUpHistory(ingredientId: "z-1")
            + fiftyPercentUpHistory(ingredientId: "a-1")

        let model = try DashboardModel.build(
            ingredients: ingredients, purchases: purchases, recipes: [], items: [],
            driftThresholdPct: "999.00")

        #expect(model.topMovers.allSatisfy { $0.driftPct == "50.0" })
        // Equal |driftPct| across all three -> name ASC ("Alpha" < "Same
        // Name"), then within "Same Name" -> id ASC ("z-1" < "z-2").
        #expect(model.topMovers.map(\.ingredientId) == ["a-1", "z-1", "z-2"])
    }

    // MARK: - alerts: boundary equality across string formats

    @Test func alertBoundaryFiresWhenDriftPctEqualsThresholdAcrossFormats() throws {
        let ingredients = [Self.ingredient(id: "ing-1", name: "Right At The Line")]
        let purchases = [
            Self.purchase(id: "pu-latest", ingredientId: "ing-1", purchasedOn: "2026-07-29", totalPrice: "11.00"),
            Self.purchase(id: "pu-b1", ingredientId: "ing-1", purchasedOn: "2026-07-20", totalPrice: "10.00"),
            Self.purchase(id: "pu-b2", ingredientId: "ing-1", purchasedOn: "2026-07-10", totalPrice: "10.00"),
            Self.purchase(id: "pu-b3", ingredientId: "ing-1", purchasedOn: "2026-06-30", totalPrice: "10.00"),
        ]
        let model = try DashboardModel.build(
            ingredients: ingredients, purchases: purchases, recipes: [], items: [],
            driftThresholdPct: "10.00")

        let mover = try #require(model.topMovers.first)
        #expect(mover.driftPct == "10.0")
        // "10.0" (drift_pct, 1dp) vs "10.00" (threshold, 2dp) -- same exact
        // Rational value across differing string formats -- must still fire.
        #expect(model.alerts.map(\.ingredientId) == ["ing-1"])
    }

    // MARK: - avgFcPct: exact-Rational mean, half-away rounding

    @Test func avgFcPctOfThirtyAndThirtyPointOneRoundsHalfAwayToThirtyPointOne() throws {
        let ingredients = [
            Self.ingredient(id: "ing-a", name: "A"),
            Self.ingredient(id: "ing-b", name: "B"),
        ]
        let purchases = [
            // fc = 3.00 * 100 / 10.00 = 30.0.
            Self.purchase(id: "pu-a", ingredientId: "ing-a", purchasedOn: "2026-07-29", totalPrice: "3.00"),
            // fc = 3.01 * 100 / 10.00 = 30.1.
            Self.purchase(id: "pu-b", ingredientId: "ing-b", purchasedOn: "2026-07-29", totalPrice: "3.01"),
        ]
        let recipes = [
            Self.recipe(id: "rec-a", name: "Recipe A"),
            Self.recipe(id: "rec-b", name: "Recipe B"),
        ]
        let items = [
            Self.item(id: "item-a", recipeId: "rec-a", ingredientId: "ing-a"),
            Self.item(id: "item-b", recipeId: "rec-b", ingredientId: "ing-b"),
        ]

        let model = try DashboardModel.build(
            ingredients: ingredients, purchases: purchases, recipes: recipes, items: items,
            driftThresholdPct: "999.00")

        #expect(model.menuItems.allSatisfy { $0.complete })
        #expect(Set(model.menuItems.map(\.fcPct)) == ["30.0", "30.1"])
        // (30.0 + 30.1) / 2 = 30.05 -- rounds half-away-from-zero UP to 30.1.
        #expect(model.summary.avgFcPct == "30.1")
    }

    // MARK: - summary counts, including incomplete

    @Test func summaryCountsCoverEveryStatusAndIncomplete() throws {
        let ingredients = [
            Self.ingredient(id: "ing-ok", name: "OK Ingredient"),
            Self.ingredient(id: "ing-watch", name: "Watch Ingredient"),
            Self.ingredient(id: "ing-danger", name: "Danger Ingredient"),
            Self.ingredient(id: "ing-incomplete", name: "No History Ingredient"),
        ]
        let purchases = [
            // fc = 1.00 * 100 / 10.00 = 10.0 <= target 30.0 -> ok.
            Self.purchase(id: "pu-ok", ingredientId: "ing-ok", purchasedOn: "2026-07-29", totalPrice: "1.00"),
            // fc = 3.10 * 100 / 10.00 = 31.0, in (30.0, 32.0] -> watch.
            Self.purchase(id: "pu-watch", ingredientId: "ing-watch", purchasedOn: "2026-07-29", totalPrice: "3.10"),
            // fc = 5.00 * 100 / 10.00 = 50.0 > 32.0 -> danger.
            Self.purchase(id: "pu-danger", ingredientId: "ing-danger", purchasedOn: "2026-07-29", totalPrice: "5.00"),
            // ing-incomplete has no purchase at all.
        ]
        let recipes = [
            Self.recipe(id: "rec-ok", name: "R OK"),
            Self.recipe(id: "rec-watch", name: "R Watch"),
            Self.recipe(id: "rec-danger", name: "R Danger"),
            Self.recipe(id: "rec-incomplete", name: "R Incomplete"),
        ]
        let items = [
            Self.item(id: "item-ok", recipeId: "rec-ok", ingredientId: "ing-ok"),
            Self.item(id: "item-watch", recipeId: "rec-watch", ingredientId: "ing-watch"),
            Self.item(id: "item-danger", recipeId: "rec-danger", ingredientId: "ing-danger"),
            Self.item(id: "item-incomplete", recipeId: "rec-incomplete", ingredientId: "ing-incomplete"),
        ]

        let model = try DashboardModel.build(
            ingredients: ingredients, purchases: purchases, recipes: recipes, items: items,
            driftThresholdPct: "999.00")

        #expect(model.summary.okCount == 1)
        #expect(model.summary.watchCount == 1)
        #expect(model.summary.dangerCount == 1)
        #expect(model.summary.incompleteCount == 1)
        #expect(model.menuItems.count == 4)
    }
}
