// The CostSauce local store — user-initiated edits.
//
// Every mutating function here mints a fresh UUIDv7 `op_id` (and, for an
// insert, a fresh UUIDv7 row `id` too), stamps `client_mutated_at`/
// `recorded_at` via `Kernel.canonicalTimestamp(now)`, and enqueues exactly
// one `PendingOp` via `LocalStore.enqueue` -- which both records the
// outbox entry AND makes the edit visible to local reads immediately (see
// `LocalStore.enqueue`'s doc comment for how insert-kind ops get a fresh
// local row before it's ever pushed).
//
// `PendingOp.fields` mirrors the server's per-table allowlists exactly
// (api/services/sync.py:25-38's `INSERT_FIELDS`/`UPDATE_FIELDS`) -- every
// key here is a subset of the matching allowlist, and `nil`-valued
// optional fields are simply OMITTED from the dict (never sent as an
// explicit `null`), except a tombstone op, which sends `deleted_at`.

import Foundation

public struct LocalEdits {
    private let store: LocalStore
    private let locationId: String

    public init(store: LocalStore, locationId: String) {
        self.store = store
        self.locationId = locationId
    }

    public enum EditError: Error, Equatable {
        case duplicate(existingId: String, name: String)
        case inUse(count: Int)
        case lastLine
    }

    /// Mirrors `POST /locations/{id}/ingredients` (api/routes/ingredients.py:69-97).
    /// `INSERT_FIELDS.ingredients` is `{name, base_unit, vendor, category, source,
    /// deleted_at}`; this sends `name` (trimmed) and `base_unit` always, `vendor`/
    /// `category` only when non-nil -- `source` and `deleted_at` are never sent by
    /// a device-initiated create.
    public func createIngredient(
        name: String, baseUnit: String, vendor: String?, category: String?,
        now: Date = Date()
    ) throws -> String {
        let normalized = Kernel.normalizeName(name)
        guard !normalized.isEmpty else {
            throw KernelError("name normalizes to nothing")
        }
        // (created_at, id) order -- the server's own `_candidates` order
        // (api/routes/ingredients.py:19-27) -- first exact normalized match wins.
        let candidates = try store.liveIngredientsByCreation()
        if let existing = candidates.first(where: { Kernel.normalizeName($0.name) == normalized }) {
            throw EditError.duplicate(existingId: existing.id, name: existing.name)
        }

        let rowId = UUIDv7.generate(now: now)
        let opId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)

