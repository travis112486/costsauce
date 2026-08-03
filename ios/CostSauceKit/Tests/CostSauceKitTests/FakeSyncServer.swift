// In-process contract double for the sync HTTP surface (Task 8), mounted on
// StubTransport exactly like ApiClientTests' fixtures. Reproduces enough of
// api/routes/sync.py + api/services/sync.py to drive SyncEngineTests:
//
// - canonical rows per table, kept as raw wire dicts (String/NSNull/Int --
//   the same vocabulary `PullChange.row`'s `SyncValue` speaks, just untyped
//   here since this class only ever talks JSON, never touches CostSauceKit's
//   own types directly);
// - a SINGLE global `server_seq` counter shared across all four tables,
//   mirroring the real UNION ALL's single `ORDER BY 2` (api/services/
//   sync.py:196-197) -- a client walking pages in order sees one monotonic
//   timeline across tables, not four independent ones;
// - configurable pull page size (`pageSize`, default matches SYNC_PAGE_CAP's
//   spirit but small enough for tests to force multi-page walks);
// - push apply with the server's exact result vocabulary: `applied`,
//   `stale`/`older`|`deleted`, `needs_attention` with a reason string, and
//   `replayed: true` layered onto whatever the ORIGINAL result was (never a
//   distinct status of its own -- api/routes/sync.py:83-85's
//   `{**row[0], "replayed": True}`);
// - the `recipe_items` ON CONFLICT upsert-arbitration path (api/services/
//   sync.py:247-271): an INSERT whose (recipe_id, ingredient_id) pair
//   already has a live canonical row folds onto it, winning or losing by
//   `client_mutated_at` -- losing returns `stale`/`older` WITH a `row_id`
//   pointing at the canonical row, the one case where `stale` carries a
//   `row_id` at all;
// - whole-batch 401/410 toggles (`forceUnauthorized`/`forceOrgDeleted`),
//   applied uniformly to every request while set;
// - `failPullOnCall`: a one-shot "the Nth GET /sync call fails" toggle used
//   to simulate an app-killed-mid-pull-loop without needing StubTransport's
//   `Responder` (which always returns a real HTTP response) to model a raw
//   transport error;
// - `dropNextPushResponse`: a one-shot "the push succeeded server-side but
//   the client never saw the response" toggle, used to build the replay
//   scenario -- the op stays queued locally (nothing to process), so the
//   next `syncNow()` resends the SAME op_id and hits the ledger;
// - `onPullCall`: a hook fired on every GET /sync call, used to inject a
//   local store mutation at a precise point mid-`syncNow()`;
// - `bogusStatusOpId`: forces one op_id's result to a synthetic,
//   out-of-vocabulary status string, to exercise the client's fail-safe
//   default.
//
// All mutable state lives behind one `NSLock` (the same "class is
// `@unchecked Sendable`, a lock guards everything" shape `ApiClient` itself
// uses for `onUnauthorized`) since `StubTransport`'s `Responder` closure can
// be invoked from whatever thread `URLSession` schedules the stub protocol
// on.

import Foundation
@testable import CostSauceKit

final class FakeSyncServer: @unchecked Sendable {
    private let lock = NSLock()

    private var tables: [String: [String: [String: Any]]] = [
        "ingredients": [:], "recipes": [:], "recipe_items": [:], "purchases": [:],
        "invoices": [:], "invoice_pages": [:],
    ]
    private var nextSeq: Int64 = 0
    private var ledger: [String: [String: Any]] = [:]  // op_id -> ledgered result
    private var pullCallCount = 0

