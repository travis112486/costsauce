# Invoice Page Re-download and Wired Eviction Sweep — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an evicted invoice page recoverable from storage, then turn on the eviction sweep that 3a shipped as dead policy.

**Architecture:** A signed-download endpoint mirrors the existing signed-upload one (same `_invoice_org`, same `storage_path`), so bytes keep travelling direct to storage while rows travel through sync. `ImageEviction` gains an injectable budget; a new app-target `ImageSweeper` measures files, calls the pure policy, and deletes. `InvoicePageView` downloads on demand into memory only.

**Tech Stack:** FastAPI + psycopg3 + httpx (backend); Swift 6.2, GRDB 7, Swift Testing (Kit); SwiftUI + XCTest/XCUITest (app).

**Spec:** `docs/superpowers/specs/2026-08-03-invoice-page-redownload-design.md` (commit `4e77f9b`). **Branch:** `invoice-page-redownload`.

## Global Constraints

- **Every synced column is TEXT locally.** `server_seq` is the sole INTEGER exception. `page_no`/`width`/`height` are TEXT in SQLite though integer server-side — cast when ordering or comparing numerically.
- **`storage_path` is `{org_id}/{invoice_id}/{page_no}.jpg`, no zero-padding**, derived independently on both sides and never accepted from the client.
- **Simulator seams are gated on `UITEST=1` only**; production always takes the real path. Established twice: `AppModel.pageSource` (camera) and `BackgroundUploader` (ephemeral session).
- **An un-uploaded page is never deleted**, at any age or size. Until storage acknowledges, the local file is the only copy in existence.
- **Eviction deletes files, never rows.** The `invoice_pages` row survives, which is what keeps the page re-downloadable and the purchase's `invoice_page_id` provenance intact.
- **"Add purchase from this page" is enabled in every view state**, including offline with no photo.
- Timestamps: write with `Kernel.canonicalTimestamp(_:)`, read with `Kernel.parsePostgresTimestamp(_:)` (accepts both the canonical `…T…Z` form and Postgres `timestamptz::text`).
- The `.xcodeproj` is **xcodegen-generated and gitignored**. New source files need `xcodegen generate`, never a pbxproj edit.
- Run the backend suite with `uv run pytest -q`; the Kit suite with `swift test` from `ios/CostSauceKit`.

---

### Task 1: Backend `download-url` endpoint

**Files:**
- Modify: `api/routes/invoices.py` (add `sign_get`, add the route)
- Test: `tests/test_invoices.py` (append to the route-test section, after line ~208)

**Interfaces:**
- Consumes: existing `storage_path(org_id, invoice_id, page_no)`, `_invoice_org(conn, invoice_id)`, `BUCKET`, `UPLOAD_URL_TTL_SECONDS`.
- Produces: `POST /invoices/{invoice_id}/pages/{page_no}/download-url` → `200 {"url": str, "expires_at": str}`; `409` when `sha256 IS NULL`; `404` when absent or another org's. Module-level `async def sign_get(path: str) -> tuple[str, str]`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_invoices.py`:

