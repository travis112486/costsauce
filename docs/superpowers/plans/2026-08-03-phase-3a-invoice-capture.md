# Phase 3a — Invoice Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture invoice pages with the system document scanner, store and upload them durably offline-first, and let the owner key purchases in against a page on screen.

**Architecture:** Two queues (spec 3a-D2): invoice rows ride the existing `/sync` protocol as two new syncable tables, while page images ride a separate local upload queue driving a background `URLSession` against pre-signed URLs. Rows and bytes are both written to disk before any network call, so nothing captured is ever lost to a failure downstream.

**Tech Stack:** Postgres 17 + RLS (migration `0017`), FastAPI, psycopg; Swift 6 / SwiftUI / GRDB (`CostSauceKit`), VisionKit `VNDocumentCameraViewController`, Accelerate/Core Image, background `URLSession`.

**Spec:** `docs/superpowers/specs/2026-08-03-phase-3a-invoice-capture-design.md`

---

## STATUS: PARTIAL — tasks 2 onward need their step detail written

Task 1 below is complete and executable. **Tasks 2–10 have their boundaries,
files, and interfaces fixed, but not yet their step-by-step TDD detail.**
They were deliberately not written rather than written from guessed
signatures: the iOS tasks need `Records.swift` / `Schema.swift` column
shapes and the VisionKit + background-`URLSession` APIs read first, and a
plan that names types no task defines is worse than one that stops.

**To resume:** read `ios/CostSauceKit/Sources/CostSauceKit/Store/Records.swift`,
`Store/Schema.swift`, and `Sync/SyncEngine.swift`, then write Tasks 2–10 to
the same shape as Task 1. The decomposition below does not need revisiting.

---

## Global Constraints

Copied verbatim from the spec and the parent spec's Global Constraints; every task's requirements implicitly include these.

- **Money, quantity, and percentage values are STRINGS end to end** — never routed through `Double`/`Float`/`Decimal`. The one carve-out is pixel math that never touches a rendered value.
- **`storage_path` is written by the client, not the server** — a deterministic function of the client-minted invoice UUID plus page number, so a retry overwrites rather than duplicates. The server refuses a client-supplied path disagreeing with its own derivation.
- **The local file is never deleted until storage acknowledges** (parent spec §13).
- **A page that has not uploaded is never evictable**, at any age or size (spec 3a-D4).
- **The unsynced badge counts pending uploads as well as pending ops** (spec §9).
- **`purchases.source` stays `'manual'`** in this phase (spec 3a-D5).
- **No on-device OCR.** The document *scanner* and image-quality math (resolution, variance-of-Laplacian) are permitted; text recognition is not (parent spec D4).
- **Row and bytes are persisted before the upload starts** (parent spec §12 step 3).
- Sharpness and resolution thresholds, and the eviction bounds, **have no values in the spec by design** — Task 6 sets them and records how it calibrated them.

---

## File Structure

**Backend**
- Create `supabase/migrations/0017_invoice_capture.sql` — the two new tables, their RLS policies, the live-only partial unique, and the `purchases.invoice_page_id` column.
- Modify `api/services/sync.py:23-40` — `TABLE_ORDER` (reordered, not appended), `INSERT_FIELDS`, `UPDATE_FIELDS`, `_PARENT_CHECKS`.
- Create `api/routes/invoices.py` — the mint-upload-URL and confirm-upload endpoints.
- Modify `api/main.py` — register the new router.

**Kit (`CostSauceKit`)**
- Modify `Store/Schema.swift` — `invoices`, `invoice_pages`, `pending_uploads` tables in a new migration version.
- Modify `Store/Records.swift` — `LocalInvoice`, `LocalInvoicePage`, `PendingUpload` records; `LocalPurchase` gains `invoice_page_id`.
- Modify `Store/LocalStore.swift` — reads for invoices, pages, and the upload queue.
- Modify `Store/LocalEdits.swift` — `createInvoice`, `addInvoicePage`, `tombstoneInvoice`.
- Create `Store/StoragePath.swift` — deterministic `{org_id}/{invoice_uuid}/{page_no}.jpg` derivation. Its own file because both the Kit and the confirm-endpoint contract depend on it agreeing exactly.
- Create `Upload/UploadQueue.swift` — the queue state machine, pure and testable.
- Create `Upload/ImageEviction.swift` — the eviction policy, pure and testable.
- Modify `Sync/SyncEngine.swift` — the two new tables in push/apply.

