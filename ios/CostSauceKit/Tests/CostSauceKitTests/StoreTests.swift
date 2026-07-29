import Testing
import Foundation
import GRDB
@testable import CostSauceKit

@Suite struct StoreTests {

    // MARK: - PullChange fixtures
    //
    // Keys copied verbatim from api/services/sync.py's `_PULL`
    // jsonb_build_object key lists. Timestamps use the Postgres
    // `timestamptz::text` wire shape ("YYYY-MM-DD HH:MM:SS+00") so tests
    // also exercise `applyPullPage`'s canonicalization.

    static func ingredientChange(
        id: String, locationId: String = "loc-1", name: String, baseUnit: String = "lb",
        vendor: String? = nil, category: String? = nil, source: String? = nil,
        clientMutatedAt: String = "2026-07-29 10:00:00+00", serverSeq: Int64,
        updatedAt: String = "2026-07-29 10:00:00+00", deletedAt: String? = nil,
        createdAt: String = "2026-07-29 10:00:00+00"
    ) -> PullChange {
        PullChange(table: "ingredients", row: [
            "id": .string(id),
            "location_id": .string(locationId),
            "name": .string(name),
            "base_unit": .string(baseUnit),
            "vendor": vendor.map(SyncValue.string) ?? .null,
            "category": category.map(SyncValue.string) ?? .null,
            "source": source.map(SyncValue.string) ?? .null,
            "client_mutated_at": .string(clientMutatedAt),
            "server_seq": .int(serverSeq),
            "updated_at": .string(updatedAt),
            "deleted_at": deletedAt.map(SyncValue.string) ?? .null,
            "created_at": .string(createdAt),
        ])
    }

    static func recipeChange(
        id: String, locationId: String = "loc-1", name: String, menuPrice: String = "12.00",
        targetFcPct: String = "30.00", clientMutatedAt: String = "2026-07-29 10:00:00+00",
        serverSeq: Int64, updatedAt: String = "2026-07-29 10:00:00+00", deletedAt: String? = nil,
        createdAt: String = "2026-07-29 10:00:00+00"
    ) -> PullChange {
        PullChange(table: "recipes", row: [
            "id": .string(id),
            "location_id": .string(locationId),
            "name": .string(name),
            "menu_price": .string(menuPrice),
            "target_fc_pct": .string(targetFcPct),
            "client_mutated_at": .string(clientMutatedAt),
            "server_seq": .int(serverSeq),
            "updated_at": .string(updatedAt),
            "deleted_at": deletedAt.map(SyncValue.string) ?? .null,
            "created_at": .string(createdAt),
        ])
    }

    static func recipeItemChange(
        id: String, locationId: String = "loc-1", recipeId: String, ingredientId: String,
        qtyBaseUnits: String = "1.0000", clientMutatedAt: String = "2026-07-29 10:00:00+00",
        serverSeq: Int64, updatedAt: String = "2026-07-29 10:00:00+00", deletedAt: String? = nil,
        createdAt: String = "2026-07-29 10:00:00+00"
    ) -> PullChange {
        PullChange(table: "recipe_items", row: [
            "id": .string(id),
            "location_id": .string(locationId),
            "recipe_id": .string(recipeId),
            "ingredient_id": .string(ingredientId),
            "qty_base_units": .string(qtyBaseUnits),
            "client_mutated_at": .string(clientMutatedAt),
            "server_seq": .int(serverSeq),
            "updated_at": .string(updatedAt),
            "deleted_at": deletedAt.map(SyncValue.string) ?? .null,
            "created_at": .string(createdAt),
        ])
    }

    static func purchaseChange(
        id: String, locationId: String = "loc-1", ingredientId: String,
        purchasedOn: String = "2026-07-29", recordedAt: String = "2026-07-29 10:00:00+00",
        qty: String = "10", unit: String = "lb", qtyInCase: String? = nil,
        qtyBaseUnits: String = "10.0000", totalPrice: String = "20.00", unitPrice: String? = nil,
        source: String? = nil, clientMutatedAt: String = "2026-07-29 10:00:00+00",
        serverSeq: Int64, updatedAt: String = "2026-07-29 10:00:00+00", deletedAt: String? = nil,
        createdAt: String = "2026-07-29 10:00:00+00"
    ) -> PullChange {
        PullChange(table: "purchases", row: [
            "id": .string(id),
            "location_id": .string(locationId),
            "ingredient_id": .string(ingredientId),
            "purchased_on": .string(purchasedOn),
            "recorded_at": .string(recordedAt),
            "qty": .string(qty),
            "unit": .string(unit),
            "qty_in_case": qtyInCase.map(SyncValue.string) ?? .null,
            "qty_base_units": .string(qtyBaseUnits),
            "total_price": .string(totalPrice),
            "unit_price": unitPrice.map(SyncValue.string) ?? .null,
            "source": source.map(SyncValue.string) ?? .null,
            "client_mutated_at": .string(clientMutatedAt),
            "server_seq": .int(serverSeq),
            "updated_at": .string(updatedAt),
            "deleted_at": deletedAt.map(SyncValue.string) ?? .null,
            "created_at": .string(createdAt),
        ])
    }