```python
async def _fake_sign_get(path):
    return f"https://storage.test/get/{path}", "2026-08-03T12:00:00+00:00"


async def _confirm(raw_conn, inv, loc, page_no=1):
    """A page WITH bytes: sha256 set is what makes it downloadable."""
    page = await _mint_page(raw_conn, inv, loc, page_no)
    await raw_conn.execute(
        "UPDATE invoice_pages SET sha256 = %s, width = 1694, height = 2200"
        " WHERE id = %s", ("a" * 64, page))
    await raw_conn.commit()
    return page


async def test_download_url_signs_the_same_key_the_upload_wrote(
        app_client, seeded_biz, raw_conn, monkeypatch):
    """Download must resolve against the key upload derived, or it 404s in
    the bucket while both endpoints look correct in isolation."""
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_get", lambda path: _fake_sign_get(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])
    await _confirm(raw_conn, inv, s["acme_loc"], 2)

    r = await app_client.post(
        f"/invoices/{inv}/pages/2/download-url", headers=auth(s["alice"]))

    assert r.status_code == 200, r.text
    assert r.json()["url"].endswith(f"{s['acme']}/{inv}/2.jpg")
    assert r.json()["expires_at"]


async def test_download_url_409s_for_a_page_whose_bytes_never_confirmed(
        app_client, seeded_biz, raw_conn, monkeypatch):
    """Not 404: the row exists and is legitimately ours. 409 says the page
    is not in a state that has bytes, which is the truth and is actionable."""
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_get", lambda path: _fake_sign_get(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])
    await _mint_page(raw_conn, inv, s["acme_loc"], 1)   # no sha256
    await raw_conn.commit()

    r = await app_client.post(
        f"/invoices/{inv}/pages/1/download-url", headers=auth(s["alice"]))

    assert r.status_code == 409, r.text


async def test_download_url_404s_for_another_orgs_invoice(
        app_client, seeded_biz, raw_conn, monkeypatch):
    """404, never 403: distinguishing 'absent' from 'not yours' would leak
    the existence of another org's invoice."""
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_get", lambda path: _fake_sign_get(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])
    await _confirm(raw_conn, inv, s["acme_loc"], 1)

    r = await app_client.post(
        f"/invoices/{inv}/pages/1/download-url", headers=auth(s["bob"]))

    assert r.status_code == 404, r.text


async def test_download_url_404s_for_a_page_that_does_not_exist(
        app_client, seeded_biz, raw_conn, monkeypatch):
    import api.routes.invoices as mod
    monkeypatch.setattr(mod, "sign_get", lambda path: _fake_sign_get(path))

    s = seeded_biz
    inv = await _mint_invoice_for(raw_conn, s["acme_loc"])

    r = await app_client.post(
        f"/invoices/{inv}/pages/7/download-url", headers=auth(s["alice"]))

    assert r.status_code == 404, r.text
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_invoices.py -q -k download_url`
Expected: FAIL — 404 from FastAPI for every case (the route does not exist), and `AttributeError` on `monkeypatch.setattr(mod, "sign_get", ...)` because the attribute is absent.

- [ ] **Step 3: Add `sign_get` to `api/routes/invoices.py`**

Insert immediately after `sign_put` (after line 62):

```python
async def sign_get(path: str):
    """A pre-signed download URL for `path`, and when it expires.

    The mirror of `sign_put`, with one difference that will bite anyone who
    copies that function: Supabase's DOWNLOAD signing endpoint returns its
    path under `signedURL`, while the UPLOAD one returns `url`. A copy-paste
    raises KeyError against real Supabase while passing against any stub
    that happens to return `url`.
    """
    base = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.post(
            f"{base}/storage/v1/object/sign/{BUCKET}/{path}",
            headers={"Authorization": f"Bearer {key}"},
            json={"expiresIn": UPLOAD_URL_TTL_SECONDS},
        )
    if response.status_code != 200:
        raise HTTPException(502, "could not sign the download URL")
    payload = response.json()
    signed = payload.get("signedURL") or payload["url"]
    expires_at = (
        datetime.now(timezone.utc) + timedelta(seconds=UPLOAD_URL_TTL_SECONDS)
    ).isoformat()
    return f"{base}/storage/v1{signed}", expires_at
```

`payload.get("signedURL") or payload["url"]` accepts both spellings deliberately — the spec flags the key as an expectation, not a verified fact, and this tolerates either without a silent failure. Step 6 verifies which one real Supabase actually sends.

- [ ] **Step 4: Add the route**

Append to `api/routes/invoices.py`:

```python
@router.post("/invoices/{invoice_id}/pages/{page_no}/download-url")
async def mint_download_url(invoice_id: uuid.UUID, page_no: int, request: Request,
                            caller: CallerIdentity = Depends(require_caller)):
    """A signed GET for a page whose bytes are confirmed present.

    409 rather than 404 when `sha256` is null: the row exists and is ours,
    it simply has no bytes in the bucket yet, and a signed URL would resolve
    to nothing. 404 stays reserved for absent-or-another-org's (`_invoice_org`).
    """
    if page_no < 1:
        raise HTTPException(422, "page_no must be positive")
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        org_id = await _invoice_org(conn, invoice_id)
        cur = await conn.execute(
            "SELECT sha256 FROM invoice_pages"
            " WHERE invoice_id = %s AND page_no = %s AND deleted_at IS NULL",
            (invoice_id, page_no))
        row = await cur.fetchone()
    if row is None:
        raise HTTPException(404, "page not found")
    if row[0] is None:
        raise HTTPException(409, "page bytes are not confirmed")
    url, expires_at = await sign_get(storage_path(org_id, invoice_id, page_no))
    return {"url": url, "expires_at": expires_at}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/test_invoices.py -q -k download_url`
Expected: 4 passed.

- [ ] **Step 6: Run the whole backend suite — nothing may regress**

Run: `uv run pytest -q`
Expected: `1479 passed` (1475 + the 4 new). If the count differs, reconcile before committing.