**App**
- Create `Views/InvoiceCaptureView.swift` — the scanner wrapper plus quality gates.
- Create `Views/InvoiceListView.swift`, `Views/InvoicePageView.swift` — browse, and the page-visible-while-typing entry surface.
- Create `Upload/BackgroundUploader.swift` — the `URLSession` background delegate.
- Modify `Views/PurchaseEntryView.swift` — accept an optional `invoicePageId`.
- Modify `AppModel.swift` — fold pending uploads into `pendingCount`.

**Tests**
- Modify `tests/test_sync.py` — the reordered `TABLE_ORDER` apply path, asserted directly.
- Create `tests/test_invoices.py` — endpoints and cross-org RLS.
- Create `CostSauceKitTests/UploadQueueTests.swift`, `ImageEvictionTests.swift`, `StoragePathTests.swift`.
- Modify `CostSauceKitTests/LocalEditsTests.swift`, `SyncEngineTests.swift`.
- Modify `ios/CostSauceUITests/SmokeTests.swift` — the acceptance walk.

---

## Task List

| # | Task | Deliverable a reviewer could reject independently |
|---|---|---|
| 1 | Migration `0017` + RLS | Schema and policies exist; cross-org isolation proven |
| 2 | `sync.py` table config, incl. the `TABLE_ORDER` reorder | Both tables sync server-side; the reorder is proven not to break the existing apply path |
| 3 | Upload-URL and confirm endpoints | A page's bytes can be uploaded and confirmed against a real bucket |
| 4 | Kit schema, records, and `StoragePath` | Local tables exist; path derivation matches the server's byte for byte |
| 5 | `LocalEdits` invoice helpers + `SyncEngine` wiring | An invoice captured offline pushes and converges |
| 6 | Capture UI + quality gates (**sets the thresholds**) | A scan is accepted or refused with a retake prompt |
| 7 | `UploadQueue` + `BackgroundUploader` | A queued page uploads, retries with backoff, survives relaunch |
| 8 | `ImageEviction` + badge integration | Bounded cache; un-uploaded pages never evicted; badge counts uploads |
| 9 | Photo-assisted entry | A purchase minted against a visible page carries `invoice_page_id` |
| 10 | XCUITest acceptance + fixture-injection seam | The whole walk runs headless without a camera |

**Task 6 note:** the scanner cannot be driven in the simulator, so the
`UITEST`-gated injection seam that Task 10 needs must be built *in Task 6*,
where the scanner's output is first handled — not retrofitted. Phase 2b
shipped a permanently unautomatable flow for exactly this reason.

---

### Task 1: Migration `0017` — invoice tables, RLS, and the purchases link

**Files:**
- Create: `supabase/migrations/0017_invoice_capture.sql`
- Test: `tests/test_invoices.py`

**Interfaces:**
- Consumes: the existing `locations`, `purchases` tables and the `0004` RLS policy pattern.
- Produces: tables `invoices` and `invoice_pages` with the standard sync column set (`client_mutated_at timestamptz`, `server_seq bigint`, `updated_at timestamptz`, `deleted_at timestamptz`, `created_at timestamptz`); index `invoice_pages_live_uq` on `(invoice_id, page_no) WHERE deleted_at IS NULL`; column `purchases.invoice_page_id uuid NULL`.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_invoices.py
import pytest


@pytest.mark.asyncio
async def test_invoice_page_live_unique_allows_retake_after_tombstone(conn, location_id):
    """A retaken page tombstones its predecessor and reuses page_no.

    The partial unique must be live-only, exactly like recipe_items_live_uq:
    a full unique would make a retake impossible without renumbering pages.
    """
    inv = await conn.fetchval(
        "INSERT INTO invoices (location_id, captured_at, client_mutated_at) "
        "VALUES (%s, now(), now()) RETURNING id", (location_id,))
    first = await conn.fetchval(
        "INSERT INTO invoice_pages (invoice_id, location_id, page_no, storage_path, "
        "client_mutated_at) VALUES (%s, %s, 1, 'org/inv/1.jpg', now()) RETURNING id",
        (inv, location_id))
    await conn.execute(
        "UPDATE invoice_pages SET deleted_at = now() WHERE id = %s", (first,))

    # The retake: same (invoice_id, page_no), predecessor tombstoned.
    await conn.execute(
        "INSERT INTO invoice_pages (invoice_id, location_id, page_no, storage_path, "
        "client_mutated_at) VALUES (%s, %s, 1, 'org/inv/1.jpg', now())",
        (inv, location_id))

    live = await conn.fetchval(
        "SELECT count(*) FROM invoice_pages "
        "WHERE invoice_id = %s AND deleted_at IS NULL", (inv,))
    assert live == 1