    /// Asserts `body` throws a `StoreError` with the given `kind`, without
    /// depending on any particular `#expect(throws:)` overload set.
    private func expectStoreError(_ kind: StoreError.Kind, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected to throw StoreError(kind: \(kind))")
        } catch let error as StoreError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("expected StoreError, got \(error)")
        }
    }

    // MARK: - bind / meta

    @Test func bindInsertsMetaWithCursorZero() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        let meta = try store.meta()
        #expect(meta == Meta(user_id: "user-1", org_id: "org-1", location_id: "loc-1", cursor: 0))
    }

    @Test func rebindSameIdentityIsNoOp() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage([], cursor: 5)

        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")

        #expect(try store.meta()?.cursor == 5)
    }

    @Test func bindWithDifferentUserThrowsIdentityMismatch() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")

        expectStoreError(.identityMismatch) {
            try store.bind(userId: "user-2", orgId: "org-1", locationId: "loc-1")
        }
    }

    // MARK: - applyPullPage

    @Test func applyPullPageUpsertsAllFourTablesAndCanonicalizesTimestamps() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")

        let changes: [PullChange] = [
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
            Self.recipeChange(id: "rec-1", name: "Bread", serverSeq: 2),
            Self.recipeItemChange(id: "ri-1", recipeId: "rec-1", ingredientId: "ing-1", serverSeq: 3),
            Self.purchaseChange(id: "pu-1", ingredientId: "ing-1", serverSeq: 4),
        ]
        try store.applyPullPage(changes, cursor: 4)

        let ingredient = try #require(try store.ingredient(id: "ing-1"))
        #expect(ingredient.name == "Flour")
        #expect(ingredient.client_mutated_at == "2026-07-29T10:00:00.000000Z")
        #expect(ingredient.updated_at == "2026-07-29T10:00:00.000000Z")
        #expect(ingredient.created_at == "2026-07-29T10:00:00.000000Z")

        #expect(try store.liveRecipes().first?.name == "Bread")
        #expect(try store.liveRecipeItems().count == 1)

        let purchase = try #require(try store.allLivePurchases().first)
        #expect(purchase.recorded_at == "2026-07-29T10:00:00.000000Z")
        #expect(purchase.purchased_on == "2026-07-29") // date, verbatim -- never canonicalized

        #expect(try store.meta()?.cursor == 4)
    }

    @Test func applyPullPageIsAtomicOnUnknownTable() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")

        let changes: [PullChange] = [
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
            PullChange(table: "bogus", row: ["id": .string("x-1")]),
        ]

        expectStoreError(.unknownTable("bogus")) {
            try store.applyPullPage(changes, cursor: 99)
        }

        // Whole page rolled back: cursor untouched AND the earlier,
        // otherwise-valid ingredient row never landed either.
        #expect(try store.meta()?.cursor == 0)
        #expect(try store.ingredient(id: "ing-1") == nil)
    }

    @Test func pulledTombstoneExcludedFromLiveButQueryableById() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")

        try store.applyPullPage([
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
        ], cursor: 1)
        try store.applyPullPage([
            Self.ingredientChange(
                id: "ing-1", name: "Flour", serverSeq: 2,
                deletedAt: "2026-07-29 11:00:00+00"),
        ], cursor: 2)

        #expect(try store.liveIngredients().isEmpty)

        let tombstoned = try #require(try store.ingredient(id: "ing-1"))
        #expect(tombstoned.deleted_at == "2026-07-29T11:00:00.000000Z")
    }

    // MARK: - rebase

    @Test func rebaseReappliesQueuedOpOverPullOverwrite() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")

        try store.applyPullPage([
            Self.ingredientChange(id: "ing-x", name: "Beef Brisket Raw", serverSeq: 1),
        ], cursor: 1)

        try store.enqueue(PendingOp(
            op_id: "op-1", table: "ingredients", row_id: "ing-x", location_id: "loc-1",
            client_mutated_at: "2026-07-29T10:05:00.000000Z", kind: .update,
            fields: ["name": "Brisket"], state: .queued, reason: nil,
            created_at: "2026-07-29T10:05:00.000000Z"))

        // The server pull overwrites the name yet again with its own truth.
        try store.applyPullPage([
            Self.ingredientChange(id: "ing-x", name: "Beef Brisket Raw", serverSeq: 2),
        ], cursor: 2)

        let ingredient = try #require(try store.ingredient(id: "ing-x"))
        #expect(ingredient.name == "Brisket")

        let stillQueued = try store.pendingOps(state: .queued)
        #expect(stillQueued.count == 1)
        #expect(stillQueued.first?.op_id == "op-1")
    }

    /// Two queued ops edit the same field of the same row, ENQUEUED (i.e.
    /// inserted -- ascending rowid) in the OPPOSITE order of their
    /// `created_at`: `op-late` is inserted first, `op-early` second. Without
    /// an explicit `ORDER BY created_at, op_id` on the rebase replay query,
    /// SQLite's natural rowid/insertion iteration order would replay
    /// `op-late` before `op-early`, so `op-early`'s field would be applied
    /// LAST and silently revert the row to a stale value. With the ordering
    /// fix, replay follows `(created_at, op_id)` regardless of insertion
    /// order, so `op-late` -- the chronologically SECOND (most recent) edit
    /// -- is applied last and wins.
    @Test func rebaseReplaysMultipleQueuedOpsOnTheSameRowInCreatedAtOrder() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")

        try store.applyPullPage([
            Self.ingredientChange(id: "ing-x", name: "Original", serverSeq: 1),
        ], cursor: 1)

        // Inserted first (lower rowid) but chronologically the LATER edit.
        try store.enqueue(PendingOp(
            op_id: "op-late", table: "ingredients", row_id: "ing-x", location_id: "loc-1",
            client_mutated_at: "2026-07-29T10:10:00.000000Z", kind: .update,
            fields: ["name": "Newer Edit"], state: .queued, reason: nil,
            created_at: "2026-07-29T10:10:00.000000Z"))
        // Inserted second (higher rowid) but chronologically the EARLIER edit.
        try store.enqueue(PendingOp(
            op_id: "op-early", table: "ingredients", row_id: "ing-x", location_id: "loc-1",
            client_mutated_at: "2026-07-29T10:05:00.000000Z", kind: .update,
            fields: ["name": "Older Edit"], state: .queued, reason: nil,
            created_at: "2026-07-29T10:05:00.000000Z"))

        // A pull page touches the row, triggering rebase.
        try store.applyPullPage([
            Self.ingredientChange(id: "ing-x", name: "Original", serverSeq: 2),
        ], cursor: 2)

        // (created_at, op_id) order is op-early (10:05) then op-late
        // (10:10), so op-late's field -- the chronologically SECOND edit --
        // wins the replay.
        let ingredient = try #require(try store.ingredient(id: "ing-x"))
        #expect(ingredient.name == "Newer Edit")
    }

    // MARK: - enqueue

    @Test func enqueueAppliesFieldsToLocalRowInTheSameCall() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage([
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
        ], cursor: 1)

        try store.enqueue(PendingOp(
            op_id: "op-1", table: "ingredients", row_id: "ing-1", location_id: "loc-1",
            client_mutated_at: "2026-07-29T10:05:00.000000Z", kind: .update,
            fields: ["name": "Bread Flour"], state: .queued, reason: nil,
            created_at: "2026-07-29T10:05:00.000000Z"))

        #expect(try store.ingredient(id: "ing-1")?.name == "Bread Flour")
    }

    // MARK: - pendingCount

    @Test func pendingCountCountsQueuedAndNeedsAttention() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage([
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
        ], cursor: 1)

        try store.enqueue(PendingOp(
            op_id: "op-1", table: "ingredients", row_id: "ing-1", location_id: "loc-1",
            client_mutated_at: "t1", kind: .update, fields: ["name": "A"],
            state: .queued, reason: nil, created_at: "t1"))
        try store.enqueue(PendingOp(
            op_id: "op-2", table: "ingredients", row_id: "ing-1", location_id: "loc-1",
            client_mutated_at: "t2", kind: .update, fields: ["name": "B"],
            state: .needsAttention, reason: "rejected", created_at: "t2"))

        #expect(try store.pendingCount() == 2)
    }

    // MARK: - adoptCanonicalRow

    @Test func adoptCanonicalRowRemovesTheMintedRow() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage([
            Self.recipeChange(id: "rec-1", name: "Bread", serverSeq: 1),
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 2),
            Self.recipeItemChange(
                id: "minted-1", recipeId: "rec-1", ingredientId: "ing-1", serverSeq: 3),
        ], cursor: 3)
        #expect(try store.liveRecipeItems().count == 1)

        try store.adoptCanonicalRow(
            table: "recipe_items", mintedId: "minted-1", canonicalId: "canonical-1")

        #expect(try store.liveRecipeItems().isEmpty)
    }

    // MARK: - livePurchases ordering

    @Test func livePurchasesOrderingMatchesWrittenRule() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage([
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
            // Same purchased_on AND same recorded_at as pu-c -- tie-broken by id DESC.
            Self.purchaseChange(
                id: "pu-d", ingredientId: "ing-1", purchasedOn: "2026-07-29",
                recordedAt: "2026-07-29 10:00:00+00", serverSeq: 2),
            Self.purchaseChange(
                id: "pu-c", ingredientId: "ing-1", purchasedOn: "2026-07-29",
                recordedAt: "2026-07-29 10:00:00+00", serverSeq: 3),
            // Same date, earlier recorded_at.
            Self.purchaseChange(
                id: "pu-a", ingredientId: "ing-1", purchasedOn: "2026-07-29",
                recordedAt: "2026-07-29 09:00:00+00", serverSeq: 4),
            // Earlier date entirely.
            Self.purchaseChange(
                id: "pu-b", ingredientId: "ing-1", purchasedOn: "2026-07-28",
                recordedAt: "2026-07-28 23:00:00+00", serverSeq: 5),
        ], cursor: 5)

        let purchases = try store.livePurchases(ingredientId: "ing-1")
        #expect(purchases.map(\.id) == ["pu-d", "pu-c", "pu-a", "pu-b"])
    }

    // MARK: - exportPendingOps

    @Test func exportPendingOpsRoundTripsNeedsAttentionOpWithReason() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage([
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
        ], cursor: 1)

        try store.enqueue(PendingOp(
            op_id: "op-1", table: "ingredients", row_id: "ing-1", location_id: "loc-1",
            client_mutated_at: "2026-07-29T10:05:00.000000Z", kind: .update,
            fields: ["name": "Bread Flour"], state: .queued, reason: nil,
            created_at: "2026-07-29T10:05:00.000000Z"))
        try store.markNeedsAttention(opId: "op-1", reason: "duplicate")

        let data = try store.exportPendingOps()
        let decoded = try JSONDecoder().decode([PendingOp].self, from: data)

        #expect(decoded.count == 1)
        let op = try #require(decoded.first)
        #expect(op.op_id == "op-1")
        #expect(op.state == .needsAttention)
        #expect(op.reason == "duplicate")
        #expect(op.fields == ["name": "Bread Flour"])

        // Pretty-printed and sorted-keys, per §13.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\n"))
        #expect(json.contains("\"needs_attention\""))
    }

    // MARK: - on-disk store

    /// Not part of the brief's in-memory Step-1 list, but `init(path:)` is
    /// still frozen public API (later tasks construct the real on-disk
    /// store this way) -- exercise directory creation, migration, and the
    /// best-effort file-protection attribute together at least once.
    @Test func onDiskStoreCreatesDirectoryMigratesAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let store = try LocalStore(path: dbPath)
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage([
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
        ], cursor: 1)

        #expect(FileManager.default.fileExists(atPath: dbPath))
        #expect(try store.meta()?.cursor == 1)
        #expect(try store.ingredient(id: "ing-1")?.name == "Flour")

        // Re-opening the same file must not re-run (or fail re-running) the
        // migrator, and must see the data the first instance wrote.
        let reopened = try LocalStore(path: dbPath)
        #expect(try reopened.ingredient(id: "ing-1")?.name == "Flour")
    }

    // MARK: - wipe

    @Test func wipeEmptiesEverythingIncludingMeta() throws {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        try store.applyPullPage([
            Self.ingredientChange(id: "ing-1", name: "Flour", serverSeq: 1),
            Self.recipeChange(id: "rec-1", name: "Bread", serverSeq: 2),
            Self.recipeItemChange(id: "ri-1", recipeId: "rec-1", ingredientId: "ing-1", serverSeq: 3),
            Self.purchaseChange(id: "pu-1", ingredientId: "ing-1", serverSeq: 4),
        ], cursor: 4)
        try store.enqueue(PendingOp(
            op_id: "op-1", table: "ingredients", row_id: "ing-1", location_id: "loc-1",
            client_mutated_at: "t1", kind: .update, fields: ["name": "X"],
            state: .queued, reason: nil, created_at: "t1"))

        try store.wipe()

        #expect(try store.meta() == nil)
        #expect(try store.liveIngredients().isEmpty)
        #expect(try store.liveRecipes().isEmpty)
        #expect(try store.liveRecipeItems().isEmpty)
        #expect(try store.allLivePurchases().isEmpty)
        #expect(try store.pendingOps(state: nil).isEmpty)
    }
}