- [ ] **Step 7: Commit**

```bash
git add api/routes/invoices.py tests/test_invoices.py
git commit -m "feat: signed download URLs for confirmed invoice pages"
```

---

### Task 2: `ApiClient.downloadURL`

**Files:**
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Api/ApiModels.swift` (add `SignedDownload` near `SignedUpload`, ~line 290)
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Api/ApiClient.swift` (add after `confirmPage`, ~line 235)

**Interfaces:**
- Consumes: Task 1's endpoint; existing private `decode(_:_:method:)` and `makeURL(_:query:)`.
- Produces: `public struct SignedDownload: Codable, Sendable { let url: String; let expiresAt: String }` and `public func downloadURL(invoiceId: String, pageNo: Int) async throws -> SignedDownload`.

- [ ] **Step 1: Add the model**

In `ApiModels.swift`, immediately after the `SignedUpload` struct:

```swift
/// The response of `api/routes/invoices.py`'s `mint_download_url`. No
/// `storagePath`: unlike an upload, the caller does not need the key --
/// the server already resolved it and the URL is scoped to that one object.
public struct SignedDownload: Codable, Sendable {
    public let url: String
    public let expiresAt: String

    public init(url: String, expiresAt: String) {
        self.url = url
        self.expiresAt = expiresAt
    }
}
```

- [ ] **Step 2: Add the client method**

In `ApiClient.swift`, immediately after `confirmPage`:

```swift
    /// A signed GET for a page whose local file is gone. Minted per view,
    /// never cached: the URL expires in an hour and a cached one would be
    /// dead by the next time anyone opens an old invoice.
    ///
    /// Throws on 409 -- the page's bytes were never confirmed. Unreachable
    /// for a page THIS device evicted (the sweep only deletes pages whose
    /// outbox reached `uploaded`, and that implies a server-side sha256),
    /// so the view treats it as the generic error state.
    public func downloadURL(invoiceId: String, pageNo: Int) async throws -> SignedDownload {
        try await decode(
            SignedDownload.self,
            makeURL("/invoices/\(invoiceId)/pages/\(pageNo)/download-url"),
            method: "POST")
    }
```

- [ ] **Step 3: Build the Kit to verify it compiles**

Run: `cd ios/CostSauceKit && swift build`
Expected: build succeeds, no warnings.

- [ ] **Step 4: Run the Kit suite — nothing may regress**

Run: `cd ios/CostSauceKit && swift test`
Expected: `206 tests ... passed` (unchanged; this task adds no tests — it is a thin wire-level mirror whose behaviour Task 1 already pins server-side and Task 7 exercises end to end).

- [ ] **Step 5: Commit**

```bash
git add ios/CostSauceKit/Sources/CostSauceKit/Api/ApiModels.swift \
        ios/CostSauceKit/Sources/CostSauceKit/Api/ApiClient.swift
git commit -m "feat: ApiClient.downloadURL mirroring the upload mint"
```

---

### Task 3: `ImageEviction` takes an injectable budget