    var pageSize = 500
    /// Applies to EVERY request (GET and POST alike) -- matches
    /// `require_caller`'s uniform auth gate on both routes.
    var forceUnauthorized = false
    /// PUSH-ONLY, matching api/routes/sync.py's docstring: "Reads stay
    /// available during the deletion grace window -- the export path
    /// depends on them; only writes are frozen (§6.2)." GET /sync's handler
    /// never checks `deletion_scheduled_at` at all.
    var forceOrgDeleted = false
    /// One-shot: the Nth GET /sync call (1-based) returns 503 instead of a
    /// normal page, then auto-clears.
    var failPullOnCall: Int?
    /// One-shot: the next POST /sync call applies+ledgers normally
    /// server-side but responds 503 instead of the real 200 body, then
    /// auto-clears.
    var dropNextPushResponse = false
    /// Overrides the push response's `cursor` field with an arbitrary value
    /// (simulating other devices' unrelated writes having already advanced
    /// the org's global counter) -- used to prove the engine never adopts
    /// it (sync.py warning (a)).
    var pushResponseCursorOverride: Int64?
    /// Fires synchronously on every GET /sync call, passed the 1-based call
    /// count -- lets a test inject a LOCAL store mutation (e.g. enqueue a
    /// new op via a captured `LocalEdits`/`LocalStore`) at a precise point
    /// mid-`syncNow()`, simulating a local edit landing while a sync is
    /// still in flight. `LocalStore` is plain and thread-safe (its own
    /// GRDB `DatabaseQueue` serializes writes internally), so calling into
    /// it from this hook -- which runs on whatever thread URLSession
    /// dispatches the stub protocol on, under THIS class's own `lock` -- is
    /// safe; there is no shared lock between the two.
    var onPullCall: ((Int) -> Void)?
    /// When set, the op with this `op_id` gets a synthetic, deliberately
    /// UNRECOGNIZED status back instead of going through the normal
    /// apply/ledger flow -- proves the client never silently deletes an op
    /// whose result shape it doesn't understand (§13).
    var bogusStatusOpId: String?

    // purchases LAST, mirroring api/services/sync.py's Phase 3a reorder:
    // it gained an invoice_pages FK, so the page must apply first.
    private static let tableOrder = ["ingredients", "recipes", "recipe_items",
                                     "invoices", "invoice_pages", "purchases"]

    private static let insertFields: [String: Set<String>] = [
        "ingredients": ["name", "base_unit", "vendor", "category", "source", "deleted_at"],
        "recipes": ["name", "menu_price", "target_fc_pct", "deleted_at"],
        "recipe_items": ["recipe_id", "ingredient_id", "qty_base_units", "deleted_at"],
        "invoices": ["captured_at", "parse_status", "deleted_at"],
        "invoice_pages": [
            "invoice_id", "page_no", "storage_path", "width", "height", "sha256",
            "deleted_at",
        ],
        "purchases": [
            "ingredient_id", "purchased_on", "recorded_at", "qty", "unit",
            "qty_in_case", "qty_base_units", "total_price", "source",
            "invoice_page_id", "deleted_at",
        ],
    ]
    private static let updateFields: [String: Set<String>] = [
        "ingredients": ["name", "base_unit", "vendor", "category", "deleted_at"],
        "recipes": ["name", "menu_price", "target_fc_pct", "deleted_at"],
        "recipe_items": ["qty_base_units", "deleted_at"],
        "invoices": ["parse_status", "deleted_at"],
        "invoice_pages": ["storage_path", "width", "height", "sha256", "deleted_at"],
        "purchases": [
            "purchased_on", "recorded_at", "qty", "unit", "qty_in_case",
            "qty_base_units", "total_price", "invoice_page_id", "deleted_at",
        ],
    ]
    // purchases.unit_price is server-generated and never client-settable
    // (LocalPurchase's own doc comment) -- always emitted as null here.
    private static let extraPullOnlyFields: [String: [String]] = ["purchases": ["unit_price"]]

