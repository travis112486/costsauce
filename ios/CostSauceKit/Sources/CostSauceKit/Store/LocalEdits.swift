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
}
