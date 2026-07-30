// The CostSauce local costing engine.
//
// Exact mirror of api/services/costing.py:46-104 -- the ONE authoritative
// math implementation is the kernel (Kernel/Kernel.swift, Kernel/Drift.swift);
// this file is pure orchestration/shaping over already-local rows, same
// division of labor as the Python service is over already-fetched SQL rows.
// All decimals stay STRINGS at the boundary; every arithmetic step goes
// through `Rational`/`Kernel`, never `Double`/`Float`/`Decimal`.

import Foundation

public struct CostedItem: Equatable, Sendable {
    public let id: String
    public let ingredientId: String
    public let name: String?
    public let baseUnit: String?
    public let qtyBaseUnits: String
    public let unitPrice: String?
    public let cost: String?
    public let isResolvable: Bool

    public init(
        id: String, ingredientId: String, name: String?, baseUnit: String?,
        qtyBaseUnits: String, unitPrice: String?, cost: String?, isResolvable: Bool
    ) {
        self.id = id
        self.ingredientId = ingredientId
        self.name = name
        self.baseUnit = baseUnit
        self.qtyBaseUnits = qtyBaseUnits
        self.unitPrice = unitPrice
        self.cost = cost
        self.isResolvable = isResolvable
    }
}

public struct CostedRecipe: Equatable, Sendable {
    public let recipeId: String
    public let name: String
    public let menuPrice: String
    public let targetFcPct: String
    public let plateCost: String
    public let fcPct: String?
    public let status: String?
    public let suggestedPrice: String?
    public let complete: Bool
    public let items: [CostedItem]

    public init(
        recipeId: String, name: String, menuPrice: String, targetFcPct: String,
        plateCost: String, fcPct: String?, status: String?, suggestedPrice: String?,
        complete: Bool, items: [CostedItem]
    ) {
        self.recipeId = recipeId
        self.name = name
        self.menuPrice = menuPrice
        self.targetFcPct = targetFcPct
        self.plateCost = plateCost
        self.fcPct = fcPct
        self.status = status
        self.suggestedPrice = suggestedPrice
        self.complete = complete
        self.items = items
    }
}

public enum Costing {

    /// Groups live purchases by `ingredient_id` and runs `Kernel.drift` per
    /// group. Each row's price is `Kernel.unitPrice(total_price,
    /// qty_base_units)` -- NEVER the stored `unit_price` column (Task 5's
    /// note on `LocalPurchase.unit_price`: it's nil until the first pull
    /// echoes a locally-created purchase back, and local costing must price
    /// an unsynced purchase identically to a synced one). `recorded_at` is
    /// already canonical (Records.swift canonicalizes it on pull;
    /// `LocalEdits.createPurchase` stamps it canonical on create), so it's
    /// passed straight through to `PurchaseRow`. Mirrors
    /// api/services/costing.py's `location_drift`.
    public static func driftByIngredient(purchases: [LocalPurchase]) -> [String: DriftResult] {
        var byIngredient: [String: [PurchaseRow]] = [:]
        for p in purchases {
            // total_price/qty_base_units are already-validated positive
            // decimal strings -- produced by Kernel.normalizePurchase at
            // creation time (LocalEdits.createPurchase), or echoed back
            // from the server's own generated column on pull. A parse/
            // divide failure here would mean corrupted upstream data, not
            // a normal error path, so this mirrors Drift.swift's identical
            // `try!` idiom (see its doc comment) rather than adding
            // `throws` to this frozen, non-throwing signature.
            let unitPrice = try! Kernel.unitPrice(
                totalPrice: p.total_price, qtyBaseUnits: p.qty_base_units)
            let row = PurchaseRow(
                purchasedOn: p.purchased_on, recordedAt: p.recorded_at, id: p.id,
                unitPrice: unitPrice, deleted: p.deleted_at != nil)
            byIngredient[p.ingredient_id, default: []].append(row)
        }
        var result: [String: DriftResult] = [:]
        for (ingredientId, rows) in byIngredient {
            if let d = Kernel.drift(rows) {
                result[ingredientId] = d
            }
        }
        return result
    }

