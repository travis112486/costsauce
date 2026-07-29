// The CostSauce sync engine — the core of the iOS offline loop (Phase 2a,
// Task 8). One entry point, `syncNow()`, drives the device's half of the
// contract `api/routes/sync.py` / `api/services/sync.py` define server-side:
// pull everything new, push everything queued, then pull once more so the
// device's own writes (and anything else that landed while it pushed) come
// back with real server truth (`server_seq`, canonical ids, LWW arbitration
// outcomes).
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

    /// Rule 1: pull loop → push → pull loop, actor-serialized (concurrent
    /// callers queue behind the actor, never interleave). `SyncState` has no
    /// dedicated "pushing" case, so `.catchingUp` covers the whole in-flight
    /// duration -- it flips to `.caughtUp` only once every phase has
    /// finished cleanly. Never throws: every failure path ends in
    /// `.blocked(_)` instead, since this is the app layer's poll point, not
    /// a throwing call it awaits inside a do/catch.
    public func syncNow() async {
        setState(.catchingUp)
        do {
            try await pullLoop()
            try await pushQueuedOps()
            try await pullLoop()
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
    private func pushQueuedOps() async throws {
        let queued = try store.pendingOps(state: .queued)
        guard !queued.isEmpty else { return }

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
                try apply(result, to: op)
            }
        }
    }

    /// Rule 2's per-result outcomes, positionally zipped by the caller.
    ///
    /// `needs_attention` is the only status that leaves the op queued (as
    /// `.needsAttention`, with the server's reason) -- terminal, never
    /// retried automatically (Task 14's UI resolves it).
    ///
    /// Every other status (`applied`, or `stale` -- `replayed: true` only
    /// ever DECORATES one of those two with a flag, api/routes/sync.py:
    /// 83-85, never a distinct status string of its own) ends the same way:
    /// if the result carries a `rowId` that differs from what THIS op
    /// minted, `adoptCanonicalRow` first, then `deleteOp` either way.
    ///
    /// The rowId-mismatch check is what covers `recipe_items`' ON CONFLICT
    /// upsert-arbitration (api/services/sync.py:247-271): a LOSING insert
    /// there comes back as `stale`/`older` carrying the WINNING canonical
    /// row's id, and `LocalStore.adoptCanonicalRow`'s own contract is to
    /// drop the local minted row so the canonical copy (already known, or
    /// arriving on the next pull) is the only one left. A plain
    /// UPDATE-vs-UPDATE `stale`/`older` never carries a `rowId` at all, so
    /// for that case this reduces to exactly rule 2's literal "stale →
    /// deleteOp".
    ///
    /// Per the Task 5 hand-off note: `adoptCanonicalRow` does NOT touch
    /// `pending_ops` -- `deleteOp` below is still required after it.
    private func apply(_ result: OpResult, to op: PendingOp) throws {
        guard result.status != "needs_attention" else {
            try store.markNeedsAttention(opId: op.op_id, reason: result.reason ?? "needs attention")
            return
        }
        if let rowId = result.rowId, rowId != op.row_id {
            try store.adoptCanonicalRow(table: op.table, mintedId: op.row_id, canonicalId: rowId)
        }
        try store.deleteOp(opId: op.op_id)
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
