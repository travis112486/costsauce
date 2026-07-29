// The CostSauce local store — GRDB records.
//
// Columns mirror the server's sync pull payload keys EXACTLY
// (api/services/sync.py:154-195, the `_PULL` jsonb_build_object key
// lists). Every value that crosses the wire is stored verbatim as TEXT;
// `server_seq` is the sole INTEGER. Money/decimal strings (qty, prices,
// percentages) are never parsed here — the kernel (Task 6) is the only
// place that turns them into numbers. Timestamps ARE canonicalized, but
// only once, at `LocalStore.applyPullPage` time (see LocalStore.swift) —
// these record types themselves are dumb value holders.
//
// Records conform to GRDB's Codable-record idioms: `Encodable`/`Decodable`
// derive `encode(to:)`/`init(from:)` from the stored properties, which
// GRDB's `EncodableRecord`/`FetchableRecord` default implementations reuse
// to move values in and out of SQLite rows. Property names are snake_case
// and equal to their column names one-for-one, so no CodingKeys remapping
// is needed anywhere in this file.

import Foundation
import GRDB

// MARK: - ingredients

public struct LocalIngredient: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "ingredients"

    public var id: String
    public var location_id: String
    public var name: String
    public var base_unit: String
    public var vendor: String?
    public var category: String?
    public var source: String?
    public var client_mutated_at: String
    public var server_seq: Int64
    public var updated_at: String
    public var deleted_at: String?
    public var created_at: String

    public init(
        id: String, location_id: String, name: String, base_unit: String,
        vendor: String?, category: String?, source: String?,
        client_mutated_at: String, server_seq: Int64, updated_at: String,
        deleted_at: String?, created_at: String
    ) {
        self.id = id
        self.location_id = location_id
        self.name = name
        self.base_unit = base_unit
        self.vendor = vendor
        self.category = category
        self.source = source
        self.client_mutated_at = client_mutated_at
        self.server_seq = server_seq
        self.updated_at = updated_at
        self.deleted_at = deleted_at
        self.created_at = created_at
    }
}

// MARK: - recipes

public struct LocalRecipe: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "recipes"

    public var id: String
    public var location_id: String
    public var name: String
    public var menu_price: String
    public var target_fc_pct: String
    public var client_mutated_at: String
    public var server_seq: Int64
    public var updated_at: String
    public var deleted_at: String?
    public var created_at: String

    public init(
        id: String, location_id: String, name: String, menu_price: String,
        target_fc_pct: String, client_mutated_at: String, server_seq: Int64,
        updated_at: String, deleted_at: String?, created_at: String
    ) {
        self.id = id
        self.location_id = location_id
        self.name = name
        self.menu_price = menu_price
        self.target_fc_pct = target_fc_pct
        self.client_mutated_at = client_mutated_at
        self.server_seq = server_seq
        self.updated_at = updated_at
        self.deleted_at = deleted_at
        self.created_at = created_at
    }
}

// MARK: - recipe_items

public struct LocalRecipeItem: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "recipe_items"

    public var id: String
    public var location_id: String
    public var recipe_id: String
    public var ingredient_id: String
    public var qty_base_units: String
    public var client_mutated_at: String
    public var server_seq: Int64
    public var updated_at: String
    public var deleted_at: String?
    public var created_at: String

    public init(
        id: String, location_id: String, recipe_id: String, ingredient_id: String,
        qty_base_units: String, client_mutated_at: String, server_seq: Int64,
        updated_at: String, deleted_at: String?, created_at: String
    ) {
        self.id = id
        self.location_id = location_id
        self.recipe_id = recipe_id
        self.ingredient_id = ingredient_id
        self.qty_base_units = qty_base_units
        self.client_mutated_at = client_mutated_at
        self.server_seq = server_seq
        self.updated_at = updated_at
        self.deleted_at = deleted_at
        self.created_at = created_at
    }
}

// MARK: - purchases

