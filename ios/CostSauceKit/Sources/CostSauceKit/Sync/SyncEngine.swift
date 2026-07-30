// The CostSauce sync engine — the core of the iOS offline loop (Phase 2a,
// Task 8). One entry point, `syncNow()`, drives the device's half of the
// contract `api/routes/sync.py` / `api/services/sync.py` define server-side:
// pull everything new, push everything queued, then pull once more so the
// device's own writes (and anything else that landed while it pushed) come
// back with real server truth (`server_seq`, canonical ids, LWW arbitration
// outcomes) — repeating the push+pull pass until nothing is left queued, so
// `.caughtUp` never lies about outstanding local work. Concurrent callers
// coalesce onto one real sync rather than interleaving (see `syncNow`'s doc
// comment).
//
// Three warnings from api/routes/sync.py's module docstring bind this file
// directly:
//   (a) POST /sync's response `cursor` is the org's GLOBAL sync_counter, not
//       what THIS device has actually pulled -- adopting it blind would skip
//       other-device rows forever. Only a GET /sync page's own `cursor` is
//       ever written to `meta` (`pullLoop`, never `pushQueuedOps`).
//   (b)/(c) are `LocalEdits`'/the kernel's concern, not this file's.
//
// `LocalStore` (Task 5) is the source of truth for identity/cursor/queue
// state; this actor holds NO durable state of its own beyond the in-memory
// `state` it publishes -- a freshly constructed `SyncEngine` over the same
// store resumes exactly where a killed one left off, purely by reading
// `store.meta()`/`store.pendingOps(state:)` again.

import Foundation

public enum SyncState: Equatable, Sendable {
    case idle
    case catchingUp
    case caughtUp
    case blocked(SyncBlock)
}

public enum SyncBlock: Equatable, Sendable {
    case authRequired
    case orgDeleted
    case offline(String)
}