**Files:**
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Upload/ImageEviction.swift:40-58`
- Test: `ios/CostSauceKit/Tests/CostSauceKitTests/ImageEvictionTests.swift`

**Interfaces:**
- Produces: `ImageEviction.evictable(candidates:now:maximumBytes:maximumAge:)`, both budget parameters defaulted to the existing statics so every current call site and test is source-compatible.

- [ ] **Step 1: Write the failing tests**

Append inside `@Suite struct ImageEvictionTests`:

```swift
    /// The acceptance walk needs one ordinary captured page to exceed the
    /// budget, which the 500MB production value can never do.
    @Test func injectedByteBudgetEvictsWhereTheDefaultWouldNot() {
        let evicted = ImageEviction.evictable(
            candidates: [candidate("a", bytes: 1_000, ageDays: 1)],
            now: now, maximumBytes: 100)
        #expect(evicted == ["a"])
    }

    @Test func injectedAgeBudgetEvictsWhereTheDefaultWouldNot() {
        let evicted = ImageEviction.evictable(
            candidates: [candidate("a", bytes: 1_000, ageDays: 2)],
            now: now, maximumAge: 86_400)
        #expect(evicted == ["a"])
    }

    /// The invariant survives budget injection: a tiny budget must still
    /// never sacrifice the only copy of an un-uploaded page.
    @Test func injectedBudgetStillNeverEvictsAnUnuploadedPage() {
        let evicted = ImageEviction.evictable(
            candidates: [candidate("a", bytes: 1_000_000, ageDays: 3650, uploaded: false)],
            now: now, maximumBytes: 1, maximumAge: 1)
        #expect(evicted.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/CostSauceKit && swift test --filter ImageEvictionTests`
Expected: compile error — `extra arguments 'maximumBytes', 'maximumAge' in call`.

- [ ] **Step 3: Parameterise the function**

Replace the signature at `ImageEviction.swift:40` so it reads:

```swift
    /// Page ids safe to delete, oldest first. An un-uploaded page is never
    /// returned, at any age or size: until storage acknowledges, the local
    /// file is the only copy in existence (§13).
    ///
    /// The budget is a PARAMETER rather than a read of the statics so the
    /// acceptance walk can inject one an ordinary page exceeds. Production
    /// passes nothing and gets the calibrated defaults.
    public static func evictable(
        candidates: [Candidate],
        now: Date,
        maximumBytes: Int = ImageEviction.maximumBytes,
        maximumAge: TimeInterval = ImageEviction.maximumAge
    ) -> [String] {
```

The body already references the bare names `maximumAge` (line 51) and `maximumBytes` (line 52), which now resolve to the parameters rather than the statics. **Verify both lines read `> maximumAge` and `> maximumBytes` with no `ImageEviction.` prefix** — a leftover prefix would silently keep reading the static and the injected budget would do nothing.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/CostSauceKit && swift test --filter ImageEvictionTests`
Expected: all pass, including every pre-existing case (they call the two-argument form and get the defaults).

- [ ] **Step 5: Commit**

```bash
git add ios/CostSauceKit/Sources/CostSauceKit/Upload/ImageEviction.swift \
        ios/CostSauceKit/Tests/CostSauceKitTests/ImageEvictionTests.swift
git commit -m "feat: injectable eviction budget, defaulted to the calibrated values"
```

---

### Task 4: `LocalStore.evictionCandidates()`

**Files:**
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Store/LocalStore.swift` (add after `livePages`, ~line 530)
- Test: `ios/CostSauceKit/Tests/CostSauceKitTests/StoreTests.swift`

**Interfaces:**
- Consumes: `Kernel.parsePostgresTimestamp(_:)`, the `invoice_pages` and `pending_uploads` tables, `PendingUpload.State.uploaded`.
- Produces:

```swift
public struct EvictionCandidate: Sendable, Equatable {
    public let pageId: String
    public let invoiceId: String
    public let pageNo: Int
    public let createdAt: Date
    public let isUploaded: Bool
}

public func evictionCandidates() throws -> [EvictionCandidate]
```

- [ ] **Step 1: Read the existing invoice test helpers**

Open `StoreTests.swift` and note the exact names and signatures its Phase 3a invoice tests use for store construction, `createInvoice`, `addInvoicePage`, and `tombstoneInvoice`. `addInvoicePage` returns both a row id and a storage path — note which property is which. Step 2's tests must use those real shapes, not the illustrative ones below.

- [ ] **Step 2: Write the failing tests**

Append to `StoreTests.swift`, adapting the helper calls to what Step 1 found:

```swift
    /// isUploaded comes from the OUTBOX, not the row's sha256. A page this
    /// device just uploaded has no local sha256 until a later pull brings
    /// the server's confirmation back -- and the outbox reaching `uploaded`
    /// is the only local proof that storage acknowledged.
    @Test func evictionCandidatesReadUploadedFromTheOutboxNotSha256() throws {
        let store = try makeStore()
        let invoice = try store.createInvoice(locationId: "loc")
        let added = try store.addInvoicePage(invoiceId: invoice, orgId: "org")
        try store.enqueueUpload(pageId: added.pageId, localPath: "/tmp/1.jpg")

        var candidates = try store.evictionCandidates()
        #expect(candidates.count == 1)
        #expect(candidates[0].isUploaded == false)   // queued, not uploaded

        var upload = try #require(try store.pendingUploads().first)
        upload = UploadQueue.transition(upload, on: .succeeded)
        try store.updateUpload(upload)

        candidates = try store.evictionCandidates()
        #expect(candidates[0].isUploaded == true)
        #expect(candidates[0].pageId == added.pageId)
        #expect(candidates[0].invoiceId == invoice)
        #expect(candidates[0].pageNo == 1)
    }

    /// A page with no outbox row at all -- pulled from another device --
    /// is NOT uploaded as far as this device can prove, so it must never
    /// be evictable.
    @Test func evictionCandidatesTreatAPageWithNoOutboxRowAsNotUploaded() throws {
        let store = try makeStore()
        let invoice = try store.createInvoice(locationId: "loc")
        _ = try store.addInvoicePage(invoiceId: invoice, orgId: "org")

        let candidates = try store.evictionCandidates()
        #expect(candidates.count == 1)
        #expect(candidates[0].isUploaded == false)
    }

    @Test func evictionCandidatesExcludeTombstonedPages() throws {
        let store = try makeStore()
        let invoice = try store.createInvoice(locationId: "loc")
        _ = try store.addInvoicePage(invoiceId: invoice, orgId: "org")
        try store.tombstoneInvoice(invoice)

        #expect(try store.evictionCandidates().isEmpty)
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ios/CostSauceKit && swift test --filter StoreTests`
Expected: compile error — `value of type 'LocalStore' has no member 'evictionCandidates'`.

- [ ] **Step 4: Add the record type**

Next to the other public record types in `LocalStore.swift`:

```swift
public struct EvictionCandidate: Sendable, Equatable {
    public let pageId: String
    public let invoiceId: String
    public let pageNo: Int
    public let createdAt: Date
    public let isUploaded: Bool
}
```

- [ ] **Step 5: Implement the query**

Add to `LocalStore.swift` after `livePages`:

```swift
    /// Every live page with what eviction needs to judge it.
    ///
    /// `isUploaded` is LEFT JOINed from the outbox and defaults to false: a
    /// page with no outbox row (pulled from another device) cannot be proven
    /// uploaded by this device, and the eviction invariant is that an
    /// unproven page is never deleted.
    ///
    /// Returns rows, not files. The caller filters to pages that actually
    /// have a file on disk before measuring bytes -- counting bytes that are
    /// not there would evict real files to get under a budget the device was
    /// never over.
    public func evictionCandidates() throws -> [EvictionCandidate] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id AS page_id, p.invoice_id, p.page_no, p.created_at,
                       COALESCE(u.state, '') AS upload_state
                  FROM invoice_pages p
                  LEFT JOIN pending_uploads u ON u.page_id = p.id
                 WHERE p.deleted_at IS NULL
                 ORDER BY p.created_at, p.id
                """)
            return try rows.map { row in
                EvictionCandidate(
                    pageId: row["page_id"],
                    invoiceId: row["invoice_id"],
                    // page_no is TEXT locally like every synced column.
                    pageNo: Int(row["page_no"] as String) ?? 0,
                    createdAt: try Kernel.parsePostgresTimestamp(row["created_at"]),
                    isUploaded: (row["upload_state"] as String)
                        == PendingUpload.State.uploaded.rawValue)
            }
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd ios/CostSauceKit && swift test --filter StoreTests`
Expected: the three new tests pass and every pre-existing `StoreTests` case still passes.

- [ ] **Step 7: Run the full Kit suite**

Run: `cd ios/CostSauceKit && swift test`
Expected: `212 tests ... passed` (206 + 3 from Task 3 + 3 here). Reconcile any difference before committing.

- [ ] **Step 8: Commit**

```bash
git add ios/CostSauceKit/Sources/CostSauceKit/Store/LocalStore.swift \
        ios/CostSauceKit/Tests/CostSauceKitTests/StoreTests.swift
git commit -m "feat: evictionCandidates, with isUploaded read from the outbox"
```

---

### Task 5: `ImageSweeper` and its two triggers

**Files:**
- Create: `ios/CostSauce/Upload/ImageSweeper.swift`
- Modify: `ios/CostSauce/CostSauceApp.swift:68-72` (the `scenePhase` `onChange`)
- Modify: `ios/CostSauce/Views/InvoiceCaptureView.swift:96` (`ingest`, at its end)

**Interfaces:**
- Consumes: `LocalStore.evictionCandidates()` (Task 4), `ImageEviction.evictable(candidates:now:maximumBytes:maximumAge:)` (Task 3), existing `InvoiceFiles.url(invoiceId:pageNo:)` and `InvoiceFiles.delete(atPath:)`.
- Produces: `enum ImageSweeper { static func sweep(store: LocalStore, now: Date = Date()) }` — the single entry point a future `BGTaskScheduler` task can also call.

- [ ] **Step 1: Create the sweeper**

```swift
// Deletes cached page images the policy says are safe to lose.
//
// The POLICY is ImageEviction, pure and in the Kit. This is the part that
// cannot be pure: it stats files and deletes them, so it lives in the app
// target beside InvoiceFiles.
//
// One entry point on purpose. Today two triggers call it (foreground and
// end-of-capture); a BGTaskScheduler task can call the same function later
// without any of this being rewritten.

import Foundation
import CostSauceKit

enum ImageSweeper {

    /// UITEST budget: one ordinary captured page is 0.5-1.5MB, so a 1-byte
    /// ceiling guarantees the walk evicts something real. Same seam rule as
    /// AppModel.pageSource and BackgroundUploader -- gated on UITEST=1 only,
    /// production always takes the calibrated defaults.
    private static var isUITest: Bool {
        ProcessInfo.processInfo.environment["UITEST"] == "1"
    }

    /// Deletes FILES, never rows. The invoice_pages row surviving is what
    /// keeps the page re-downloadable and the purchase's invoice_page_id
    /// provenance link intact.
    static func sweep(store: LocalStore, now: Date = Date()) {
        guard let candidates = try? store.evictionCandidates() else { return }

        // Only pages with a file on disk may be measured. A page pulled from
        // another device has a row and no file; counting its bytes would
        // evict real files to get under a budget we were never over.
        var pathsByPageId: [String: String] = [:]
        var measured: [ImageEviction.Candidate] = []

        for candidate in candidates {
            guard let url = try? InvoiceFiles.url(
                invoiceId: candidate.invoiceId, pageNo: candidate.pageNo),
                let attributes = try? FileManager.default
                    .attributesOfItem(atPath: url.path),
                let bytes = attributes[.size] as? Int
            else { continue }

            pathsByPageId[candidate.pageId] = url.path
            measured.append(ImageEviction.Candidate(
                pageId: candidate.pageId, bytes: bytes,
                capturedAt: candidate.createdAt, isUploaded: candidate.isUploaded))
        }

        let evicted = isUITest
            ? ImageEviction.evictable(
                candidates: measured, now: now, maximumBytes: 1, maximumAge: 1)
            : ImageEviction.evictable(candidates: measured, now: now)

        for pageId in evicted {
            if let path = pathsByPageId[pageId] {
                InvoiceFiles.delete(atPath: path)
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `cd ios && xcodegen generate`
Expected: `Created project at …/CostSauce.xcodeproj`. (`project.yml` globs source directories, so the new file needs no manual registration.)

- [ ] **Step 3: Wire the foreground trigger**

In `CostSauceApp.swift`, replace the `onChange` body (lines 68-72) with:

```swift
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await appModel.refreshOnlineData() }
                if let store = appModel.store {
                    ImageSweeper.sweep(store: store)
                }
            }
        }
