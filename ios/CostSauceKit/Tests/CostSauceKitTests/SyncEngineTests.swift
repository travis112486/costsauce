// Client-side mirror of tests/test_sync_scenarios.py (Phase 1c) for the
// device sync engine (Task 8) -- against `FakeSyncServer`, an in-process
// contract double mounted on `StubTransport`.
//
// Fixed canonical timestamps (`t1 < t2 < t3`, `Kernel.canonicalTimestamp`'s
// own "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'" shape) are used throughout instead
// of `Date()` so ordering/staleness comparisons are deterministic and
// legible from the string alone.

import Testing
import Foundation
@testable import CostSauceKit

@Suite(.serialized)
struct SyncEngineTests {
    let baseURL = URL(string: "https://api.test")!
    let t1 = "2026-07-29T09:00:00.000000Z"
    let t2 = "2026-07-29T10:00:00.000000Z"
    let t3 = "2026-07-29T11:00:00.000000Z"

    private func makeStore() throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
        return store
    }

    private func makeApi(token: String = "tok") -> ApiClient {
        ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { token }
    }

    // MARK: - state stream

    @Test func stateStreamEmitsCatchingUpThenCaughtUpInOrder() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        // Registration is synchronous (SyncEngine.stateStream doc comment) --
        // by the time this line returns, the continuation is already
        // listening, so no transition can be missed to a race with the
        // collector Task below.
        let stream = engine.stateStream
        let collector = Task<[SyncState], Never> {
            var states: [SyncState] = []
            for await state in stream {
                states.append(state)
                if states.count == 2 { break }
            }
            return states
        }

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        let states = await collector.value
        #expect(states == [.catchingUp, .caughtUp])
    }

    // MARK: - multi-page pull + resume from persisted cursor

    @Test func multiPagePullAppliesAtomicallyPerPageAndNewEngineResumesFromPersistedCursor() async throws {
        let server = FakeSyncServer()
        for i in 1...5 {
            server.seed(
                table: "ingredients", id: "ing-\(i)", clientMutatedAt: t1,
                fields: ["name": "Ingredient \(i)", "base_unit": "lb"])
        }
        server.pageSize = 2
        server.failPullOnCall = 2  // page 1 succeeds; page 2 "kills the app"

        let store = try makeStore()
        let api = makeApi()
        let engine1 = SyncEngine(store: store, api: api, orgId: "org-1")

        try await StubTransport.withStub(server.responder()) {
            await engine1.syncNow()
        }

        guard case .blocked(.offline) = await engine1.state else {
            Issue.record("expected blocked(.offline) after the simulated kill, got \(await engine1.state)")
            return
        }
        // Page 1's transaction (upsert + cursor advance) already committed --
        // a killed app resumes mid-stream, it doesn't lose page 1.
        #expect(try store.meta()?.cursor == 2)
        #expect(try store.liveIngredients().count == 2)

        // A brand-new engine over the SAME store, holding no in-memory
        // progress of its own, must resume purely from the persisted cursor.
        let engine2 = SyncEngine(store: store, api: api, orgId: "org-1")
        // The since= assertions read `StubTransport.recordedRequests` WHILE
        // still holding withStub's gate -- reading it after the block
        // returns would race any OTHER concurrently-scheduled test suite's
        // own withStub call, which resets `recordedRequests` the instant it
        // installs its responder.
        let sinceValues: [String] = try await StubTransport.withStub(server.responder()) {
            await engine2.syncNow()
            return StubTransport.recordedRequests.compactMap { req, _ -> String? in
                guard req.httpMethod == "GET" else { return nil }
                return URLComponents(url: req.url!, resolvingAgainstBaseURL: true)?
                    .queryItems?.first(where: { $0.name == "since" })?.value
            }
        }

        #expect(await engine2.state == .caughtUp)
        #expect(try store.meta()?.cursor == 5)
        #expect(try store.liveIngredients().count == 5)

        // Direct proof it never re-walked from the start: within engine2's
        // OWN request window, no GET carries since=0, and the first one is
        // since=2 (the persisted cursor).
        #expect(!sinceValues.contains("0"))
        #expect(sinceValues.first == "2")
    }

    // MARK: - local create -> push -> trailing pull echo

    @Test func localCreatePushEchoesRowWithServerSeqAndDeletesOpViaTrailingPull() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")

        let rowId = try edits.createIngredient(name: "Flour", baseUnit: "lb", vendor: nil, category: nil)
        #expect(try store.pendingOps(state: .queued).count == 1)

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).isEmpty)
        let ingredient = try #require(try store.ingredient(id: rowId))
        #expect(ingredient.name == "Flour")
        #expect(ingredient.server_seq == 1)
    }

    // MARK: - POST-cursor never adopted

    @Test func pushResponseCursorIsNeverAdoptedOnlyTrailingPullAdvancesCursor() async throws {
        let server = FakeSyncServer()
        server.pushResponseCursorOverride = 99999  // other devices' unrelated writes, far ahead

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")
        _ = try edits.createIngredient(name: "Sugar", baseUnit: "lb", vendor: nil, category: nil)

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        // Only the pull loop's own cursor (the just-echoed row, seq 1) is
        // ever written -- the push response's inflated 99999 is discarded.
        #expect(try store.meta()?.cursor == 1)
    }

    // MARK: - replay on op_id reuse

    @Test func replayOnOpIdReuseAfterDroppedPushResponseAppliesExactlyOnce() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")
        let rowId = try edits.createIngredient(name: "Pepper", baseUnit: "oz", vendor: nil, category: nil)
        let opId = try #require(try store.pendingOps(state: .queued).first?.op_id)

        server.dropNextPushResponse = true
        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }
        // The push applied (and ledgered) server-side, but the response
        // never made it back -- locally this looks exactly like nothing
        // happened: still queued, same op_id.
        guard case .blocked(.offline) = await engine.state else {
            Issue.record("expected blocked(.offline) after the dropped response, got \(await engine.state)")
            return
        }
        #expect(try store.pendingOps(state: .queued).map(\.op_id) == [opId])

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).isEmpty)
        let ingredient = try #require(try store.ingredient(id: rowId))
        #expect(ingredient.name == "Pepper")
        #expect(ingredient.server_seq == 1)
        #expect(server.rowCount(table: "ingredients") == 1)  // never double-applied
    }

    // MARK: - stale: recipe_items ON CONFLICT arbitration (adoptCanonicalRow)

    @Test func staleRecipeItemConflictAdoptsCanonicalRowAndConvergesToServerValue() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "recipes", id: "rec-1", clientMutatedAt: t1,
            fields: ["name": "Bread", "menu_price": "12.00", "target_fc_pct": "30.00"])
        server.seed(
            table: "ingredients", id: "ing-1", clientMutatedAt: t1,
            fields: ["name": "Flour", "base_unit": "lb"])
        server.seed(
            table: "recipe_items", id: "canonical-1", clientMutatedAt: t2,
            fields: ["recipe_id": "rec-1", "ingredient_id": "ing-1", "qty_base_units": "1.0000"])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }
        #expect(try store.liveRecipeItems().count == 1)

        // Offline, the device re-creates its own copy of the SAME line (it
        // never learned the canonical row already exists) -- minted id,
        // timestamped OLDER than the canonical row, so it must lose.
        try store.enqueue(PendingOp(
            op_id: "op-minted", table: "recipe_items", row_id: "minted-1", location_id: "loc-1",
            client_mutated_at: t1, kind: .insert,
            fields: ["recipe_id": "rec-1", "ingredient_id": "ing-1", "qty_base_units": "2.0000"],
            state: .queued, reason: nil, created_at: t1))
        #expect(try store.liveRecipeItems().count == 2)  // temporary local over-count

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).isEmpty)  // silently dropped, no needs_attention
        let items = try store.liveRecipeItems()
        #expect(items.count == 1)  // never 2 -- LocalStore.adoptCanonicalRow's own contract
        #expect(items.first?.id == "canonical-1")
        #expect(items.first?.qty_base_units == "1.0000")  // server value stands
    }

    // MARK: - recipe_items ON CONFLICT: equal-timestamp tie-break (Task 5, FIX 1)

    /// The real server's upsert only rejects a STRICTLY older write (`WHERE
    /// recipe_items.client_mutated_at <= EXCLUDED.client_mutated_at`,
    /// api/services/sync.py:257) -- an EQUAL timestamp wins and folds onto
    /// the canonical row. Before FIX 1, `FakeSyncServer` rejected ties too
    /// (its own `<=` inverted the winner), which would make this insert
    /// come back `stale` and leave the canonical row's original qty
    /// standing instead of the tying insert's value.
    @Test func recipeItemInsertAtEqualTimestampWinsArbitrationAndItsValueStands() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "recipes", id: "rec-1", clientMutatedAt: t1,
            fields: ["name": "Bread", "menu_price": "12.00", "target_fc_pct": "30.00"])
        server.seed(
            table: "ingredients", id: "ing-1", clientMutatedAt: t1,
            fields: ["name": "Flour", "base_unit": "lb"])
        server.seed(
            table: "recipe_items", id: "canonical-1", clientMutatedAt: t2,
            fields: ["recipe_id": "rec-1", "ingredient_id": "ing-1", "qty_base_units": "1.0000"])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        // Offline, this device re-creates its own copy of the SAME line at
        // the EXACT SAME timestamp as the canonical row's -- a genuine tie,
        // not a strictly-older loser (that case is the existing test right
        // below this one).
        try store.enqueue(PendingOp(
            op_id: "op-tie", table: "recipe_items", row_id: "minted-tie", location_id: "loc-1",
            client_mutated_at: t2, kind: .insert,
            fields: ["recipe_id": "rec-1", "ingredient_id": "ing-1", "qty_base_units": "3.0000"],
            state: .queued, reason: nil, created_at: t2))

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).isEmpty)
        let items = try store.liveRecipeItems()
        #expect(items.count == 1)  // still one canonical row, never two
        #expect(items.first?.id == "canonical-1")
        #expect(items.first?.qty_base_units == "3.0000")  // the TYING insert's value stands, not the original 1.0000
    }

    // MARK: - recipe_items parent liveness on insert (Task 5, FIX 2)

    /// Mirrors `_PARENT_CHECKS` (api/services/sync.py:44-50): a
    /// `recipe_items` INSERT whose `recipe_id`/`ingredient_id` doesn't name
    /// a live row at this location must park as `needs_attention`, not
    /// silently apply an orphaned line. Reachable per spec §7 if a
    /// recipe's own insert op parked, or an ingredient was tombstoned by
    /// another device between this device composing the line and pushing
    /// it.
    @Test func recipeItemInsertWithNonLiveParentParksAsNeedsAttentionNotDeleted() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "recipes", id: "rec-1", clientMutatedAt: t1,
            fields: ["name": "Bread", "menu_price": "12.00", "target_fc_pct": "30.00"])
        server.seed(
            table: "ingredients", id: "ing-1", clientMutatedAt: t1,
            fields: ["name": "Flour", "base_unit": "lb"])
        server.seed(
            table: "ingredients", id: "ing-dead", clientMutatedAt: t1,
            fields: ["name": "Ghost", "base_unit": "lb", "deleted_at": t1])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        // (1) recipe_id names no server row at all.
        try store.enqueue(PendingOp(
            op_id: "op-no-recipe", table: "recipe_items", row_id: "line-1", location_id: "loc-1",
            client_mutated_at: t2, kind: .insert,
            fields: ["recipe_id": "rec-missing", "ingredient_id": "ing-1", "qty_base_units": "1.0000"],
            state: .queued, reason: nil, created_at: t2))
        // (2) ingredient_id names a TOMBSTONED server row.
        try store.enqueue(PendingOp(
            op_id: "op-dead-ingredient", table: "recipe_items", row_id: "line-2", location_id: "loc-1",
            client_mutated_at: t2, kind: .insert,
            fields: ["recipe_id": "rec-1", "ingredient_id": "ing-dead", "qty_base_units": "1.0000"],
            state: .queued, reason: nil, created_at: t2))

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        // Still present as two ops total -- parked, not deleted.
        #expect(try store.pendingOps(state: nil).count == 2)
        #expect(try store.pendingOps(state: .queued).isEmpty)
        let parked = try store.pendingOps(state: .needsAttention)
        #expect(parked.count == 2)
        #expect(parked.first(where: { $0.op_id == "op-no-recipe" })?.reason == "referenced recipe is not live")
        #expect(
            parked.first(where: { $0.op_id == "op-dead-ingredient" })?.reason
                == "referenced ingredient is not live")
        #expect(server.rowCount(table: "recipe_items") == 0)  // neither orphan ever landed
    }

    // MARK: - create-with-lines in one push batch (TABLE_ORDER FK safety)

    /// `saveNewRecipe` (Task 3) mints a `recipes` insert plus one
    /// `recipe_items` insert per line, all in ONE `enqueueBatch` call, and
    /// they can go out in the SAME push -- the server's `TABLE_ORDER`
    /// ranking applies every `recipes` op before any `recipe_items` op
    /// within a batch (api/services/sync.py:23, mirrored by
    /// `FakeSyncServer`'s own `tableOrder` sort in `handlePush`), so the
    /// lines' FK parent is already live by the time their inserts run even
    /// though it arrived in the identical wire batch.
    @Test func createWithLinesInOneBatchAppliesAllThreeDespiteSameBatchFKOrdering() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "ingredients", id: "ing-flour", clientMutatedAt: t1,
            fields: ["name": "Flour", "base_unit": "lb"])
        server.seed(
            table: "ingredients", id: "ing-salt", clientMutatedAt: t1,
            fields: ["name": "Salt", "base_unit": "oz"])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        let draft = RecipeDraft(
            name: "Bread", menuPrice: "12.00", targetFcPct: "30.00",
            lines: [
                RecipeDraft.Line(ingredientId: "ing-flour", qty: "1.0000"),
                RecipeDraft.Line(ingredientId: "ing-salt", qty: "0.5000"),
            ])
        let recipeId = try edits.saveNewRecipe(draft)
        #expect(try store.pendingOps(state: .queued).count == 3)  // 1 recipe + 2 lines

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).isEmpty)  // all 3 applied, none parked
        #expect(server.rowCount(table: "recipes") == 1)
        #expect(server.rowCount(table: "recipe_items") == 2)
        #expect(try store.recipe(id: recipeId)?.name == "Bread")
        #expect(try store.liveRecipeItems(recipeId: recipeId).count == 2)
    }

    // MARK: - delete fan-out round-trip (Task 2 end-to-end guard)

    /// `tombstoneRecipe` enqueues N+1 ops (one tombstone per live line plus
    /// the recipe's own) in ONE batch. Proves the whole fan-out survives a
    /// real push+pull round-trip against the double: every op applies, and
    /// the server ends with zero live lines for the deleted recipe.
    @Test func deleteFanOutRoundTripAppliesEveryTombstoneAndLeavesNoLiveLines() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "recipes", id: "rec-1", clientMutatedAt: t1,
            fields: ["name": "Bread", "menu_price": "12.00", "target_fc_pct": "30.00"])
        server.seed(
            table: "ingredients", id: "ing-flour", clientMutatedAt: t1,
            fields: ["name": "Flour", "base_unit": "lb"])
        server.seed(
            table: "ingredients", id: "ing-salt", clientMutatedAt: t1,
            fields: ["name": "Salt", "base_unit": "oz"])
        server.seed(
            table: "recipe_items", id: "line-1", clientMutatedAt: t1,
            fields: ["recipe_id": "rec-1", "ingredient_id": "ing-flour", "qty_base_units": "1.0000"])
        server.seed(
            table: "recipe_items", id: "line-2", clientMutatedAt: t1,
            fields: ["recipe_id": "rec-1", "ingredient_id": "ing-salt", "qty_base_units": "0.5000"])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }
        #expect(try store.liveRecipeItems(recipeId: "rec-1").count == 2)

        try edits.tombstoneRecipe(id: "rec-1")
        #expect(try store.pendingOps(state: .queued).count == 3)  // recipe + 2 lines, one timestamp

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).isEmpty)  // every op applied
        #expect(server.rowCount(table: "recipe_items") == 0)
        #expect(try store.liveRecipeItems(recipeId: "rec-1").isEmpty)
        #expect(try store.recipe(id: "rec-1")?.deleted_at != nil)
    }

    // MARK: - stale/deleted: quantity edit against a server-tombstoned line

    /// Spec §7's "one deliberate exception to silence": a quantity edit
    /// against a line another device already tombstoned must PARK as
    /// `needs_attention` rather than silently vanish like a plain
    /// stale/older LWW loss, so the user can see the edit didn't land. The
    /// double already returns the server's exact `stale`/`reason: "deleted"`
    /// for this (locked protocol, `docs/superpowers/plans/
    /// 2026-07-27-phase-1c-sync-protocol.md:24`: "Tombstones are terminal
    /// -- any op against a tombstoned row is `stale` with `reason:
    /// "deleted"` regardless of clocks"). What's missing is the CLIENT side:
    /// `SyncEngine.apply()` currently treats every `stale` result
    /// identically (`case "applied", "stale": ... deleteOp`, SyncEngine.swift
    /// :335-347) with no branch on `reason`, so this park never happens
    /// today -- a genuine production gap in the frozen 2a engine, not
    /// something this test-only task may fix (task-5-report.md has the full
    /// writeup). Disabled rather than left red so `swift test` stays a
    /// trustworthy gate; re-enable once `apply()` grows the `reason ==
    /// "deleted"` branch.
    @Test(
        .disabled(
            "Production gap in SyncEngine.apply() (SyncEngine.swift:335-347): every `stale` result deletes the op regardless of `reason`, so a tombstoned-row rejection never parks as needs_attention the way spec §7 requires. Out of scope for this test-only task -- see task-5-report.md."
        )
    )
    func quantityEditAgainstServerTombstonedLineParksAsNeedsAttention() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "recipes", id: "rec-1", clientMutatedAt: t1,
            fields: ["name": "Bread", "menu_price": "12.00", "target_fc_pct": "30.00"])
        server.seed(
            table: "ingredients", id: "ing-1", clientMutatedAt: t1,
            fields: ["name": "Flour", "base_unit": "lb"])
        server.seed(
            table: "recipe_items", id: "line-1", clientMutatedAt: t1,
            fields: ["recipe_id": "rec-1", "ingredient_id": "ing-1", "qty_base_units": "1.0000"])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }
        #expect(try store.liveRecipeItems(recipeId: "rec-1").count == 1)

        // Another device tombstones the line server-side; this device
        // hasn't pulled that yet and queues a quantity edit against it.
        server.seed(
            table: "recipe_items", id: "line-1", clientMutatedAt: t2,
            fields: [
                "recipe_id": "rec-1", "ingredient_id": "ing-1", "qty_base_units": "1.0000",
                "deleted_at": t2,
            ])
        try store.enqueue(PendingOp(
            op_id: "op-qty-on-dead-line", table: "recipe_items", row_id: "line-1", location_id: "loc-1",
            client_mutated_at: t3, kind: .update, fields: ["qty_base_units": "2.0000"],
            state: .queued, reason: nil, created_at: t3))

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).count == 1)  // parked, not deleted
        let parked = try store.pendingOps(state: .needsAttention)
        #expect(parked.count == 1)
        #expect(parked.first?.op_id == "op-qty-on-dead-line")
        #expect(parked.first?.reason == "deleted")
        #expect(try store.pendingOps(state: .queued).isEmpty)
        // Regardless of the park, the trailing pull still removes the line locally.
        #expect(try store.liveRecipeItems(recipeId: "rec-1").isEmpty)
    }

    // MARK: - stale: plain older-edit silently dropped

    @Test func staleOlderUpdateSilentlyDropsOpWithoutNeedsAttention() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "ingredients", id: "ing-1", clientMutatedAt: t2,
            fields: ["name": "Original", "base_unit": "lb"])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }
        #expect(try store.ingredient(id: "ing-1")?.name == "Original")

        // A locally-queued edit stamped BEFORE the row's already-known
        // client_mutated_at (t2) -- must lose to the server's value,
        // silently (§4.2's LWW anti-case, client-side).
        try store.enqueue(PendingOp(
            op_id: "op-stale", table: "ingredients", row_id: "ing-1", location_id: "loc-1",
            client_mutated_at: t1, kind: .update, fields: ["name": "Stale Edit"],
            state: .queued, reason: nil, created_at: t1))

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        // Gone from the queue entirely -- never parked as needs_attention,
        // which is reserved for genuinely unresolvable ops (§5.5).
        #expect(try store.pendingOps(state: nil).isEmpty)
        #expect(try store.pendingOps(state: .needsAttention).isEmpty)
        // §14 convergence (review finding 3): a `stale` result forces a full
        // baseline re-pull (cursor reset to 0), so the row is guaranteed to
        // be re-fetched with the rejected op already gone from pending_ops
        // -- nothing left to rebase-overlay the locally-rejected edit back
        // on top. The local copy must show the SERVER's value, not the
        // value that was silently dropped -- never a value that exists
        // nowhere.
        #expect(try store.ingredient(id: "ing-1")?.name == "Original")
    }

    /// Review finding 3, round 2: a SECOND, later-discovered stale conflict
    /// must ALSO force a re-pull, not just the first one the drain loop
    /// sees. Without re-arming the reset every iteration (a one-shot flag
    /// instead), this row's rejected value would be stuck locally forever
    /// -- its server_seq is already <= the cursor the FIRST reset's pull
    /// already advanced past, so a plain incremental pull never revisits
    /// it.
    @Test func secondStaleConflictDiscoveredMidDrainLoopAlsoForcesReset() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "ingredients", id: "ing-a", clientMutatedAt: t2,
            fields: ["name": "A-Server", "base_unit": "lb"])
        server.seed(
            table: "ingredients", id: "ing-b", clientMutatedAt: t2,
            fields: ["name": "B-Server", "base_unit": "lb"])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        // Prep: pull both rows in so the device has a cursor past them
        // BEFORE the hook below is armed -- the compound scenario is about
        // what happens once syncing is already underway, not about the
        // very first pull.
        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }
        #expect(await engine.state == .caughtUp)

        // ing-a's local edit is already queued and already stale (older
        // than the row's known t2) -- this is iteration 1's conflict.
        try store.enqueue(PendingOp(
            op_id: "op-a-stale", table: "ingredients", row_id: "ing-a", location_id: "loc-1",
            client_mutated_at: t1, kind: .update, fields: ["name": "A-Stale"],
            state: .queued, reason: nil, created_at: t1))

        // GET call count within the syncNow() below (pullCallCount carries
        // over from the prep sync's 2 calls): #3 is this call's initial
        // pullLoop (since=2, nothing new, precedes any push); #4 is
        // iteration 1's reset-triggered full re-pull (since=0, after
        // op-a-stale's push already came back stale and reset the
        // baseline) -- exactly where a mid-flight local edit would land in
        // the real world. Enqueueing here means op-b-stale is in
        // pending_ops before THIS page's applyPullPage/rebase runs, so it
        // gets rebase-overlaid onto the just-re-fetched ing-b row, exactly
        // like op-a-stale was on an earlier pull. It's ALSO stale (t1 <
        // ing-b's known t2) but hasn't been pushed yet -- iteration 2 is
        // the one that discovers that, which is the whole point of this
        // test.
        server.onPullCall = { count in
            if count == 4 {
                try? store.enqueue(PendingOp(
                    op_id: "op-b-stale", table: "ingredients", row_id: "ing-b", location_id: "loc-1",
                    client_mutated_at: t1, kind: .update, fields: ["name": "B-Stale"],
                    state: .queued, reason: nil, created_at: t1))
            }
        }

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).isEmpty)
        // BOTH rows must show the server's value -- ing-a from iteration
        // 1's reset, ing-b from iteration 2's (the one this fix adds).
        #expect(try store.ingredient(id: "ing-a")?.name == "A-Server")
        #expect(try store.ingredient(id: "ing-b")?.name == "B-Server")
    }

    // MARK: - reentrancy (review finding 1)

    @Test func concurrentSyncNowCallsCoalesceEachOpPushedExactlyOnce() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")
        _ = try edits.createIngredient(name: "Onion", baseUnit: "lb", vendor: nil, category: nil)
        _ = try edits.createIngredient(name: "Garlic", baseUnit: "lb", vendor: nil, category: nil)
        #expect(try store.pendingOps(state: .queued).count == 2)

        // Two concurrent syncNow() calls on the SAME actor -- without
        // coalescing, each `await` inside performSync is a point where the
        // second call can start running interleaved with the first
        // (actors are reentrant across suspension points), independently
        // reading the SAME still-queued ops and double-pushing them.
        let opIdCounts: [String: Int] = try await StubTransport.withStub(server.responder()) {
            async let first: Void = engine.syncNow()
            async let second: Void = engine.syncNow()
            _ = await (first, second)

            var counts: [String: Int] = [:]
            for (request, body) in StubTransport.recordedRequests where request.httpMethod == "POST" {
                guard let body,
                    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                    let ops = object["ops"] as? [[String: Any]]
                else { continue }
                for op in ops {
                    if let opId = op["op_id"] as? String {
                        counts[opId, default: 0] += 1
                    }
                }
            }
            return counts
        }

        #expect(await engine.state == .caughtUp)
        #expect(try store.pendingOps(state: nil).isEmpty)
        // Every op_id appears in exactly ONE POST body across BOTH
        // concurrent calls combined -- coalesced onto one real sync, never
        // pushed twice.
        #expect(opIdCounts.count == 2)
        #expect(opIdCounts.values.allSatisfy { $0 == 1 })
    }

    // MARK: - caughtUp only once no push work remains (review finding 2)

    @Test func enqueuedOpMidSyncDelaysCaughtUpUntilItIsPushed() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")

        let firstRowId = try edits.createIngredient(name: "Onion", baseUnit: "lb", vendor: nil, category: nil)
        var secondRowId: String?

        // Fires during the SECOND GET /sync call of this syncNow() -- the
        // trailing pull that follows op-1's push -- simulating a local edit
        // (from anywhere in the app; LocalStore.enqueue is plain and
        // thread-safe, callable any time) landing while the sync is still
        // mid-flight.
        server.onPullCall = { callCount in
            if callCount == 2 {
                secondRowId = try? edits.createIngredient(
                    name: "Garlic", baseUnit: "lb", vendor: nil, category: nil)
            }
        }

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        // Both ops -- the original and the one that landed mid-sync -- were
        // actually pushed before caughtUp was declared; neither is left
        // behind a state that already claims there's nothing outstanding.
        #expect(try store.pendingOps(state: nil).isEmpty)
        let secondId = try #require(secondRowId)
        #expect((try store.ingredient(id: firstRowId)?.server_seq ?? 0) > 0)
        #expect((try store.ingredient(id: secondId)?.server_seq ?? 0) > 0)
    }

    // MARK: - unrecognized push status (review finding 4)

    @Test func unrecognizedPushStatusParksOpInsteadOfDeletingIt() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")
        _ = try edits.createIngredient(name: "Cumin", baseUnit: "oz", vendor: nil, category: nil)
        let opId = try #require(try store.pendingOps(state: .queued).first?.op_id)
        server.bogusStatusOpId = opId

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .caughtUp)
        // §13 "never lose local work": an unrecognized status must park the
        // op, not silently delete it.
        let parked = try store.pendingOps(state: .needsAttention)
        #expect(parked.count == 1)
        #expect(parked.first?.op_id == opId)
        #expect(parked.first?.reason == "unrecognized result: totally_unrecognized_status")
        #expect(try store.pendingOps(state: .queued).isEmpty)
    }

    // MARK: - needs_attention

    @Test func needsAttentionParksWithReasonAndExcludedFromNextPushBatch() async throws {
        let server = FakeSyncServer()
        server.seed(
            table: "ingredients", id: "ing-1", clientMutatedAt: t1,
            fields: ["name": "Flour", "base_unit": "lb"])

        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        // "source" is a real LOCAL column (LocalIngredient.source) -- so
        // `enqueue` applies it locally without complaint -- but it is
        // insert-only server-side (UPDATE_FIELDS.ingredients omits it,
        // api/services/sync.py:33: "identity fields immutable: repointing
        // is merge's job, never sync's"), so the PUSH must reject it.
        try store.enqueue(PendingOp(
            op_id: "op-bad", table: "ingredients", row_id: "ing-1", location_id: "loc-1",
            client_mutated_at: t2, kind: .update, fields: ["source": "Costco"],
            state: .queued, reason: nil, created_at: t2))

        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        let parked = try store.pendingOps(state: .needsAttention)
        #expect(parked.count == 1)
        #expect(parked.first?.op_id == "op-bad")
        #expect(parked.first?.reason == "unknown or immutable field: source")
        #expect(try store.pendingOps(state: .queued).isEmpty)

        // A second syncNow() must not retry it -- terminal until Task 14's
        // UI resolves it (§5.5) -- proven directly: no POST body at all,
        // since the only pending op is needs_attention, not queued. Read
        // INSIDE the withStub closure (see the multi-page test's comment
        // for why reading it after would race another suite).
        let postRequestCount: Int = try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
            return StubTransport.recordedRequests.filter { $0.request.httpMethod == "POST" }.count
        }
        #expect(postRequestCount == 0)
        let stillParked = try store.pendingOps(state: .needsAttention)
        #expect(stillParked.count == 1)
        #expect(stillParked.first?.reason == "unknown or immutable field: source")
    }

    // MARK: - 401 / 410

    @Test func unauthorizedBlocksSyncAndLeavesQueueIntact() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")
        _ = try edits.createIngredient(name: "Salt", baseUnit: "oz", vendor: nil, category: nil)
        #expect(try store.pendingOps(state: .queued).count == 1)

        server.forceUnauthorized = true
        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .blocked(.authRequired))
        #expect(try store.pendingOps(state: .queued).count == 1)  // untouched
    }

    @Test func orgDeletedDuringPushBlocksAndLeavesQueueIntact() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")
        let edits = LocalEdits(store: store, locationId: "loc-1")
        _ = try edits.createIngredient(name: "Butter", baseUnit: "lb", vendor: nil, category: nil)
        #expect(try store.pendingOps(state: .queued).count == 1)

        server.forceOrgDeleted = true  // push-only, matching the route's own reads-stay-open contract
        try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
        }

        #expect(await engine.state == .blocked(.orgDeleted))
        // §6.2: the export path needs these -- only a user-confirmed wipe
        // (Task 14) discards them, never an automatic 410.
        #expect(try store.pendingOps(state: .queued).count == 1)
    }

    // MARK: - genuine transport failure

    @Test func transportFailureBlocksAsOffline() async throws {
        let store = try makeStore()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        // Loopback port 1: nothing listens there in any test environment,
        // so this fails fast with a genuine URLError -- no StubTransport
        // involvement, so no risk of racing another suite's active stub.
        let api = ApiClient(baseURL: URL(string: "http://127.0.0.1:1")!, session: session) { "tok" }
        let engine = SyncEngine(store: store, api: api, orgId: "org-1")

        await engine.syncNow()

        guard case .blocked(.offline) = await engine.state else {
            Issue.record("expected blocked(.offline), got \(await engine.state)")
            return
        }
    }

    // MARK: - two-store convergence (§14 item-count scenario, client-side)

    /// Task 5(g) extends this beyond ingredients/purchases into the recipe
    /// surface Phase 2b adds: A creates a recipe with two lines (one op
    /// batch, TABLE_ORDER-safe in a single push alongside an unrelated
    /// ingredient+purchase), B pulls it, then the two devices each mutate a
    /// DIFFERENT line offline (B edits one line's quantity, A tombstones
    /// the other) before both push and pull to convergence -- proving the
    /// non-conflicting fan-out and the plain LWW update path agree on a
    /// final, field-identical state on both sides.
    @Test func twoStoreConvergenceFieldIdenticalRowsAndCounts() async throws {
        let server = FakeSyncServer()
        let storeA = try makeStore()
        let storeB = try LocalStore.inMemory()
        try storeB.bind(userId: "user-2", orgId: "org-1", locationId: "loc-1")
        let engineA = SyncEngine(store: storeA, api: makeApi(token: "tok-a"), orgId: "org-1")
        let engineB = SyncEngine(store: storeB, api: makeApi(token: "tok-b"), orgId: "org-1")
        let editsA = LocalEdits(store: storeA, locationId: "loc-1")
        let editsB = LocalEdits(store: storeB, locationId: "loc-1")
        var recipeId = ""

        try await StubTransport.withStub(server.responder()) {
            // B starts caught up.
            await engineB.syncNow()
            #expect(await engineB.state == .caughtUp)

            // A works entirely offline: an ingredient, then a purchase
            // against it, both still queued locally.
            let ingredientId = try editsA.createIngredient(
                name: "Ground Beef", baseUnit: "lb", vendor: nil, category: nil)
            _ = try editsA.createPurchase(
                ingredientId: ingredientId, purchasedOn: "2026-07-29", qty: "10",
                unit: "lb", qtyInCase: nil, totalPrice: "45.00")
            #expect(try storeA.pendingOps(state: .queued).count == 2)

            // A comes back online.
            await engineA.syncNow()
            #expect(await engineA.state == .caughtUp)
            #expect(try storeA.pendingOps(state: nil).isEmpty)

            // B then pulls.
            await engineB.syncNow()
            #expect(await engineB.state == .caughtUp)

            // A, still offline, adds a second ingredient and composes a
            // two-line recipe over it plus the already-synced Ground Beef
            // -- 1 ingredient insert + saveNewRecipe's 3 ops, all still
            // local.
            let saltId = try editsA.createIngredient(
                name: "Salt", baseUnit: "oz", vendor: nil, category: nil)
            recipeId = try editsA.saveNewRecipe(RecipeDraft(
                name: "Meatloaf", menuPrice: "18.00", targetFcPct: "30.00",
                lines: [
                    RecipeDraft.Line(ingredientId: ingredientId, qty: "1.0000"),
                    RecipeDraft.Line(ingredientId: saltId, qty: "0.1000"),
                ]))
            #expect(try storeA.pendingOps(state: .queued).count == 4)

            await engineA.syncNow()
            #expect(await engineA.state == .caughtUp)
            #expect(try storeA.pendingOps(state: nil).isEmpty)

            await engineB.syncNow()
            #expect(await engineB.state == .caughtUp)

            // Now each device mutates a DIFFERENT line of the SAME recipe,
            // still offline -- no conflict, just the fan-out and the plain
            // LWW update path racing to converge together.
            let groundBeefLineB = try #require(
                try storeB.liveRecipeItems(recipeId: recipeId).first { $0.ingredient_id == ingredientId })
            try editsB.updateRecipeLineQty(itemId: groundBeefLineB.id, qty: "1.2500")
            #expect(try storeB.pendingOps(state: .queued).count == 1)

            let saltLineA = try #require(
                try storeA.liveRecipeItems(recipeId: recipeId).first { $0.ingredient_id == saltId })
            try editsA.tombstoneRecipeLine(itemId: saltLineA.id)
            #expect(try storeA.pendingOps(state: .queued).count == 1)

            await engineA.syncNow()  // pushes the tombstone
            #expect(await engineA.state == .caughtUp)
            await engineB.syncNow()  // pushes the qty edit, pulls A's tombstone too
            #expect(await engineB.state == .caughtUp)
            await engineA.syncNow()  // trailing pull to see B's qty edit
            #expect(await engineA.state == .caughtUp)
        }

        let ingredientsA = try storeA.liveIngredients()
        let ingredientsB = try storeB.liveIngredients()
        #expect(ingredientsA.count == 2)  // Ground Beef + Salt
        #expect(ingredientsA == ingredientsB)

        let purchasesA = try storeA.allLivePurchases()
        let purchasesB = try storeB.allLivePurchases()
        #expect(purchasesA.count == 1)
        #expect(purchasesA == purchasesB)

        let recipesA = try storeA.liveRecipes()
        let recipesB = try storeB.liveRecipes()
        #expect(recipesA.count == 1)
        #expect(recipesA == recipesB)

        let itemsA = try storeA.liveRecipeItems(recipeId: recipeId)
        let itemsB = try storeB.liveRecipeItems(recipeId: recipeId)
        #expect(itemsA.count == 1)  // the salt line is tombstoned on both sides
        #expect(itemsA == itemsB)
        #expect(itemsA.first?.qty_base_units == "1.2500")  // B's edit stands
    }

    // MARK: - push ordering (rules 2/7: no reordering, no merging)

    @Test func pushSendsQueuedOpsInCreatedAtOpIdOrder() async throws {
        let server = FakeSyncServer()
        let store = try makeStore()
        let engine = SyncEngine(store: store, api: makeApi(), orgId: "org-1")

        // Enqueued in the OPPOSITE order of their created_at (op-a inserted
        // first but is chronologically LATER) -- pendingOps(state:) is
        // documented (created_at, op_id) order regardless of insertion
        // order, and the engine must preserve that, not fall back to
        // insertion/rowid order, when it builds the wire batch.
        try store.enqueue(PendingOp(
            op_id: "op-a", table: "ingredients", row_id: "ing-a", location_id: "loc-1",
            client_mutated_at: t2, kind: .insert, fields: ["name": "B", "base_unit": "lb"],
            state: .queued, reason: nil, created_at: t2))
        try store.enqueue(PendingOp(
            op_id: "op-b", table: "ingredients", row_id: "ing-b", location_id: "loc-1",
            client_mutated_at: t1, kind: .insert, fields: ["name": "A", "base_unit": "lb"],
            state: .queued, reason: nil, created_at: t1))

        // Read INSIDE the withStub closure -- see the multi-page test's
        // comment for why reading StubTransport.recordedRequests after the
        // block returns would race another concurrently-scheduled suite.
        let opIds: [String?] = try await StubTransport.withStub(server.responder()) {
            await engine.syncNow()
            let postBodies = StubTransport.recordedRequests.filter { $0.request.httpMethod == "POST" }
            guard let body = postBodies.first?.body,
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let ops = object["ops"] as? [[String: Any]]
            else {
                return []
            }
            return ops.map { $0["op_id"] as? String }
        }
        #expect(opIds == ["op-b", "op-a"])
    }
}