public struct LocalPurchase: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "purchases"

    public var id: String
    public var location_id: String
    public var ingredient_id: String
    public var purchased_on: String
    public var recorded_at: String
    public var qty: String
    public var unit: String
    public var qty_in_case: String?
    public var qty_base_units: String
    public var total_price: String
    /// Server-generated (`round(total_price / qty_base_units, 6)`, a DB
    /// generated column) — nil until the first pull echoes the row back.
    /// Local costing never reads this: Task 6 computes
    /// `Kernel.unitPrice(total_price, qty_base_units)` so an unsynced
    /// purchase prices identically to a synced one.
    public var unit_price: String?
    public var source: String?
    public var client_mutated_at: String
    public var server_seq: Int64
    public var updated_at: String
    public var deleted_at: String?
    public var created_at: String

    public init(
        id: String, location_id: String, ingredient_id: String, purchased_on: String,
        recorded_at: String, qty: String, unit: String, qty_in_case: String?,
        qty_base_units: String, total_price: String, unit_price: String?, source: String?,
        client_mutated_at: String, server_seq: Int64, updated_at: String,
        deleted_at: String?, created_at: String
    ) {
        self.id = id
        self.location_id = location_id
        self.ingredient_id = ingredient_id
        self.purchased_on = purchased_on
        self.recorded_at = recorded_at
        self.qty = qty
        self.unit = unit
        self.qty_in_case = qty_in_case
        self.qty_base_units = qty_base_units
        self.total_price = total_price
        self.unit_price = unit_price
        self.source = source
        self.client_mutated_at = client_mutated_at
        self.server_seq = server_seq
        self.updated_at = updated_at
        self.deleted_at = deleted_at
        self.created_at = created_at
    }
}

// MARK: - pending_ops

public enum OpKind: String, Codable, DatabaseValueConvertible, Equatable, Sendable {
    case insert, update
}

public enum OpState: String, Codable, DatabaseValueConvertible, Equatable, Sendable {
    case queued
    case needsAttention = "needs_attention"
}

/// A queued (not-yet-pushed) local mutation. `fields` holds the same
/// shape the server's `SyncOpIn.fields` accepts: a flat string-keyed map
/// of column → new value, `nil` meaning an explicit SQL NULL (e.g. a
/// tombstone's non-`deleted_at` columns are simply absent, not nil).
/// GRDB persists `fields` as JSON TEXT automatically (it isn't itself
/// `DatabaseValueConvertible`, so the default Codable-record encoder
/// falls back to JSON — see `EncodableRecord+Encodable.swift`), and
/// `exportPendingOps` reuses the same `Codable` conformance to produce
/// the §13 export JSON directly from `JSONEncoder`.
public struct PendingOp: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "pending_ops"

    public var op_id: String
    public var table: String
    public var row_id: String
    public var location_id: String
    public var client_mutated_at: String
    public var kind: OpKind
    public var fields: [String: String?]
    public var state: OpState
    public var reason: String?
    public var created_at: String

    public init(
        op_id: String, table: String, row_id: String, location_id: String,
        client_mutated_at: String, kind: OpKind, fields: [String: String?],
        state: OpState, reason: String?, created_at: String
    ) {
        self.op_id = op_id
        self.table = table
        self.row_id = row_id
        self.location_id = location_id
        self.client_mutated_at = client_mutated_at
        self.kind = kind
        self.fields = fields
        self.state = state
        self.reason = reason
        self.created_at = created_at
    }
}

// MARK: - meta

/// Single-row identity + cursor record, always stored at `rowid` 1.
/// Not a GRDB record itself (no natural `id` column to key on) —
/// `LocalStore` reads/writes it with plain SQL against a fixed rowid.
public struct Meta: Equatable, Sendable {
    public var user_id: String
    public var org_id: String
    public var location_id: String
    public var cursor: Int64

    public init(user_id: String, org_id: String, location_id: String, cursor: Int64) {
        self.user_id = user_id
        self.org_id = org_id
        self.location_id = location_id
        self.cursor = cursor
    }
}

// MARK: - pull wire format

/// One row of a sync pull page, table name + its raw wire-format fields
/// (string keys copied verbatim from the server's `_PULL` jsonb key
/// lists). `LocalStore.applyPullPage` is the only place these get turned
/// into typed `Local*` records.
public struct PullChange: Sendable {
    public let table: String
    public let row: [String: SyncValue]

    public init(table: String, row: [String: SyncValue]) {
        self.table = table
        self.row = row
    }
}

/// A single pull-payload field value. `server_seq` is the only integer
/// field across all four `_PULL` tables; everything else is a string or
/// SQL NULL.
public enum SyncValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case null
}

public struct StoreError: Error, Equatable, Sendable {
    public let kind: Kind

    public enum Kind: Equatable, Sendable {
        case identityMismatch
        case unknownTable(String)
    }

    public init(kind: Kind) {
        self.kind = kind
    }
}

// MARK: - wire-row parsing helpers

/// Thrown when a `PullChange.row` is missing a key its table's known
/// field list requires, or has the wrong `SyncValue` case for that key.
/// This is a defensive-only error: with fixtures/pull payloads built from
/// the `_PULL` field lists this never fires. It's deliberately NOT part
/// of `StoreError` — that type is the frozen, caller-facing contract;
/// this is an internal invariant check.
struct MalformedPullRow: Error {
    let table: String
    let key: String
}