public actor SyncEngine {
    private let store: LocalStore
    private let api: ApiClient
    private let orgId: String

    /// Ops are chunked to at most this many per push request/batch_id
    /// (spec §5.3 / api/services/sync.py's `MAX_BATCH_OPS`).
    private static let maxOpsPerBatch = 200

    public private(set) var state: SyncState = .idle

    /// The single real sync currently running, if any -- see `syncNow`'s
    /// doc comment for why this exists at all (actors are NOT serialized
    /// across suspension points; without this, two concurrent `syncNow()`
    /// calls interleave).
    private var inFlightSync: Task<Void, Never>?

    /// Thread-safe multi-subscriber fan-out for `stateStream`, held
    /// OUTSIDE actor isolation (a `Sendable` helper object, not
    /// actor-isolated state) so registration can happen SYNCHRONOUSLY, with
    /// no `await`/actor-hop between a caller reading `engine.stateStream`
    /// and its continuation being live. That matters: if registration were
    /// deferred behind an actor hop, a caller doing
    /// `let s = engine.stateStream; await engine.syncNow()` could race the
    /// hop against `syncNow`'s very first `setState` and silently miss it.
    private nonisolated let subscribers = SyncStateSubscribers()

    public init(store: LocalStore, api: ApiClient, orgId: String) {
        self.store = store
        self.api = api
        self.orgId = orgId
    }

    /// A fresh `AsyncStream` per access, one continuation per subscriber
    /// (multi-subscriber safe by construction: each call to this property
    /// registers its own independent continuation, no shared/consumed-once
    /// stream). Emits only FUTURE transitions -- a late subscriber does not
    /// get the current `state` replayed; call `state` directly for that.
    public nonisolated var stateStream: AsyncStream<SyncState> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = subscribers.add(continuation)
            continuation.onTermination = { [subscribers] _ in
                subscribers.remove(id)
            }
        }
    }

    private func setState(_ newState: SyncState) {
        state = newState
        subscribers.yield(newState)
    }

    // MARK: - the one entry point

    /// Rule 1: pull loop → {push → pull loop} until no push work remains.
    ///
    /// **Coalesced, not merely "actor-serialized".** Actors only exclude
    /// concurrent execution BETWEEN suspension points -- every `await` in
    /// the body below is a point where a second, concurrently-arriving
    /// `syncNow()` call can start running interleaved with the first
    /// (reentrancy is the actor default, not something `actor` alone rules
    /// out). Two independently-running copies of the loop below would
    /// thrash `state`, could each read/push the SAME still-queued ops
    /// (double-pushing a batch), and could race `markNeedsAttention`/
    /// `deleteOp` against each other for the same op. `inFlightSync` fixes
    /// this: the FIRST call creates and stores the real work as a child
    /// `Task` before its first `await`, so a second call arriving while the
    /// first is suspended sees `inFlightSync` already set and simply awaits
    /// the SAME task instead of starting its own -- both calls return once
    /// the one real sync finishes, and `inFlightSync` is cleared as that
    /// task's last action (from inside actor isolation), so a LATER,
    /// non-overlapping `syncNow()` call still starts a fresh sync rather
    /// than replaying a stale result.
    ///
    /// `SyncState` has no dedicated "pushing" case, so `.catchingUp` covers
    /// the whole in-flight duration -- it flips to `.caughtUp` only once
    /// every phase has finished AND no push work remains (see
    /// `performSync`'s loop). Never throws: every failure path ends in
    /// `.blocked(_)` instead, since this is the app layer's poll point, not
    /// a throwing call it awaits inside a do/catch.
    public func syncNow() async {
        if let inFlightSync {
            await inFlightSync.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAndClearInFlight()
        }
        inFlightSync = task
        await task.value
    }

    /// The actual sync body, plus clearing `inFlightSync` as its very last
    /// action -- both inside one actor-isolated hop, so by the time
    /// `task.value` resolves for ANY awaiter (the leader or a coalesced
    /// follower), `inFlightSync` is unconditionally `nil` already. Without
    /// that ordering, a brand-new `syncNow()` call arriving in the tiny gap
    /// between "the real work finished" and "the field got cleared" could
    /// wrongly coalesce onto an already-finished task and return instantly
    /// without ever pushing its own new work.
    private func runAndClearInFlight() async {
        await performSync()
        inFlightSync = nil
    }

    private func performSync() async {
        setState(.catchingUp)
        do {
            try await pullLoop()
            // Rule 2's "no push work remains" half of caughtUp: loop
            // push+trailing-pull until a pass finds nothing left queued.
            // Without this, an op enqueued (from the app layer, entirely
            // outside this actor -- `LocalStore.enqueue` is plain,
            // thread-safe, callable any time) between this sync's push and
            // its trailing pull would leave real, unpushed work behind a
            // state that already claims `.caughtUp` -- exactly the signal
            // Task 9's suppression logic reads to decide whether to nag the
            // user about a still-pending edit.
            //
            // This loop is UNBOUNDED by design, not an oversight: it is the
            // only way to make "caughtUp implies nothing is queued" an
            // actual guarantee rather than a best-effort. Termination still
            // holds in the ordinary case -- `pushQueuedOps` always resolves
            // every op it sends to either `.needsAttention` or deleted
            // (never leaves it `.queued`), so a given op can delay at most
            // one more pass -- and only fails to terminate if the app layer
            // keeps enqueueing new edits faster than one push+pull round
            // trip completes, which is not a realistic edit rate.
            while true {
                let sawStale = try await pushQueuedOps()
                if sawStale {
                    // §14 convergence / silent-LWW correctness (controller
                    // ruling: "truth arrives on the trailing pull" governs,
                    // make it true). A `stale` rejection means the LOCAL
                    // row may currently be showing a value that exists
                    // NOWHERE on the server: `LocalStore.applyPullPage`'s
                    // rebase step (frozen, Task 5) unconditionally
                    // re-applies a still-queued op's fields onto ANY row a
                    // pull page touches, with no regard for the op's
                    // eventual staleness -- so if that row was ever
                    // re-fetched by an earlier pull in THIS call (the only
                    // way push could even discover the conflict, since the
                    // winning edit must already be server-side), the
                    // rejected edit got overlaid on top of the true value.
                    // The op is gone from pending_ops now (deleteOp already
                    // ran), but a plain incremental `since=<cursor>` pull
                    // would never re-fetch that exact row again -- its
                    // server_seq is already <= cursor. Resetting the
                    // baseline to 0 (a pure cursor write; `changes: []`
                    // touches no table row and no pending op -- see
                    // `LocalStore.applyPullPage`) forces the very next
                    // `pullLoop()` to walk every row from scratch. That DOES
                    // re-fetch the conflicting row, and with the op already
                    // deleted, nothing re-applies the rejected value on top
                    // this time -- the server's true value lands and
                    // stands.
                    //
                    // Re-armed on EVERY iteration that sees a stale result,
                    // not just the first: a row an earlier iteration's own
                    // reset pull re-fetched can get freshly rebase-overlaid
                    // by an op that was enqueued mid-reset (or simply hadn't
                    // been pushed yet) and turns out to ALSO be stale on a
                    // later iteration's push -- a one-shot flag would leave
                    // THAT row's wrong value stuck forever, since its
                    // server_seq is by then <= the already-advanced cursor
                    // too. A given op can only ever trigger one stale result
                    // (once pushed, it's gone from `.queued` either way), so
                    // this can't itself cause an extra iteration -- it just
                    // ensures whichever iteration discovers the conflict
                    // also gets to fix it. Full re-pull is only paid on
                    // these rare (cross-device-conflict) iterations, and the
                    // org dataset is small enough for that cost to be
                    // acceptable.
                    try store.applyPullPage([], cursor: 0)
                }
                try await pullLoop()
                if try store.pendingOps(state: .queued).isEmpty { break }
            }
            setState(.caughtUp)
        } catch let apiError as ApiError {
            switch apiError.status {
            case 401:
                // §13: the app layer separately flips SessionController via
                // ApiClient.onUnauthorized; this engine only reports state.
                setState(.blocked(.authRequired))
            case 410:
                // §6.2: no ops are touched here -- the export path (and a
                // user-confirmed wipe, Task 14) need the queue intact.
                setState(.blocked(.orgDeleted))
            default:
                // Not part of the frozen 401/410/URLError vocabulary --
                // treated as a transient reachability problem so `syncNow`
                // still always resolves to a well-defined blocked state
                // rather than silently swallowing an unmodeled status.
                setState(.blocked(.offline(apiError.message)))
            }
        } catch let urlError as URLError {
            setState(.blocked(.offline(urlError.localizedDescription)))
        } catch {
            setState(.blocked(.offline(error.localizedDescription)))
        }
    }

    // MARK: - pull

    /// Repeats `GET /sync?since=<meta.cursor>` until a page comes back with
    /// `hasMore == false`. Each page is applied via ONE atomic
    /// `store.applyPullPage` call (upserts + pending-op rebase + cursor
    /// advance) BEFORE the next page is requested -- so if the app dies
    /// between pages, the next `pullLoop` (a fresh `syncNow`, possibly on a
    /// brand-new `SyncEngine`) resumes from exactly the last committed
    /// page's cursor, never re-fetching or re-applying an earlier one.
    private func pullLoop() async throws {
        while true {
            let since = try store.meta()?.cursor ?? 0
            let page = try await api.syncPull(orgId: orgId, since: since)
            try store.applyPullPage(page.changes, cursor: page.cursor)
            if !page.hasMore { break }
        }
    }

    // MARK: - push

    /// Sends every `.queued` op in `(created_at, op_id)` order (the same
    /// order `LocalStore.pendingOps` documents and `applyPullPage`'s own
    /// rebase relies on), in chunks of at most `maxOpsPerBatch`, each chunk
    /// under a fresh UUIDv7 `batchId` -- `opId` itself is untouched across
    /// chunks/retries, which is what lets the server's idempotency ledger
    /// dedupe a resend. Never reorders or merges ops (rule 7): a chunk is a
    /// contiguous slice of the already-ordered queue, sent as-is.
    ///
    /// Returns whether ANY result in this call came back `stale` --
    /// `performSync` uses that to decide whether the next pull needs a full
    /// baseline reset (see its doc comment).
    private func pushQueuedOps() async throws -> Bool {
        let queued = try store.pendingOps(state: .queued)
        guard !queued.isEmpty else { return false }

        var sawStale = false
        for chunk in Self.chunked(queued, size: Self.maxOpsPerBatch) {
            let batchId = UUIDv7.generate()
            let wireOps = chunk.map { op in
                SyncOp(
                    opId: op.op_id, table: op.table, rowId: op.row_id,
                    locationId: op.location_id, clientMutatedAt: op.client_mutated_at,
                    fields: op.fields)
            }
            // Rule 3 / warning (a): `response.cursor` is the org's GLOBAL
            // counter, not this device's pull position -- deliberately never
            // read here. Only the trailing `pullLoop()` call advances
            // `meta.cursor`.
            let response = try await api.syncPush(orgId: orgId, batchId: batchId, ops: wireOps)
            for (op, result) in zip(chunk, response.results) {
                if result.status == "stale" { sawStale = true }
                try apply(result, to: op)
            }
        }
        return sawStale
    }

    /// Rule 2's per-result outcomes, positionally zipped by the caller. An
    /// explicit switch over the server's exact result vocabulary -- NOT an
    /// `if status != "needs_attention"` catch-all -- because §13's "never
    /// lose local work" contract means an unrecognized status must never
    /// fall through to `deleteOp` by accident; it has to be an active,
    /// enumerated choice for every case this client knows about, with a
    /// `default` that fails safe.
    ///
    /// `applied` and `stale`/`reason: "older"` (a plain LWW loss; `replayed:
    /// true` only ever DECORATES one of these with a flag, api/routes/
    /// sync.py:83-85, never a distinct status string of its own) end the
    /// same way: if the result carries a `rowId` that differs from what THIS
    /// op minted, `adoptCanonicalRow` first, then `deleteOp` either way. The
    /// rowId-mismatch check is what covers `recipe_items`' ON CONFLICT
    /// upsert-arbitration (api/services/sync.py:247-271): a LOSING insert
    /// there comes back as `stale`/`older` carrying the WINNING canonical
    /// row's id, and `LocalStore.adoptCanonicalRow`'s own contract is to
    /// drop the local minted row so the canonical copy is the only one
    /// left. A plain UPDATE-vs-UPDATE `stale`/`older` never carries a
    /// `rowId` at all, so for that case this reduces to exactly rule 2's
    /// literal "stale → deleteOp" (see `performSync`'s baseline-reset for
    /// how the row's CONTENT still converges to server truth).
    ///
    /// `stale`/`reason: "deleted"` is different in kind, not degree: it is
    /// the server refusing to re-mutate a row another device already
    /// tombstoned (spec §7's locked protocol -- tombstones are terminal
    /// regardless of clocks), not an ordinary conflict the trailing pull
    /// silently resolves. §13 requires a server-side refusal never cost the
    /// user work without telling them, so this parks -- exactly the way an
    /// unrecognized status already does below -- instead of deleting the
    /// op. Any OTHER `stale` reason (including none at all) parks the same
    /// fail-safe way, for the same reason an unrecognized status does:
    /// a shape this client doesn't specifically know how to resolve is
    /// grounds to surface it, not to guess it converges silently.
    ///
    /// `needs_attention` is the only OTHER status that leaves the op queued
    /// (as `.needsAttention`, with the server's reason) -- terminal, never
    /// retried automatically (Task 14's UI resolves it). An unrecognized
    /// status is treated the same way, with a reason naming the unknown
    /// status string, rather than silently discarded -- a shape this client
    /// doesn't understand yet is a reason to park and surface it, not to
    /// pretend it succeeded.
    ///
    /// Per the Task 5 hand-off note: `adoptCanonicalRow` does NOT touch
    /// `pending_ops` -- `deleteOp` below is still required after it.
    private func apply(_ result: OpResult, to op: PendingOp) throws {
        switch result.status {
        case "applied":
            if let rowId = result.rowId, rowId != op.row_id {
                try store.adoptCanonicalRow(table: op.table, mintedId: op.row_id, canonicalId: rowId)
            }
            try store.deleteOp(opId: op.op_id)
        case "stale":
            // Rule 2's "stale" outcome is NOT uniform: an ordinary
            // last-write-wins loss (`reason: "older"`) means the trailing
            // pull already fixes the row's content, so the op is simply
            // dropped -- silently, per §14 (see `staleOlderUpdateSilently
            // DropsOpWithoutNeedsAttention`). But `reason: "deleted"` means
            // the server refused to re-mutate a TOMBSTONED row (spec §7,
            // locked protocol: "Tombstones are terminal -- any op against a
            // tombstoned row is `stale` with `reason: "deleted"` regardless
            // of clocks"). That is not an ordinary conflict the trailing
            // pull silently resolves in the user's favor or the server's --
            // it is a server-side refusal, and §13 requires those never cost
            // the user work without telling them. So this parks exactly the
            // way an unrecognized status already does below, reusing that
            // same mechanism rather than inventing a second one. Any OTHER
            // reason (including an absent one) is treated the same
            // fail-safe way: park, don't silently discard -- a shape this
            // client doesn't specifically know how to resolve is a reason to
            // surface it, not to guess it's fine.
            if result.reason == "older" {
                if let rowId = result.rowId, rowId != op.row_id {
                    try store.adoptCanonicalRow(table: op.table, mintedId: op.row_id, canonicalId: rowId)
                }
                try store.deleteOp(opId: op.op_id)
            } else {
                try store.markNeedsAttention(
                    opId: op.op_id, reason: result.reason ?? "stale")
            }
        case "needs_attention":
            try store.markNeedsAttention(opId: op.op_id, reason: result.reason ?? "needs attention")
        default:
            try store.markNeedsAttention(
                opId: op.op_id, reason: "unrecognized result: \(result.status)")
        }
    }

    private static func chunked<T>(_ items: [T], size: Int) -> [[T]] {
        guard !items.isEmpty else { return [] }
        var result: [[T]] = []
        var index = items.startIndex
        while index < items.endIndex {
            let end = items.index(index, offsetBy: size, limitedBy: items.endIndex) ?? items.endIndex
            result.append(Array(items[index..<end]))
            index = end
        }
        return result
    }
}

/// See `SyncEngine.subscribers`'s doc comment for why this lives outside
/// actor isolation. `@unchecked Sendable`: every stored property is only
/// ever touched under `lock`, the same "class + one NSLock guarding
/// everything" shape `ApiClient` uses for `onUnauthorized`.
private final class SyncStateSubscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SyncState>.Continuation] = [:]

    func add(_ continuation: AsyncStream<SyncState>.Continuation) -> UUID {
        let id = UUID()
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    func yield(_ value: SyncState) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        for continuation in current {
            continuation.yield(value)
        }
    }
}