```

- [ ] **Step 4: Wire the end-of-capture trigger**

At the very end of `InvoiceCaptureView.ingest(_:)` — **after the loop over every scanned image completes**, not inside it — add:

```swift
        // Once per capture SESSION, not per page: sweeping between pages of
        // one multi-page invoice measures a cache still mid-growth and could
        // evict page 1 while page 3 is still being written.
        if let store = appModel.store {
            ImageSweeper.sweep(store: store)
        }
```

- [ ] **Step 5: Build the app target**

Run:
```bash
cd ios && xcodebuild build-for-testing -project CostSauce.xcodeproj -scheme CostSauce \
  -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D' \
  2>&1 | grep -E "warning:|error:|BUILD"
```
Expected: `** TEST BUILD SUCCEEDED **` and **zero** `warning:` lines.

- [ ] **Step 6: Commit**

```bash
git add ios/CostSauce/Upload/ImageSweeper.swift ios/CostSauce/CostSauceApp.swift \
        ios/CostSauce/Views/InvoiceCaptureView.swift
git commit -m "feat: wire the eviction sweep to foreground and end-of-capture"
```

---

### Task 6: `InvoicePageView` re-downloads on demand

**Files:**
- Modify: `ios/CostSauce/Views/InvoicePageView.swift` (the `else` branch at lines 73-78, plus new state and a loader)

**Interfaces:**
- Consumes: `ApiClient.downloadURL(invoiceId:pageNo:)` (Task 2), the app model's `ApiClient` property.
- Produces: no new public surface; three view states replacing the current two.

- [ ] **Step 1: Confirm the API property's name and optionality**

Run: `grep -n "ApiClient" ios/CostSauce/AppModel.swift | head`
Note the property's exact name and whether it is optional. Steps 3-4 below assume `appModel.api` as an optional; adjust every reference if it differs.

- [ ] **Step 2: Add the download state**

Add to the `@State` block near the top of the struct:

```swift
    /// Re-downloaded bytes live HERE and never touch disk. Writing them back
    /// would thrash: the age rule evicts any uploaded page past 90 days
    /// regardless of size, so a restored old page would be deleted again on
    /// the very next foreground sweep -- and old invoices are exactly the
    /// ones people reopen during a dispute.
    @State private var downloaded: [String: UIImage] = [:]
    @State private var downloadFailure: DownloadFailure?
    @State private var isDownloading = false

    private enum DownloadFailure: Equatable { case offline, failed }