    /// One line's cost -- shared by `costRecipes` and `previewPlate` so the
    /// rounding order (round each line, THEN sum) lives in exactly one
    /// place. Resolvable iff the ingredient is present AND live
    /// (`deleted_at == nil`) AND `drift` has an entry for it (spec §10.1).
    /// An unresolvable line contributes no cents.
    private static func costLine(
        ingredientId: String, qtyBaseUnits: String,
        ingredient: LocalIngredient?, drift: [String: DriftResult]
    ) throws -> (resolvable: Bool, unitPrice: String?, cost: String?, cents: Int) {
        let ingredientLive = ingredient != nil && ingredient?.deleted_at == nil
        let itemDrift = drift[ingredientId]
        guard ingredientLive, let itemDrift else {
            return (false, nil, nil, 0)
        }
        let qty = try Rational.parseDec(qtyBaseUnits)
        let price = try Rational.parseDec(itemDrift.latestPrice)
        let cost = Kernel.roundHalfAway(qty.mul(price), places: 2)
        let cents = try Kernel.centsFromString(cost)
        return (true, itemDrift.latestPrice, cost, cents)
    }

    /// The `fcPct`/`status`/`suggestedPrice` triple -- shared by
    /// `costRecipes` and `previewPlate`, both of which call this only once
    /// they've already established `complete` and parsed `menuCents`/
    /// `targetBp` (each in its own shape: unconditionally for a stored
    /// recipe's always-present menu price, conditionally in `previewPlate`
    /// when both draft pricing inputs are supplied). Taking already-parsed
    /// `Int`s here, rather than raw `String?`s, keeps that parsing
    /// asymmetry at each call site while sharing the arithmetic itself.
    private static func priceFields(
        plateCents: Int, menuCents: Int, targetBp: Int
    ) throws -> (fcPct: String, status: String, suggestedPrice: String) {
        let (fc, status) = try Kernel.fcStatus(
            plateCents: plateCents, menuCents: menuCents, targetBp: targetBp)
        let suggestedCents = try Kernel.suggestedPriceCents(
            plateCents: plateCents, targetBp: targetBp)
        return (fc, status, Kernel.moneyFromCents(suggestedCents))
    }

    /// Exact mirror of api/services/costing.py's `cost_recipes`.
    /// Completeness contract (spec §10.1): an item is resolvable only when
    /// its ingredient is present in `ingredients` AND live (`deleted_at ==
    /// nil`) AND `drift` has an entry for it; any unresolvable item nulls
    /// the WHOLE recipe's `fc_pct`/`status`/`suggested_price` (never
    /// reprice a partial). Each item's cost is rounded to 2dp
    /// half-away-from-zero FIRST, then summed as integer cents -- summing
    /// the unrounded products first can disagree with the server by a
    /// cent (proven by `CostingTests`).
    public static func costRecipes(
        recipes: [LocalRecipe], items: [LocalRecipeItem],
        ingredients: [LocalIngredient], drift: [String: DriftResult]
    ) throws -> [CostedRecipe] {
        var ingredientsById: [String: LocalIngredient] = [:]
        for ingredient in ingredients { ingredientsById[ingredient.id] = ingredient }

        var itemsByRecipe: [String: [LocalRecipeItem]] = [:]
        for item in items { itemsByRecipe[item.recipe_id, default: []].append(item) }

        var out: [CostedRecipe] = []
        for recipe in recipes {
            var plateCents = 0
            var complete = true
            var costedItems: [CostedItem] = []

            for item in itemsByRecipe[recipe.id] ?? [] {
                let ingredient = ingredientsById[item.ingredient_id]
                let line = try costLine(
                    ingredientId: item.ingredient_id, qtyBaseUnits: item.qty_base_units,
                    ingredient: ingredient, drift: drift)

                if line.resolvable {
                    plateCents += line.cents
                } else {
                    complete = false
                }

                costedItems.append(CostedItem(
                    id: item.id, ingredientId: item.ingredient_id,
                    name: ingredient?.name, baseUnit: ingredient?.base_unit,
                    qtyBaseUnits: item.qty_base_units, unitPrice: line.unitPrice,
                    cost: line.cost, isResolvable: line.resolvable))
            }

            // (ingredient name, item id) ASC, nil names LAST -- Postgres'
            // "ORDER BY i.name, ri.id" with NULLS LAST default for ASC.
            costedItems.sort { a, b in
                switch (a.name, b.name) {
                case (nil, nil): return a.id < b.id
                case (nil, _): return false
                case (_, nil): return true
                case let (an?, bn?):
                    return an != bn ? an < bn : a.id < b.id
                }
            }

            let plateCost = Kernel.moneyFromCents(plateCents)
            let menuCents = try Kernel.centsFromString(recipe.menu_price)
            let targetBp = try Kernel.bpFromString(recipe.target_fc_pct)

            var fcPct: String?
            var status: String?
            var suggestedPrice: String?
            if complete {
                let priced = try priceFields(
                    plateCents: plateCents, menuCents: menuCents, targetBp: targetBp)
                fcPct = priced.fcPct
                status = priced.status
                suggestedPrice = priced.suggestedPrice
            }

            out.append(CostedRecipe(
                recipeId: recipe.id, name: recipe.name, menuPrice: recipe.menu_price,
                targetFcPct: recipe.target_fc_pct, plateCost: plateCost,
                fcPct: fcPct, status: status, suggestedPrice: suggestedPrice,
                complete: complete, items: costedItems))
        }

        // (name, id) ASC -- "ORDER BY name, id".
        out.sort { a, b in a.name != b.name ? a.name < b.name : a.recipeId < b.recipeId }
        return out
    }
}

