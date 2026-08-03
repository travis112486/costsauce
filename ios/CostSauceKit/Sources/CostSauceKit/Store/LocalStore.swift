// The CostSauce local store — GRDB-backed offline heart of the app.
//
// Wraps a `DatabaseQueue` running the "v1" schema (Schema.swift) over the
// record types in Records.swift. Two invariants worth restating here
// because they're easy to get wrong in later tasks:
//
// - `applyPullPage` is ONE transaction: upserts, pending-op rebase, and
//   the cursor write all succeed or all roll back together. An unknown
//   table throws mid-page and GRDB rolls the whole page back — cursor
//   AND every row touched so far in the page are left exactly as they
//   were (§5.5).
// - `enqueue` both records the outbox entry AND mutates the local row in
//   the same transaction, so a read immediately after `enqueue` always
//   sees the edit, synced or not.

import Foundation
import GRDB

public final class LocalStore: Sendable {
    private let dbQueue: DatabaseQueue

    private static let knownTables: Set<String> = [
        "ingredients", "recipes", "recipe_items", "purchases",
        "invoices", "invoice_pages",
    ]

    /// Opens (creating if needed) the SQLite file at `path`, runs the
    /// "v1" migrator, and marks the containing directory
    /// `NSFileProtectionComplete` (§13).
    public init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            try Self.protectDirectory(atPath: directory)
        }
        dbQueue = try DatabaseQueue(path: path)
        try Schema.migrator.migrate(dbQueue)
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Schema.migrator.migrate(dbQueue)
    }

    /// In-memory store for tests — same schema, no file protection to set.
    public static func inMemory() throws -> LocalStore {
        try LocalStore(dbQueue: DatabaseQueue())
    }

    /// `NSFileProtectionComplete` is an iOS Data Protection guarantee.
    /// On iOS, failure to set it is surfaced (`throws`) since it's a
    /// real security property the caller is relying on. On macOS (incl.
    /// this package's `swift test` host) APFS-on-Mac doesn't implement
    /// Data Protection at all, so `setAttributes` for `.protectionKey`
    /// routinely errors even though nothing is actually wrong — best
    /// effort only there, and failures are swallowed so store
    /// construction never fails because of a guarantee the platform
    /// can't provide.
    private static func protectDirectory(atPath path: String) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
        #else
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
        #endif
    }

    // MARK: - Identity

    public func meta() throws -> Meta? {
        try dbQueue.read { db in try Self.readMeta(db) }
    }

    /// Inserts meta with cursor 0. Re-binding the same (user, org) is a
    /// no-op (location_id is not part of the identity check). Binding a
    /// different user or org throws `StoreError(.identityMismatch)`
    /// rather than silently overwriting a still-live local dataset.
    public func bind(userId: String, orgId: String, locationId: String) throws {
        try dbQueue.write { db in
            if let existing = try Self.readMeta(db) {
                guard existing.user_id == userId, existing.org_id == orgId else {
                    throw StoreError(kind: .identityMismatch)
                }
                return
            }
            try db.execute(
                sql: "INSERT INTO meta (rowid, user_id, org_id, location_id, cursor) VALUES (1, ?, ?, ?, 0)",
                arguments: [userId, orgId, locationId])
        }
    }

    private static func readMeta(_ db: Database) throws -> Meta? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT user_id, org_id, location_id, cursor FROM meta WHERE rowid = 1")
        else {
            return nil
        }
        return Meta(
            user_id: row["user_id"], org_id: row["org_id"],
            location_id: row["location_id"], cursor: row["cursor"])
    }

    // MARK: - Pull apply

    /// One transaction: upsert every row (full-row replace, keyed by
    /// `id`), rebase still-queued pending ops onto the rows this page
    /// just touched, then advance the cursor. An unknown table throws
    /// and the whole page rolls back untouched.
    public func applyPullPage(_ changes: [PullChange], cursor: Int64) throws {
        try dbQueue.write { db in
            var upsertedRowIds: [String: Set<String>] = [:]
            for change in changes {
                try Self.upsert(change, in: db)
                let rowId = try change.requireString("id")
                upsertedRowIds[change.table, default: []].insert(rowId)
            }

            // (created_at, op_id) order -- same rule as `pendingOps(state:)` --
            // so that when two queued ops touch the same row, the later op's
            // fields win the replay and the row doesn't end up reverted to an
            // earlier edit's value.
            let queuedOps = try PendingOp.fetchAll(
                db, sql: "SELECT * FROM pending_ops WHERE state = ? ORDER BY created_at, op_id",
                arguments: [OpState.queued.rawValue])
            for op in queuedOps {
                guard upsertedRowIds[op.table]?.contains(op.row_id) == true else { continue }
                try Self.applyFields(op.fields, table: op.table, rowId: op.row_id, in: db)
            }

            try db.execute(sql: "UPDATE meta SET cursor = ? WHERE rowid = 1", arguments: [cursor])
        }
    }

    private static func upsert(_ change: PullChange, in db: Database) throws {
        switch change.table {
        case "ingredients":
            try LocalIngredient.fromPull(change).save(db)
        case "recipes":
            try LocalRecipe.fromPull(change).save(db)
        case "recipe_items":
            try LocalRecipeItem.fromPull(change).save(db)
        case "purchases":
            try LocalPurchase.fromPull(change).save(db)
        case "invoices":
            try LocalInvoice.fromPull(change).save(db)
        case "invoice_pages":
            try LocalInvoicePage.fromPull(change).save(db)
        default:
            throw StoreError(kind: .unknownTable(change.table))
        }
    }

    /// Sets exactly the columns named in `fields` on the row `rowId` of
    /// `table`. Used both by `enqueue` (apply-on-write) and by
    /// `applyPullPage`'s rebase (silent-LWW optimistic overlay: server
    /// truth from the pull, then our still-unpushed edits reapplied on
    /// top).
    private static func applyFields(
        _ fields: [String: String?], table: String, rowId: String, in db: Database
    ) throws {
        guard !fields.isEmpty else { return }
        let entries = Array(fields)
        let assignments = entries.map { "\($0.key) = ?" }.joined(separator: ", ")
        var arguments: [(any DatabaseValueConvertible)?] = entries.map { $0.value }
        arguments.append(rowId)
        try db.execute(
            sql: "UPDATE \"\(table)\" SET \(assignments) WHERE id = ?",
            arguments: StatementArguments(arguments))
    }

    // MARK: - Pending queue

    /// Inserts `op` AND applies its `fields` to the local row, in one
    /// transaction — a read immediately after always sees the edit.
    ///
    /// For an `.insert`-kind op (Task 6's `LocalEdits.createIngredient`/
    /// `createPurchase`, which mint a brand-new row id that has never been
    /// pulled), `applyFields`'s `UPDATE ... WHERE id = ?` would silently
    /// match zero rows -- there is nothing to update yet. `insertStub`
    /// creates a NOT-NULL-satisfying placeholder row first (empty strings /
    /// `op.client_mutated_at` for every column), which `applyFields` then
    /// overwrites with the op's real field values in the same transaction,
    /// so the new row is fully populated and immediately visible to local
    /// reads (costing, dashboard, duplicate-name checks) even before the
    /// op ever reaches the server. `.update`-kind ops are unaffected: their
    /// target row already exists (pulled, or a previously inserted row).
    public func enqueue(_ op: PendingOp) throws {
        try enqueueBatch([op])
    }

    /// `enqueue`'s per-op contract (insert the row, stub an `.insert`-kind
    /// target, apply `fields`), applied to every op in `ops` inside ONE
    /// transaction. `enqueue` itself is `enqueueBatch([op])` -- a caller
    /// that must mint several ops atomically (Task 2's `tombstoneRecipe`
    /// fan-out: a recipe's own tombstone plus one per live line) cannot
    /// just call `enqueue` in a loop, because each call would open its own
    /// transaction and a crash between calls could strand the fan-out
    /// half-applied. `dbQueue.write` is not reentrant, so this is the only
    /// way to batch more than one op atomically.
    public func enqueueBatch(_ ops: [PendingOp]) throws {
        try dbQueue.write { db in
            for op in ops {
                try op.insert(db)
                if op.kind == .insert {
                    try Self.insertStub(
                        table: op.table, rowId: op.row_id, locationId: op.location_id,
                        clientMutatedAt: op.client_mutated_at, in: db)
                }
                try Self.applyFields(op.fields, table: op.table, rowId: op.row_id, in: db)
            }
        }
    }

    /// See `enqueue`'s doc comment. `server_seq` 0 marks "never pulled" --
    /// local costing/dashboard math never reads `server_seq`, only the
    /// decimal-string columns, which `applyFields` sets correctly right
    /// after this runs.
    private static func insertStub(
        table: String, rowId: String, locationId: String, clientMutatedAt: String, in db: Database
    ) throws {
        switch table {
        case "ingredients":
            try LocalIngredient(
                id: rowId, location_id: locationId, name: "", base_unit: "",
                vendor: nil, category: nil, source: nil,
                client_mutated_at: clientMutatedAt, server_seq: 0,
                updated_at: clientMutatedAt, deleted_at: nil, created_at: clientMutatedAt
            ).insert(db)
        case "recipes":
            try LocalRecipe(
                id: rowId, location_id: locationId, name: "", menu_price: "0",
                target_fc_pct: "0", client_mutated_at: clientMutatedAt, server_seq: 0,
                updated_at: clientMutatedAt, deleted_at: nil, created_at: clientMutatedAt
            ).insert(db)
        case "recipe_items":
            try LocalRecipeItem(
                id: rowId, location_id: locationId, recipe_id: "", ingredient_id: "",
                qty_base_units: "0", client_mutated_at: clientMutatedAt, server_seq: 0,
                updated_at: clientMutatedAt, deleted_at: nil, created_at: clientMutatedAt
            ).insert(db)
        case "purchases":
            try LocalPurchase(
                id: rowId, location_id: locationId, ingredient_id: "", purchased_on: "",
                recorded_at: clientMutatedAt, qty: "0", unit: "", qty_in_case: nil,
                qty_base_units: "0", total_price: "0", unit_price: nil, source: nil,
                client_mutated_at: clientMutatedAt, server_seq: 0,
                updated_at: clientMutatedAt, deleted_at: nil, created_at: clientMutatedAt
            ).insert(db)
        case "invoices":
            try LocalInvoice(
                id: rowId, location_id: locationId, captured_at: clientMutatedAt,
                parse_status: "unparsed", client_mutated_at: clientMutatedAt, server_seq: 0,
                updated_at: clientMutatedAt, deleted_at: nil, created_at: clientMutatedAt
            ).insert(db)
        case "invoice_pages":
            try LocalInvoicePage(
                id: rowId, invoice_id: "", location_id: locationId, page_no: "0",
                storage_path: "", width: nil, height: nil, sha256: nil,
                client_mutated_at: clientMutatedAt, server_seq: 0,
                updated_at: clientMutatedAt, deleted_at: nil, created_at: clientMutatedAt
            ).insert(db)
        default:
            throw StoreError(kind: .unknownTable(table))
        }
    }

    /// `(created_at, op_id)` order; `nil` state returns every op.
    public func pendingOps(state: OpState?) throws -> [PendingOp] {
        try dbQueue.read { db in
            if let state {
                return try PendingOp.fetchAll(
                    db, sql: "SELECT * FROM pending_ops WHERE state = ? ORDER BY created_at, op_id",
                    arguments: [state.rawValue])
            }
            return try PendingOp.fetchAll(
                db, sql: "SELECT * FROM pending_ops ORDER BY created_at, op_id")
        }
    }

    public func deleteOp(opId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_ops WHERE op_id = ?", arguments: [opId])
        }
    }

    public func markNeedsAttention(opId: String, reason: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pending_ops SET state = ?, reason = ? WHERE op_id = ?",
                arguments: [OpState.needsAttention.rawValue, reason, opId])
        }
    }

    /// recipe_items upsert-arbitration case (api/services/sync.py:247-271):
    /// the server rejected our minted `mintedId` in favor of an existing
    /// canonical `(recipe_id, ingredient_id)` row. Drop the minted local
    /// row; the canonical row itself arrives via the trailing pull that
    /// follows a push, so nothing needs to be written here for it.
    public func adoptCanonicalRow(table: String, mintedId: String, canonicalId: String) throws {
        try dbQueue.write { db in
            guard Self.knownTables.contains(table) else {
                throw StoreError(kind: .unknownTable(table))
            }
            try db.execute(sql: "DELETE FROM \"\(table)\" WHERE id = ?", arguments: [mintedId])
        }
    }

    /// The §13 badge number: queued + needs_attention.
    public func pendingCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pending_ops WHERE state IN (?, ?)",
                arguments: [OpState.queued.rawValue, OpState.needsAttention.rawValue]) ?? 0
        }
    }

    // MARK: - Typed reads

    public func liveIngredients() throws -> [LocalIngredient] {
        try dbQueue.read { db in
            try LocalIngredient.fetchAll(
                db, sql: "SELECT * FROM ingredients WHERE deleted_at IS NULL ORDER BY name, id")
        }
    }

    /// Every ingredient, including tombstoned ones -- (name, id) order,
    /// same as `liveIngredients` but without the `deleted_at` filter.
    /// `Costing.costRecipes` (Task 6) needs this UNFILTERED set to give a
    /// recipe line whose ingredient was later tombstoned its real
    /// `name`/`base_unit` (LEFT-JOIN parity with api/services/costing.py:
    /// 56-62), which `liveIngredients` alone can never supply -- a
    /// tombstoned ingredient is invisible to it by construction.
    public func allIngredients() throws -> [LocalIngredient] {
        try dbQueue.read { db in
            try LocalIngredient.fetchAll(db, sql: "SELECT * FROM ingredients ORDER BY name, id")
        }
    }

    /// The `_candidates` order (api/routes/ingredients.py) — created_at, id.
    public func liveIngredientsByCreation() throws -> [LocalIngredient] {
        try dbQueue.read { db in
            try LocalIngredient.fetchAll(
                db, sql: "SELECT * FROM ingredients WHERE deleted_at IS NULL ORDER BY created_at, id")
        }
    }

    /// Unlike `liveIngredients`, this is NOT filtered by `deleted_at`:
    /// a tombstoned row must still be queryable by id.
    public func ingredient(id: String) throws -> LocalIngredient? {
        try dbQueue.read { db in
            try LocalIngredient.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = ?", arguments: [id])
        }
    }

    /// purchased_on DESC, recorded_at DESC, id DESC.
    public func livePurchases(ingredientId: String) throws -> [LocalPurchase] {
        try dbQueue.read { db in
            try LocalPurchase.fetchAll(
                db, sql: """
                    SELECT * FROM purchases WHERE ingredient_id = ? AND deleted_at IS NULL
                    ORDER BY purchased_on DESC, recorded_at DESC, id DESC
                    """,
                arguments: [ingredientId])
        }
    }

    public func allLivePurchases() throws -> [LocalPurchase] {
        try dbQueue.read { db in
            try LocalPurchase.fetchAll(
                db, sql: """
                    SELECT * FROM purchases WHERE deleted_at IS NULL
                    ORDER BY purchased_on DESC, recorded_at DESC, id DESC
                    """)
        }
    }

    public func liveRecipes() throws -> [LocalRecipe] {
        try dbQueue.read { db in
            try LocalRecipe.fetchAll(
                db, sql: "SELECT * FROM recipes WHERE deleted_at IS NULL ORDER BY name, id")
        }
    }

    /// Unlike `liveRecipes`, this is NOT filtered by `deleted_at`: a
    /// tombstoned row must still be queryable by id (mirrors `ingredient(id:)`).
    public func recipe(id: String) throws -> LocalRecipe? {
        try dbQueue.read { db in
            try LocalRecipe.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = ?", arguments: [id])
        }
    }

    public func liveRecipeItems() throws -> [LocalRecipeItem] {
        try dbQueue.read { db in
            try LocalRecipeItem.fetchAll(
                db, sql: "SELECT * FROM recipe_items WHERE deleted_at IS NULL ORDER BY id")
        }
    }

    /// Overload of `liveRecipeItems()` scoped to one recipe -- `liveRecipeItems()`
    /// itself stays unfiltered-by-recipe (DashboardModel consumes it that way).
    ///
    /// Ordered by INGREDIENT NAME, mirroring the server's own recipe-items
    /// query (`ORDER BY i.name, ri.id`, api/services/costing.py:62) and spec
    /// §3/§6 -- "there is no order column, the server orders by ingredient
    /// name", so "a saved recipe reopens alphabetically, which is also how
    /// web and the Dashboard already display it". This used to be a plain
    /// `ORDER BY id`; since `recipe_items.id` is a UUIDv7 with no
    /// intra-millisecond counter, two lines added in the same millisecond
    /// (routine when `saveNewRecipe` writes a whole draft in one
    /// transaction) then ordered arbitrarily -- stable for a given recipe,
    /// but neither alphabetical nor insertion order.
    ///
    /// LEFT JOIN, not JOIN, for the same reason `costing.py` uses one: a
    /// line whose ingredient row is missing locally (mid-pull, or pruned)
    /// must still come back rather than vanishing from the editor. Such a
    /// row sorts first here (SQLite puts NULL first ascending) where
    /// Postgres would put it last; the case is unreachable through the app
    /// -- `addRecipeLine` refuses an ingredient that is not live, and a
    /// pulled line always arrives in the same FK-ordered batch as its
    /// ingredient -- so this costs no real parity.
    public func liveRecipeItems(recipeId: String) throws -> [LocalRecipeItem] {
        try dbQueue.read { db in
            try LocalRecipeItem.fetchAll(
                db, sql: """
                    SELECT ri.* FROM recipe_items ri
                    LEFT JOIN ingredients i ON i.id = ri.ingredient_id
                    WHERE ri.recipe_id = ? AND ri.deleted_at IS NULL
                    ORDER BY i.name, ri.id
                    """,
                arguments: [recipeId])
        }
    }

    /// The in-use guard count (mirrors the server's own check at
    /// api/services/sync.py's ingredient-tombstone path).
    public func liveRecipeItemCount(ingredientId: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM recipe_items WHERE ingredient_id = ? AND deleted_at IS NULL",
                arguments: [ingredientId]) ?? 0
        }
    }

    // MARK: - Export / wipe

    /// Pretty JSON array, sorted keys (§13 export affordance).
    public func exportPendingOps() throws -> Data {
        let ops = try pendingOps(state: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ops)
    }

    /// Deletes all rows, including meta — an identity switch or an
    /// org-deleted signal both need to leave nothing behind.
    ///
    /// Returns the `local_path` of every page image the upload outbox
    /// knew about, collected inside the same transaction, BEFORE the
    /// DELETEs (§11): the JPEGs live on the filesystem and would survive a
    /// rows-only wipe, leaving another org's invoice photographs in the
    /// container on a shared or resold phone. Returning the paths rather
    /// than deleting the files here keeps this store free of filesystem
    /// concerns beyond the database file it already owns — the caller
    /// (AppModel) owns the actual file deletion.
    public func wipe() throws -> [String] {
        try dbQueue.write { db in
            let orphanedPaths = try String.fetchAll(
                db, sql: "SELECT local_path FROM pending_uploads")
            try db.execute(sql: "DELETE FROM ingredients")
            try db.execute(sql: "DELETE FROM recipes")
            try db.execute(sql: "DELETE FROM recipe_items")
            try db.execute(sql: "DELETE FROM purchases")
            try db.execute(sql: "DELETE FROM invoices")
            try db.execute(sql: "DELETE FROM invoice_pages")
            try db.execute(sql: "DELETE FROM pending_uploads")
            try db.execute(sql: "DELETE FROM pending_ops")
            try db.execute(sql: "DELETE FROM meta")
            return orphanedPaths
        }
    }

    // MARK: - Invoices (Phase 3a)

    public func invoice(id: String) throws -> LocalInvoice? {
        try dbQueue.read { db in
            try LocalInvoice.fetchOne(
                db, sql: "SELECT * FROM invoices WHERE id = ?", arguments: [id])
        }
    }

    /// One page by row id -- how the uploader turns a queued `page_id`
    /// back into the `(invoice_id, page_no)` the upload endpoints are
    /// keyed by.
    public func invoicePage(id: String) throws -> LocalInvoicePage? {
        try dbQueue.read { db in
            try LocalInvoicePage.fetchOne(
                db, sql: "SELECT * FROM invoice_pages WHERE id = ?", arguments: [id])
        }
    }

    /// Newest first -- an invoice list is read newest first, unlike the
    /// name-ordered reads elsewhere in this file.
    public func liveInvoices() throws -> [LocalInvoice] {
        try dbQueue.read { db in
            try LocalInvoice.fetchAll(
                db, sql: """
                    SELECT * FROM invoices WHERE deleted_at IS NULL
                    ORDER BY captured_at DESC, id DESC
                    """)
        }
    }

    /// Ordered by page number, which is the order a human reads an invoice.
    /// `page_no` is TEXT (every synced column is), so the CAST is required:
    /// a plain string sort puts page 10 before page 2.
    public func livePages(invoiceId: String) throws -> [LocalInvoicePage] {
        try dbQueue.read { db in
            try LocalInvoicePage.fetchAll(
                db, sql: """
                    SELECT * FROM invoice_pages
                    WHERE invoice_id = ? AND deleted_at IS NULL
                    ORDER BY CAST(page_no AS INTEGER), id
                    """,
                arguments: [invoiceId])
        }
    }

    // MARK: - Upload outbox (Phase 3a, local only)

    /// Queues `pageId`'s already-written file for upload. Separate from
    /// `enqueue` (which is the op outbox) on purpose: bytes and rows travel
    /// different paths with different retry semantics (spec 3a-D2).
    public func enqueueUpload(pageId: String, localPath: String, now: Date = Date()) throws {
        try dbQueue.write { db in
            try PendingUpload(
                page_id: pageId, local_path: localPath, state: .queued,
                attempts: 0, last_error: nil,
                created_at: Kernel.canonicalTimestamp(now)
            ).insert(db)
        }
    }

    public func pendingUploads() throws -> [PendingUpload] {
        try dbQueue.read { db in
            try PendingUpload.fetchAll(
                db, sql: "SELECT * FROM pending_uploads ORDER BY created_at, page_id")
        }
    }

    public func updateUpload(_ upload: PendingUpload) throws {
        try dbQueue.write { db in
            try upload.update(db)
        }
    }

    /// Anything not yet `uploaded` -- what the unsynced badge adds to its
    /// pending-op count (spec §9).
    public func pendingUploadCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT count(*) FROM pending_uploads WHERE state != 'uploaded'") ?? 0
        }
    }
}