        var fields: [String: String?] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "base_unit": baseUnit,
        ]
        if let vendor { fields["vendor"] = vendor }
        if let category { fields["category"] = category }

        try store.enqueue(PendingOp(
            op_id: opId, table: "ingredients", row_id: rowId, location_id: locationId,
            client_mutated_at: mutatedAt, kind: .insert, fields: fields,
            state: .queued, reason: nil, created_at: mutatedAt))
        return rowId
    }

    /// Mirrors `POST /locations/{id}/purchases`. `INSERT_FIELDS.purchases` is
    /// `{ingredient_id, purchased_on, recorded_at, qty, unit, qty_in_case,
    /// qty_base_units, total_price, source, deleted_at}`; this sends every key
    /// except `qty_in_case` (only when `unit == "case"`), `source`, and
    /// `deleted_at`. `qty_base_units` is computed by `Kernel.normalizePurchase`
    /// against the PARENT ingredient's `base_unit` -- the warning-(c) math --
    /// which also validates `qty`/`total_price`/`unit`/`qty_in_case` and throws
    /// `KernelError` on anything invalid, same as the server's own kernel call.
    public func createPurchase(
        ingredientId: String, purchasedOn: String, qty: String, unit: String,
        qtyInCase: String?, totalPrice: String, now: Date = Date()
    ) throws -> String {
        guard let ingredient = try store.ingredient(id: ingredientId) else {
            throw KernelError("ingredient not found")
        }
        let qtyBaseUnits = try Kernel.normalizePurchase(
            baseUnit: ingredient.base_unit, qty: qty, unit: unit,
            totalPrice: totalPrice, qtyInCase: qtyInCase)
        let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let rowId = UUIDv7.generate(now: now)
        let opId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)

        var fields: [String: String?] = [
            "ingredient_id": ingredientId,
            "purchased_on": purchasedOn,
            "recorded_at": mutatedAt,
            "qty": qty,
            "unit": normalizedUnit,
            "qty_base_units": qtyBaseUnits,
            "total_price": totalPrice,
        ]
        if normalizedUnit == "case" {
            fields["qty_in_case"] = qtyInCase
        }

        try store.enqueue(PendingOp(
            op_id: opId, table: "purchases", row_id: rowId, location_id: locationId,
            client_mutated_at: mutatedAt, kind: .insert, fields: fields,
            state: .queued, reason: nil, created_at: mutatedAt))
        return rowId
    }

    /// The kernel's accepted unit vocabulary for a purchase's `unit` field,
    /// scoped to the given ingredient's `base_unit` -- backs
    /// `PurchaseEntryView`'s unit `Picker`. An each-tracked ingredient only
    /// ever accepts "each" or "case" (`Kernel.normalizePurchase` throws
    /// "tracked 'each' -- use unit 'each' or 'case'" on anything else); a
    /// weight-tracked ingredient (lb/oz/kg/g) accepts any of the four
    /// weight units plus "case" regardless of which one it's tracked in --
    /// `Kernel.normalizePurchase`'s `weightToLb` table converts across
    /// them, e.g. buying oz against an lb-tracked ingredient.
    public func unitChoices(baseUnit: String) -> [String] {
        baseUnit == "each" ? ["each", "case"] : ["lb", "oz", "kg", "g", "case"]
    }

    /// A plain tombstone update -- fields are exactly `{deleted_at}`, a subset
    /// of `UPDATE_FIELDS.purchases`.
    public func tombstonePurchase(id: String, now: Date = Date()) throws {
        let opId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)
        try store.enqueue(PendingOp(
            op_id: opId, table: "purchases", row_id: id, location_id: locationId,
            client_mutated_at: mutatedAt, kind: .update,
            fields: ["deleted_at": mutatedAt],
            state: .queued, reason: nil, created_at: mutatedAt))
    }

    /// The local in-use guard runs FIRST, before any op is queued -- it mirrors
    /// both the route's 409 (api/routes/ingredients.py:104-129) AND the sync-path
    /// guard (api/services/sync.py:132-145), so a tombstone-ingredient op can
    /// never leave here only to bounce back from the server as `needs_attention`
    /// for a condition this device could already see locally.
    public func tombstoneIngredient(id: String, now: Date = Date()) throws {
        let inUseCount = try store.liveRecipeItemCount(ingredientId: id)
        guard inUseCount == 0 else {
            throw EditError.inUse(count: inUseCount)
        }
        let opId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)
        try store.enqueue(PendingOp(
            op_id: opId, table: "ingredients", row_id: id, location_id: locationId,
            client_mutated_at: mutatedAt, kind: .update,
            fields: ["deleted_at": mutatedAt],
            state: .queued, reason: nil, created_at: mutatedAt))
    }

    /// Mirrors `PATCH /recipes/{id}`. `UPDATE_FIELDS.recipes` is `{name,
    /// menu_price, target_fc_pct, deleted_at}`; each parameter `nil` means
    /// "unchanged" -- simply omitted from `fields`, never sent as an explicit
    /// null (these three columns are never nullable). If every parameter is
    /// `nil` (or every non-nil value is already what the row holds -- this
    /// method doesn't diff against the current row, only against "was a
    /// value supplied at all"), `fields` stays empty and nothing is
    /// enqueued: a no-change Save must not mint an op. `menu_price`/
    /// `target_fc_pct` must parse as a positive `Rational` (schema CHECKs:
    /// `numeric(10,2) > 0`, `numeric(5,2) > 0`).
    public func updateRecipeFields(
        id: String, name: String?, menuPrice: String?, targetFcPct: String?, now: Date = Date()
    ) throws {
        var fields: [String: String?] = [:]
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw KernelError("name must not be empty")
            }
            fields["name"] = trimmed
        }
        if let menuPrice {
            guard try Rational.parseDec(menuPrice).isPositive else {
                throw KernelError("menu_price must be greater than zero")
            }
            fields["menu_price"] = menuPrice
        }
        if let targetFcPct {
            guard try Rational.parseDec(targetFcPct).isPositive else {
                throw KernelError("target_fc_pct must be greater than zero")
            }
            fields["target_fc_pct"] = targetFcPct
        }
        guard !fields.isEmpty else { return }

        let opId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)
        try store.enqueue(PendingOp(
            op_id: opId, table: "recipes", row_id: id, location_id: locationId,
            client_mutated_at: mutatedAt, kind: .update, fields: fields,
            state: .queued, reason: nil, created_at: mutatedAt))
    }

    /// Mirrors `POST /recipes/{id}/items`. `INSERT_FIELDS.recipe_items` is
    /// `{recipe_id, ingredient_id, qty_base_units, deleted_at}`; this sends
    /// the first three always. Guards run in this order: the recipe must be
    /// live, the ingredient must be live, `qty` must parse positive, and no
    /// live line on the recipe may already hold this ingredient --
    /// pre-empting the server's `recipe_items_live_uq` constraint with the
    /// same `EditError.duplicate` shape `createIngredient` uses.
    public func addRecipeLine(
        recipeId: String, ingredientId: String, qty: String, now: Date = Date()
    ) throws -> String {
        guard let recipe = try store.recipe(id: recipeId), recipe.deleted_at == nil else {
            throw KernelError("recipe is not live")
        }
        guard let ingredient = try store.ingredient(id: ingredientId), ingredient.deleted_at == nil else {
            throw KernelError("ingredient is not live")
        }
        guard try Rational.parseDec(qty).isPositive else {
            throw KernelError("quantity must be greater than zero")
        }
        let liveLines = try store.liveRecipeItems(recipeId: recipeId)
        if let existing = liveLines.first(where: { $0.ingredient_id == ingredientId }) {
            throw EditError.duplicate(existingId: existing.id, name: ingredient.name)
        }

        let rowId = UUIDv7.generate(now: now)
        let opId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)
        let fields: [String: String?] = [
            "recipe_id": recipeId,
            "ingredient_id": ingredientId,
            "qty_base_units": qty,
        ]

        try store.enqueue(PendingOp(
            op_id: opId, table: "recipe_items", row_id: rowId, location_id: locationId,
            client_mutated_at: mutatedAt, kind: .insert, fields: fields,
            state: .queued, reason: nil, created_at: mutatedAt))
        return rowId
    }

    /// Mirrors `PATCH /recipe_items/{id}`. `fields` is `{qty_base_units}`
    /// ONLY -- `recipe_id`/`ingredient_id` are immutable over sync
    /// (`UPDATE_FIELDS.recipe_items` omits them entirely; repointing a line
    /// to a different ingredient is a tombstone + a fresh `addRecipeLine`,
    /// never an update).
    public func updateRecipeLineQty(itemId: String, qty: String, now: Date = Date()) throws {
        guard try store.liveRecipeItems().contains(where: { $0.id == itemId }) else {
            throw KernelError("recipe line is not live")
        }
        guard try Rational.parseDec(qty).isPositive else {
            throw KernelError("quantity must be greater than zero")
        }

        let opId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)
        try store.enqueue(PendingOp(
            op_id: opId, table: "recipe_items", row_id: itemId, location_id: locationId,
            client_mutated_at: mutatedAt, kind: .update,
            fields: ["qty_base_units": qty],
            state: .queued, reason: nil, created_at: mutatedAt))
    }

    /// A plain tombstone update -- fields are exactly `{deleted_at}`, a subset
    /// of `UPDATE_FIELDS.recipe_items`. The local guard runs BEFORE any op is
    /// queued, same shape as `tombstoneIngredient`'s in-use guard: a recipe's
    /// last live line may never be tombstoned, because a lineless recipe
    /// costs out at zero and reports a healthy FC% -- worse than an error
    /// (spec §9).
    public func tombstoneRecipeLine(itemId: String, now: Date = Date()) throws {
        guard let item = try store.liveRecipeItems().first(where: { $0.id == itemId }) else {
            throw KernelError("recipe line is not live")
        }
        let siblingLines = try store.liveRecipeItems(recipeId: item.recipe_id)
        guard siblingLines.count > 1 else {
            throw EditError.lastLine
        }

        let opId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)
        try store.enqueue(PendingOp(
            op_id: opId, table: "recipe_items", row_id: itemId, location_id: locationId,
            client_mutated_at: mutatedAt, kind: .update,
            fields: ["deleted_at": mutatedAt],
            state: .queued, reason: nil, created_at: mutatedAt))
    }

    /// Deletes a recipe by tombstoning it AND every one of its live lines,
    /// one `deleted_at` update op per row, all sharing a single timestamp
    /// and enqueued in ONE transaction (`LocalStore.enqueueBatch`). This is
    /// warning (b) of api/routes/sync.py:15-22: unlike `DELETE
    /// /locations/{id}/recipes/{id}`, a recipe tombstone op does NOT
    /// cascade to its lines server-side -- skipping the fan-out strands
    /// live lines against a dead recipe, which `cost_recipes` surfaces as a
    /// loud data-integrity complaint. Deliberately bypasses
    /// `tombstoneRecipeLine`'s `EditError.lastLine` guard by enqueuing the
    /// line tombstones directly: deleting the recipe is exactly the
    /// sanctioned way to remove its final line.
    public func tombstoneRecipe(id: String, now: Date = Date()) throws {
        guard let recipe = try store.recipe(id: id), recipe.deleted_at == nil else {
            throw KernelError("recipe is not live")
        }
        let liveLines = try store.liveRecipeItems(recipeId: id)
        let mutatedAt = Kernel.canonicalTimestamp(now)

        var ops: [PendingOp] = liveLines.map { line in
            PendingOp(
                op_id: UUIDv7.generate(now: now), table: "recipe_items", row_id: line.id,
                location_id: locationId, client_mutated_at: mutatedAt, kind: .update,
                fields: ["deleted_at": mutatedAt],
                state: .queued, reason: nil, created_at: mutatedAt)
        }
        ops.append(PendingOp(
            op_id: UUIDv7.generate(now: now), table: "recipes", row_id: id,
            location_id: locationId, client_mutated_at: mutatedAt, kind: .update,
            fields: ["deleted_at": mutatedAt],
            state: .queued, reason: nil, created_at: mutatedAt))

        try store.enqueueBatch(ops)
    }

    /// Mirrors `POST /locations/{id}/recipes` followed by N `POST
    /// /recipes/{id}/items` calls, but as the offline create path for a
    /// `RecipeDraft` (Task 3) composed entirely in memory. Order: `validate()`
    /// first -- a non-empty result throws its FIRST error (the editor view
    /// pre-validates before ever calling this, so this is a backstop, not
    /// the UI path). Then every draft line's ingredient must still be live
    /// -- checked BEFORE any row or op is written, so a line naming a
    /// tombstoned ingredient leaves nothing behind (no partially-written
    /// recipe, no orphaned ops): same precede-the-write-with-a-read shape as
    /// `tombstoneRecipe`'s guards. Finally ONE `enqueueBatch` call -- ONE
    /// transaction, ONE timestamp -- mints the recipe id, enqueues its
    /// insert op (`fields` ⊆ `INSERT_FIELDS.recipes`), then one insert op per
    /// line (`fields` ⊆ `INSERT_FIELDS.recipe_items`). Safe in one push
    /// despite the FK: `TABLE_ORDER` applies all `recipes` ops before any
    /// `recipe_items` ops.
    public func saveNewRecipe(_ draft: RecipeDraft, now: Date = Date()) throws -> String {
        if let firstError = draft.validate().first {
            throw firstError
        }
        for line in draft.lines {
            guard let ingredient = try store.ingredient(id: line.ingredientId), ingredient.deleted_at == nil else {
                throw KernelError("ingredient is not live")
            }
        }

        let recipeId = UUIDv7.generate(now: now)
        let mutatedAt = Kernel.canonicalTimestamp(now)

        var ops: [PendingOp] = [
            PendingOp(
                op_id: UUIDv7.generate(now: now), table: "recipes", row_id: recipeId,
                location_id: locationId, client_mutated_at: mutatedAt, kind: .insert,
                fields: [
                    "name": draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "menu_price": draft.menuPrice,
                    "target_fc_pct": draft.targetFcPct,
                ],
                state: .queued, reason: nil, created_at: mutatedAt),
        ]
        for line in draft.lines {
            ops.append(PendingOp(
                op_id: UUIDv7.generate(now: now), table: "recipe_items",
                row_id: UUIDv7.generate(now: now), location_id: locationId,
                client_mutated_at: mutatedAt, kind: .insert,
                fields: [
                    "recipe_id": recipeId,
                    "ingredient_id": line.ingredientId,
                    "qty_base_units": line.qty,
                ],
                state: .queued, reason: nil, created_at: mutatedAt))
        }

        try store.enqueueBatch(ops)
        return recipeId
    }
}