extension Costing {

    /// The draft-time twin of `costRecipes`, for lines that aren't rows
    /// yet -- same completeness contract (spec §10.1), same rounding
    /// order (each line rounded to 2dp half-away-from-zero, THEN summed
    /// as integer cents), sharing `costLine` so both stay identical.
    public struct PreviewResult: Equatable, Sendable {
        public let plateCost: String
        public let complete: Bool
        public let fcPct: String?
        public let status: String?
        public let suggestedPrice: String?

        public init(
            plateCost: String, complete: Bool, fcPct: String?, status: String?,
            suggestedPrice: String?
        ) {
            self.plateCost = plateCost
            self.complete = complete
            self.fcPct = fcPct
            self.status = status
            self.suggestedPrice = suggestedPrice
        }
    }

    /// Costs a set of not-yet-saved lines exactly as `costRecipes` costs
    /// stored rows: `complete` requires every line resolvable AND `lines`
    /// non-empty; an unresolvable line contributes nothing to `plateCost`.
    /// `fcPct`/`status`/`suggestedPrice` are computed only when `complete`
    /// AND both `menuPrice`/`targetFcPct` are supplied -- never reprice a
    /// partial, and never reprice without pricing inputs.
    public static func previewPlate(
        lines: [(ingredientId: String, qty: String)], menuPrice: String?, targetFcPct: String?,
        ingredients: [LocalIngredient], drift: [String: DriftResult]
    ) throws -> PreviewResult {
        var ingredientsById: [String: LocalIngredient] = [:]
        for ingredient in ingredients { ingredientsById[ingredient.id] = ingredient }

        var plateCents = 0
        var complete = !lines.isEmpty
        for line in lines {
            let ingredient = ingredientsById[line.ingredientId]
            let costed = try costLine(
                ingredientId: line.ingredientId, qtyBaseUnits: line.qty,
                ingredient: ingredient, drift: drift)

            if costed.resolvable {
                plateCents += costed.cents
            } else {
                complete = false
            }
        }

        let plateCost = Kernel.moneyFromCents(plateCents)

        var fcPct: String?
        var status: String?
        var suggestedPrice: String?
        if complete, let menuPrice, let targetFcPct {
            let menuCents = try Kernel.centsFromString(menuPrice)
            let targetBp = try Kernel.bpFromString(targetFcPct)
            let priced = try priceFields(
                plateCents: plateCents, menuCents: menuCents, targetBp: targetBp)
            fcPct = priced.fcPct
            status = priced.status
            suggestedPrice = priced.suggestedPrice
        }

        return PreviewResult(
            plateCost: plateCost, complete: complete, fcPct: fcPct, status: status,
            suggestedPrice: suggestedPrice)
    }
}