    /// Parent tables each syncable table's INSERT must check for liveness
    /// at the op's `location_id` before writing -- mirrors
    /// `_PARENT_CHECKS` (api/services/sync.py:44-50).
    private static let parentChecks: [String: [(field: String, table: String, label: String)]] = [
        "purchases": [("ingredient_id", "ingredients", "ingredient")],
        "recipe_items": [
            ("recipe_id", "recipes", "recipe"),
            ("ingredient_id", "ingredients", "ingredient"),
        ],
        "invoice_pages": [("invoice_id", "invoices", "invoice")],
    ]

    init() {}

    // MARK: - seeding (test setup helper -- bypasses push entirely)

    /// Directly installs a canonical row, as if some earlier write (by any
    /// actor) had already applied it -- allocates a fresh `server_seq`.
    @discardableResult
    func seed(
        table: String, id: String, locationId: String = "loc-1",
        clientMutatedAt: String, fields: [String: Any]
    ) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        nextSeq += 1
        var row = Self.fillMissingWithNull(table: table, fields: fields)
        row["id"] = id
        row["location_id"] = locationId
        row["client_mutated_at"] = clientMutatedAt
        row["created_at"] = row["created_at"] as? String ?? clientMutatedAt
        row["updated_at"] = clientMutatedAt
        row["server_seq"] = nextSeq
        tables[table, default: [:]][id] = row
        return nextSeq
    }

    /// Live (non-tombstoned) row count for a table -- lets a test assert
    /// server-side state directly (e.g. "exactly one row" after a replay).
    func rowCount(table: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (tables[table] ?? [:]).values.filter {
            !(($0["deleted_at"] as? String).map { !$0.isEmpty } ?? false)
        }.count
    }

    // MARK: - StubTransport.Responder

    func responder() -> StubTransport.Responder {
        { [weak self] request, body in
            guard let self else {
                return StubTransport.json(500, ["detail": "FakeSyncServer deallocated"])
            }
            return self.handle(request: request, body: body)
        }
    }

    private func handle(
        request: URLRequest, body: Data?
    ) -> (status: Int, headers: [String: String], body: Data) {
        lock.lock()
        defer { lock.unlock() }

        if forceUnauthorized {
            return StubTransport.json(401, ["detail": "invalid token"])
        }

        switch request.httpMethod {
        case "GET":
            return handlePull(url: request.url)
        case "POST":
            if forceOrgDeleted {
                return StubTransport.json(410, ["detail": "This organization is scheduled for deletion."])
            }
            return handlePush(body: body ?? Data())
        default:
            return StubTransport.json(404, ["detail": "not found"])
        }
    }

    // MARK: - GET /sync

    private func handlePull(url: URL?) -> (status: Int, headers: [String: String], body: Data) {
        pullCallCount += 1
        onPullCall?(pullCallCount)
        if failPullOnCall == pullCallCount {
            failPullOnCall = nil
            return StubTransport.json(503, ["detail": "simulated pull failure"])
        }

        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: true) }
        let since = components?.queryItems?.first(where: { $0.name == "since" })?.value
            .flatMap(Int64.init) ?? 0

        var all: [(seq: Int64, table: String, row: [String: Any])] = []
        for table in Self.tableOrder {
            for (_, row) in tables[table] ?? [:] {
                guard let seq = row["server_seq"] as? Int64, seq > since else { continue }
                all.append((seq, table, row))
            }
        }
        all.sort { $0.seq < $1.seq }

        let page = Array(all.prefix(pageSize))
        let hasMore = all.count > pageSize
        let cursor = page.last?.seq ?? since
        let changes: [[String: Any]] = page.map { ["table": $0.table, "row": $0.row] }

        return StubTransport.json(200, ["changes": changes, "cursor": cursor, "has_more": hasMore])
    }

    // MARK: - POST /sync

    private func handlePush(body: Data) -> (status: Int, headers: [String: String], body: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let opsWire = object["ops"] as? [[String: Any]]
        else {
            return StubTransport.json(400, ["detail": "malformed push body"])
        }

        // TABLE_ORDER-ranked internal apply order (FK safety), results
        // mapped back to the caller's original order (api/routes/sync.py:
        // 75-77, 100).
        let rank = Dictionary(uniqueKeysWithValues: Self.tableOrder.enumerated().map { ($1, $0) })
        let indexed = opsWire.enumerated().sorted { a, b in
            let ra = rank[a.element["table"] as? String ?? ""] ?? Int.max
            let rb = rank[b.element["table"] as? String ?? ""] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }

        var results = [Int: [String: Any]](minimumCapacity: opsWire.count)
        for (index, wireOp) in indexed {
            guard let opId = wireOp["op_id"] as? String else {
                results[index] = ["status": "needs_attention", "reason": "malformed op"]
                continue
            }
            if opId == bogusStatusOpId {
                // Deliberately not ledgered -- this is a synthetic,
                // out-of-vocabulary response, not a real applied/stale
                // outcome the idempotency ledger should ever remember.
                results[index] = ["status": "totally_unrecognized_status"]
                continue
            }
            if let ledgered = ledger[opId] {
                var replayed = ledgered
                replayed["replayed"] = true
                results[index] = replayed
                continue
            }
            let result = applyOp(wireOp)
            if (result["status"] as? String) != "needs_attention" {
                ledger[opId] = result
            }
            results[index] = result
        }

        let ordered = (0..<opsWire.count).map {
            results[$0] ?? ["status": "needs_attention", "reason": "internal error: no result"]
        }

        if dropNextPushResponse {
            dropNextPushResponse = false
            return StubTransport.json(503, ["detail": "simulated dropped response"])
        }
        return StubTransport.json(200, ["results": ordered, "cursor": pushResponseCursorOverride ?? nextSeq])
    }

    private func applyOp(_ wireOp: [String: Any]) -> [String: Any] {
        guard
            let table = wireOp["table"] as? String,
            let rowId = wireOp["row_id"] as? String,
            let locationId = wireOp["location_id"] as? String,
            let clientMutatedAt = wireOp["client_mutated_at"] as? String,
            let fieldsRaw = wireOp["fields"] as? [String: Any]
        else {
            return ["status": "needs_attention", "reason": "malformed op"]
        }
        let fields: [String: Any?] = fieldsRaw.mapValues { $0 is NSNull ? nil : $0 }

        if let existing = tables[table]?[rowId] {
            return applyUpdate(
                table: table, rowId: rowId, existing: existing,
                clientMutatedAt: clientMutatedAt, fields: fields)
        }
        return applyInsert(
            table: table, rowId: rowId, locationId: locationId,
            clientMutatedAt: clientMutatedAt, fields: fields)
    }

    private func applyUpdate(
        table: String, rowId: String, existing: [String: Any],
        clientMutatedAt: String, fields: [String: Any?]
    ) -> [String: Any] {
        guard let rowCM = existing["client_mutated_at"] as? String else {
            return ["status": "needs_attention", "reason": "corrupt fixture row"]
        }
        if let deletedAt = existing["deleted_at"] as? String, !(deletedAt as String).isEmpty {
            return ["status": "stale", "reason": "deleted"]
        }
        if clientMutatedAt < rowCM {
            return ["status": "stale", "reason": "older"]
        }
        let allowed = Self.updateFields[table] ?? []
        if let bad = Set(fields.keys).subtracting(allowed).sorted().first {
            return ["status": "needs_attention", "reason": "unknown or immutable field: \(bad)"]
        }

        var updated = existing
        for (key, value) in fields {
            updated[key] = value ?? NSNull()
        }
        updated["client_mutated_at"] = clientMutatedAt
        updated["updated_at"] = clientMutatedAt
        nextSeq += 1
        updated["server_seq"] = nextSeq
        tables[table]?[rowId] = updated
        return ["status": "applied", "row_id": rowId]
    }

    private func applyInsert(
        table: String, rowId: String, locationId: String,
        clientMutatedAt: String, fields: [String: Any?]
    ) -> [String: Any] {
        let allowed = Self.insertFields[table] ?? []
        if let bad = Set(fields.keys).subtracting(allowed).sorted().first {
            return ["status": "needs_attention", "reason": "unknown field: \(bad)"]
        }

        // Parent liveness (mirrors api/services/sync.py:44-50's
        // `_PARENT_CHECKS`, run before the recipe_items arbitration block
        // below): a field naming a parent row must point at one that
        // exists at THIS location and isn't tombstoned. A field simply
        // absent from `fields` (nil here) is skipped, same as the real
        // server's `if parent_id is None: continue`.
        for check in Self.parentChecks[table] ?? [] {
            guard let parentId = fields[check.field] as? String else { continue }
            let parentRow = tables[check.table]?[parentId]
            let isLive = parentRow.map { row in
                (row["location_id"] as? String) == locationId
                    && !((row["deleted_at"] as? String).map { !$0.isEmpty } ?? false)
            } ?? false
            if !isLive {
                return ["status": "needs_attention", "reason": "referenced \(check.label) is not live"]
            }
        }

        if table == "recipe_items" {
            let recipeId = fields["recipe_id"] as? String
            let ingredientId = fields["ingredient_id"] as? String
            if let recipeId, let ingredientId,
                let (existingId, existingRow) = tables["recipe_items"]?.first(where: {
                    ($0.value["recipe_id"] as? String) == recipeId
                        && ($0.value["ingredient_id"] as? String) == ingredientId
                        && !(($0.value["deleted_at"] as? String).map { !$0.isEmpty } ?? false)
                })
            {
                guard let existingCM = existingRow["client_mutated_at"] as? String else {
                    return ["status": "needs_attention", "reason": "corrupt fixture row"]
                }
                if clientMutatedAt < existingCM {
                    // Our INSERT loses the ON CONFLICT arbitration -- the
                    // one case a `stale` result carries a `row_id`. Strictly
                    // `<` (not `<=`): the real server's upsert is `WHERE
                    // recipe_items.client_mutated_at <= EXCLUDED
                    // .client_mutated_at` (api/services/sync.py:257), so it
                    // rejects ONLY a strictly older write -- an EQUAL
                    // timestamp wins and folds onto the canonical row below,
                    // same as this file's own plain-update path (:311).
                    return ["status": "stale", "reason": "older", "row_id": existingId]
                }
                var updated = existingRow
                for (key, value) in fields { updated[key] = value ?? NSNull() }
                updated["client_mutated_at"] = clientMutatedAt
                updated["updated_at"] = clientMutatedAt
                nextSeq += 1
                updated["server_seq"] = nextSeq
                tables["recipe_items"]?[existingId] = updated
                return ["status": "applied", "row_id": existingId]
            }
        }

        var row: [String: Any] = [:]
        for (key, value) in fields { row[key] = value ?? NSNull() }
        row = Self.fillMissingWithNull(table: table, fields: row)
        row["id"] = rowId
        row["location_id"] = locationId
        row["client_mutated_at"] = clientMutatedAt
        row["created_at"] = clientMutatedAt
        row["updated_at"] = clientMutatedAt
        nextSeq += 1
        row["server_seq"] = nextSeq
        tables[table, default: [:]][rowId] = row
        return ["status": "applied", "row_id": rowId]
    }

    /// Every optional wire key `PullChange.row` expects (Records.swift's
    /// `fromPull` extensions) that wasn't part of this write gets an
    /// explicit SQL-NULL placeholder, so a pulled row always decodes.
    private static func fillMissingWithNull(table: String, fields: [String: Any]) -> [String: Any] {
        var row = fields
        for key in insertFields[table] ?? [] where row[key] == nil {
            row[key] = NSNull()
        }
        for key in extraPullOnlyFields[table] ?? [] {
            row[key] = NSNull()
        }
        return row
    }
}