```

- [ ] **Step 3: Replace the unavailable branch**

Replace lines 73-78 (the `else { ContentUnavailableView("Photo Not on This Device" …) }`) with:

```swift
            } else if let image = downloaded[page.id] {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(zoom)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(magnification)
                        .accessibilityLabel("Invoice page \(page.page_no)")
                }
            } else if isDownloading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailable(page)
            }
```

- [ ] **Step 4: Add the unavailable view and the loader**

Add these methods to the struct:

```swift
    /// Offline and broken get DIFFERENT copy: someone in a walk-in cooler
    /// needs to know whether waiting will help. Everything that is not a
    /// transport failure -- including the endpoint's 409 -- is the generic
    /// error, because a 409 is unreachable for a page this device evicted
    /// and a third message for an unactionable case is not worth the string.
    @ViewBuilder
    private func unavailable(_ page: LocalInvoicePage) -> some View {
        VStack(spacing: 12) {
            if downloadFailure == .offline {
                ContentUnavailableView(
                    "Photo Needs a Connection", systemImage: "icloud.slash",
                    description: Text("It's stored safely — reconnect to view it."))
            } else {
                ContentUnavailableView(
                    "Photo Couldn't Be Loaded", systemImage: "icloud",
                    description: Text("This page's photo isn't on this device."))
            }
            Button("Retry") {
                Task { await download(page) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("retryPageDownload")
        }
    }

    private func download(_ page: LocalInvoicePage) async {
        guard let api = appModel.api, let pageNo = Int(page.page_no) else {
            downloadFailure = .failed
            return
        }
        isDownloading = true
        downloadFailure = nil
        defer { isDownloading = false }
        do {
            let signed = try await api.downloadURL(
                invoiceId: page.invoice_id, pageNo: pageNo)
            guard let url = URL(string: signed.url) else {
                downloadFailure = .failed
                return
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                downloadFailure = .failed
                return
            }
            downloaded[page.id] = image
        } catch let error as URLError where
            error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            downloadFailure = .offline
        } catch {
            downloadFailure = .failed
        }
    }
```

- [ ] **Step 5: Trigger the download when a page has no local file**

Change the existing `.task { load() }` on the body to:

```swift
            .task {
                load()
                if let pages, let page = selectedPage(in: pages),
                   localImage(for: page) == nil, downloaded[page.id] == nil {
                    await download(page)
                }
            }
```

- [ ] **Step 6: Verify the purchase button is untouched**

Read the `NavigationLink` wrapping "Add purchase from this page" (currently lines 80-90) and confirm **no `.disabled(...)` was introduced** and that it sits outside the image `if/else` chain, so it renders in all three states. This is a Global Constraint: photo-assisted entry is an aid, not a precondition.

- [ ] **Step 7: Build the app target**

Run:
```bash
cd ios && xcodebuild build-for-testing -project CostSauce.xcodeproj -scheme CostSauce \
  -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D' \
  2>&1 | grep -E "warning:|error:|BUILD"
```
Expected: `** TEST BUILD SUCCEEDED **`, zero warnings.

- [ ] **Step 8: Commit**

```bash
git add ios/CostSauce/Views/InvoicePageView.swift
git commit -m "feat: re-download an evicted page into memory, with honest failure states"
```

---

### Task 7: Storage stub retains bytes; acceptance walk proves the round trip

**Files:**
- Modify: `docs/runbooks/phase-3a-acceptance.md` (§2.3's stub listing, §1 and §4's walk description, §8's coverage gaps)
- Modify: `ios/CostSauceUITests/SmokeTests.swift` (extend `testInvoiceCaptureUploadAndPhotoAssistedPurchase`)

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: no code interface; an end-to-end proof and a runbook that matches it.

- [ ] **Step 1: Update the stub listing in the runbook**

In §2.3, replace the stub's module constants and its three handlers with:

```python
STORE: dict[str, bytes] = {}
SIGN_PREFIX = "/storage/v1/object/upload/sign/"
SIGN_GET_PREFIX = "/storage/v1/object/sign/"


    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        # Download signing returns its path under "signedURL"; upload signing
        # returns "url". api/routes/invoices.py reads each accordingly, and
        # this stub must reproduce the difference or the test proves nothing.
        if self.path.startswith(SIGN_PREFIX):
            payload = {"url": self.path[len("/storage/v1"):] + "?token=smoke"}
        elif self.path.startswith(SIGN_GET_PREFIX):
            payload = {"signedURL": self.path[len("/storage/v1"):] + "?token=smoke"}
        else:
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        if not self.path.startswith(SIGN_PREFIX):
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        chunks = []
        while length > 0:
            chunk = self.rfile.read(min(length, 1 << 16))
            if not chunk:
                break
            chunks.append(chunk)
            length -= len(chunk)
        # 3a discarded the bytes because its proof of arrival was the confirm
        # row. The download walk needs them back.
        STORE[self.path.split("?")[0].replace(SIGN_PREFIX, "", 1)] = b"".join(chunks)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        key = self.path.split("?")[0].replace(SIGN_GET_PREFIX, "", 1)
        data = STORE.get(key)
        if data is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
```

Both handlers strip their own prefix so the key is the bare `{bucket}/{org}/{invoice}/{page}.jpg` either way. **Step 4 verifies this by checking the stub log shows `200` on the GET, not `404`.**

- [ ] **Step 2: Copy the updated stub to scratch and start the stack**

Follow §2 of the runbook exactly: fresh `cs-3a-smoke` container on 55443, seed **while uvicorn is down**, start the updated stub on 8402, then `uvicorn` on 8401. Confirm:

```bash
curl -sS http://127.0.0.1:8401/config
# -> {"supabase_url":"http://127.0.0.1:8402","supabase_anon_key":null}
```

- [ ] **Step 3: Extend the acceptance journey**

In `SmokeTests.swift`, first read how the existing journey navigates to the page view and reuse its selectors. Then, after the existing assertion that the row indicator reads **Uploaded**, add:

```swift
        // The sweep runs on foreground under a 1-byte UITEST budget, so
        // backgrounding and returning must delete the page's file.
        XCUIDevice.shared.press(.home)
        app.activate()

        // CHECKPOINT 2 (sweep + re-download): the page's local file is gone
        // and the view recovers it from storage through the signed GET.
        print("CHECKPOINT 2 (sweep + re-download)")

        let redownloaded = app.images["Invoice page 1"]
        XCTAssertTrue(redownloaded.waitForExistence(timeout: 20),
                      "an evicted page must come back from storage")
```

- [ ] **Step 4: Run the 3a journey alone**

```bash
cd ios && xcodebuild test -project CostSauce.xcodeproj -scheme CostSauce \
  -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D' \
  -only-testing:CostSauceUITests/SmokeTests/testInvoiceCaptureUploadAndPhotoAssistedPurchase
```
Expected: passes. If the image never appears, check the stub log for the GET — a `404` there means Step 1's key handling is wrong. Fix the normalisation rather than loosening the lookup.

- [ ] **Step 5: Run the whole suite — nothing may regress**

Reseed with uvicorn down, restart it, then:
```bash
cd ios && xcodebuild test -project CostSauce.xcodeproj -scheme CostSauce \
  -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D'
```
Expected: **4/4**, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Update the runbook's prose**

In §1 add the new journey steps and the `ImageSweeper`/`InvoicePageView`/`invoices.py` files this work touched; in §4 record CHECKPOINT 2; in §8 **remove "Eviction sweeps" from the coverage-gap list** — automation now deletes a real file and recovers it — and replace that entry with a note that `BGTaskScheduler` background sweeping remains unbuilt. Leave the other three gaps untouched.

- [ ] **Step 7: Tear down and commit**

```bash
kill %1 %2 2>/dev/null; docker rm -f cs-3a-smoke
git add docs/runbooks/phase-3a-acceptance.md ios/CostSauceUITests/SmokeTests.swift
git commit -m "test: prove a swept page comes back through the signed download"
```

---

## Final verification

- [ ] `uv run pytest -q` → **1479 passed**
- [ ] `cd ios/CostSauceKit && swift test` → **212 tests passed**
- [ ] `xcodebuild build-for-testing …` → **zero warnings**
- [ ] Full XCUITest suite → **4/4**
- [ ] `git status` clean; branch `invoice-page-redownload` ready for a PR against `main`

Counts are the expected arithmetic, not measurements. If any differs, reconcile it before opening the PR rather than adjusting the number here.