extension PullChange {
    func requireString(_ key: String) throws -> String {
        guard case .string(let s)? = row[key] else {
            throw MalformedPullRow(table: table, key: key)
        }
        return s
    }

    func optionalString(_ key: String) throws -> String? {
        switch row[key] {
        case .string(let s): return s
        case .null, .none: return nil
        case .int: throw MalformedPullRow(table: table, key: key)
        }
    }

    func requireInt64(_ key: String) throws -> Int64 {
        guard case .int(let i)? = row[key] else {
            throw MalformedPullRow(table: table, key: key)
        }
        return i
    }
}

// MARK: - Local* <- PullChange, with timestamp canonicalization

extension LocalIngredient {
    /// Builds a full-row-replace record from a pull change. Only
    /// `client_mutated_at`/`updated_at`/`deleted_at`/`created_at` are
    /// canonicalized (via `Kernel.canonicalize`); every other value is
    /// stored exactly as it arrived on the wire.
    static func fromPull(_ change: PullChange) throws -> LocalIngredient {
        LocalIngredient(
            id: try change.requireString("id"),
            location_id: try change.requireString("location_id"),
            name: try change.requireString("name"),
            base_unit: try change.requireString("base_unit"),
            vendor: try change.optionalString("vendor"),
            category: try change.optionalString("category"),
            source: try change.optionalString("source"),
            client_mutated_at: try Kernel.canonicalize(change.requireString("client_mutated_at")),
            server_seq: try change.requireInt64("server_seq"),
            updated_at: try Kernel.canonicalize(change.requireString("updated_at")),
            deleted_at: try change.optionalString("deleted_at").map { try Kernel.canonicalize($0) },
            created_at: try Kernel.canonicalize(change.requireString("created_at"))
        )
    }
}

extension LocalRecipe {
    static func fromPull(_ change: PullChange) throws -> LocalRecipe {
        LocalRecipe(
            id: try change.requireString("id"),
            location_id: try change.requireString("location_id"),
            name: try change.requireString("name"),
            menu_price: try change.requireString("menu_price"),
            target_fc_pct: try change.requireString("target_fc_pct"),
            client_mutated_at: try Kernel.canonicalize(change.requireString("client_mutated_at")),
            server_seq: try change.requireInt64("server_seq"),
            updated_at: try Kernel.canonicalize(change.requireString("updated_at")),
            deleted_at: try change.optionalString("deleted_at").map { try Kernel.canonicalize($0) },
            created_at: try Kernel.canonicalize(change.requireString("created_at"))
        )
    }
}

extension LocalRecipeItem {
    static func fromPull(_ change: PullChange) throws -> LocalRecipeItem {
        LocalRecipeItem(
            id: try change.requireString("id"),
            location_id: try change.requireString("location_id"),
            recipe_id: try change.requireString("recipe_id"),
            ingredient_id: try change.requireString("ingredient_id"),
            qty_base_units: try change.requireString("qty_base_units"),
            client_mutated_at: try Kernel.canonicalize(change.requireString("client_mutated_at")),
            server_seq: try change.requireInt64("server_seq"),
            updated_at: try Kernel.canonicalize(change.requireString("updated_at")),
            deleted_at: try change.optionalString("deleted_at").map { try Kernel.canonicalize($0) },
            created_at: try Kernel.canonicalize(change.requireString("created_at"))
        )
    }
}

extension LocalPurchase {
    /// `purchased_on` is a plain civil date (not a timestamp) and is
    /// never canonicalized; `recorded_at` IS a timestamp and is.
    static func fromPull(_ change: PullChange) throws -> LocalPurchase {
        LocalPurchase(
            id: try change.requireString("id"),
            location_id: try change.requireString("location_id"),
            ingredient_id: try change.requireString("ingredient_id"),
            purchased_on: try change.requireString("purchased_on"),
            recorded_at: try Kernel.canonicalize(change.requireString("recorded_at")),
            qty: try change.requireString("qty"),
            unit: try change.requireString("unit"),
            qty_in_case: try change.optionalString("qty_in_case"),
            qty_base_units: try change.requireString("qty_base_units"),
            total_price: try change.requireString("total_price"),
            unit_price: try change.optionalString("unit_price"),
            source: try change.optionalString("source"),
            client_mutated_at: try Kernel.canonicalize(change.requireString("client_mutated_at")),
            server_seq: try change.requireInt64("server_seq"),
            updated_at: try Kernel.canonicalize(change.requireString("updated_at")),
            deleted_at: try change.optionalString("deleted_at").map { try Kernel.canonicalize($0) },
            created_at: try Kernel.canonicalize(change.requireString("created_at"))
        )
    }
}