@pytest.mark.asyncio
async def test_deleting_an_invoice_page_leaves_its_purchase(conn, location_id, ingredient_id):
    """ON DELETE SET NULL, not CASCADE: a purchase records a real cost the
    business incurred, and deleting the photograph must not delete it."""
    inv = await conn.fetchval(
        "INSERT INTO invoices (location_id, captured_at, client_mutated_at) "
        "VALUES (%s, now(), now()) RETURNING id", (location_id,))
    page = await conn.fetchval(
        "INSERT INTO invoice_pages (invoice_id, location_id, page_no, storage_path, "
        "client_mutated_at) VALUES (%s, %s, 1, 'org/inv/1.jpg', now()) RETURNING id",
        (inv, location_id))
    pur = await conn.fetchval(
        "INSERT INTO purchases (location_id, ingredient_id, purchased_on, qty, unit, "
        "qty_base_units, total_price, invoice_page_id, client_mutated_at) "
        "VALUES (%s, %s, '2026-01-01', 1, 'lb', 1, '5.00', %s, now()) RETURNING id",
        (location_id, ingredient_id, page))

    await conn.execute("DELETE FROM invoice_pages WHERE id = %s", (page,))

    row = await conn.fetchrow(
        "SELECT total_price, invoice_page_id FROM purchases WHERE id = %s", (pur,))
    assert row["total_price"] is not None
    assert row["invoice_page_id"] is None


@pytest.mark.asyncio
async def test_org_a_cannot_read_org_b_invoices(conn_as_org_a, org_b_location_id):
    """The cross-org RLS test (parent spec §14) extended to the new tables."""
    rows = await conn_as_org_a.fetch(
        "SELECT id FROM invoices WHERE location_id = %s", (org_b_location_id,))
    assert rows == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_invoices.py -v`
Expected: FAIL — `psycopg.errors.UndefinedTable: relation "invoices" does not exist`

- [ ] **Step 3: Write the migration**

```sql
-- supabase/migrations/0017_invoice_capture.sql
CREATE TABLE invoices (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  location_id       uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  captured_at       timestamptz NOT NULL,
  -- Only the two values 3a can actually produce; 3b widens this alongside
  -- the parser that can set the rest (spec §4).
  parse_status      text NOT NULL DEFAULT 'unparsed'
                      CHECK (parse_status IN ('unparsed','failed')),
  client_mutated_at timestamptz NOT NULL,
  server_seq        bigint,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE invoice_pages (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  invoice_id        uuid NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  location_id       uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  page_no           int NOT NULL CHECK (page_no > 0),
  storage_path      text NOT NULL,
  width             int CHECK (width IS NULL OR width > 0),
  height            int CHECK (height IS NULL OR height > 0),
  sha256            text,
  client_mutated_at timestamptz NOT NULL,
  server_seq        bigint,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- Live-only, exactly like recipe_items_live_uq: a retake tombstones its
-- predecessor and reuses the same page_no.
CREATE UNIQUE INDEX invoice_pages_live_uq
  ON invoice_pages (invoice_id, page_no) WHERE deleted_at IS NULL;

CREATE INDEX invoices_location_seq ON invoices (location_id, server_seq);
CREATE INDEX invoice_pages_location_seq ON invoice_pages (location_id, server_seq);

-- SET NULL, not CASCADE: deleting the photograph must not delete the cost.
ALTER TABLE purchases
  ADD COLUMN invoice_page_id uuid REFERENCES invoice_pages(id) ON DELETE SET NULL;

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice_pages ENABLE ROW LEVEL SECURITY;

CREATE POLICY invoices_org_isolation ON invoices
  FOR ALL TO app_user
  USING (location_id IN (SELECT id FROM locations))
  WITH CHECK (location_id IN (SELECT id FROM locations));

CREATE POLICY invoice_pages_org_isolation ON invoice_pages
  FOR ALL TO app_user
  USING (location_id IN (SELECT id FROM locations))
  WITH CHECK (location_id IN (SELECT id FROM locations));
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_invoices.py -v`
Expected: PASS, 3 tests

- [ ] **Step 5: Run the full backend suite — the new column touches `purchases`**

Run: `uv run pytest -q`
Expected: PASS, 1451 or more. A failure here means an existing purchases test asserts an exact column set; update that assertion, not the migration.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0017_invoice_capture.sql tests/test_invoices.py
git commit -m "feat(3a): invoice and invoice_pages tables, RLS, and the purchases link"
```

---

### Tasks 2–10

Boundaries, files, and interfaces are fixed in the File Structure and Task
List above. Step-level detail still to be written — see **STATUS** at the
top of this document for what to read first and why it was deferred.
