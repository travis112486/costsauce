# Phase 3a — Invoice Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture invoice pages with the system document scanner, store and upload them durably offline-first, and let the owner key purchases in against a page on screen.

**Architecture:** Two queues (spec 3a-D2): invoice rows ride the existing `/sync` protocol as two new syncable tables, while page images ride a separate local upload queue driving a background `URLSession` against pre-signed URLs. Rows and bytes are both written to disk before any network call, so nothing captured is ever lost to a failure downstream.

**Tech Stack:** Postgres 17 + RLS (migration `0017`), FastAPI, psycopg3; Swift 6 / SwiftUI / GRDB (`CostSauceKit`), VisionKit `VNDocumentCameraViewController`, Accelerate/Core Image, background `URLSession`.

**Spec:** `docs/superpowers/specs/2026-08-03-phase-3a-invoice-capture-design.md`

---

## Global Constraints

Copied verbatim from the spec and the parent spec; every task's requirements implicitly include these.

- **Money, quantity, and percentage values are STRINGS end to end** — never routed through `Double`/`Float`/`Decimal`. The one carve-out is pixel math that never touches a rendered value.
- **Every synced column in the local SQLite store is TEXT** except `server_seq`, which is INTEGER.
- **`storage_path` is written by the client**, deterministically from the client-minted invoice UUID plus page number, so a retry overwrites rather than duplicates. The server refuses a client-supplied path disagreeing with its own derivation.
- **The local file is never deleted until storage acknowledges** (parent spec §13).
- **A page that has not uploaded is never evictable**, at any age or size (spec 3a-D4).
- **The unsynced badge counts pending uploads as well as pending ops** (spec §9).
- **`purchases.source` stays `'manual'`** in this phase (spec 3a-D5).
- **No on-device OCR.** The document *scanner* and image-quality math (resolution, variance-of-Laplacian) are permitted; text recognition is not (parent spec D4).
- **Row and bytes are persisted before the upload starts** (parent spec §12 step 3).
- Backend tests use **psycopg3** (`cur = await conn.execute(...)`, `(await cur.fetchone())[0]`), the `raw_conn` / `seeded_biz` fixtures, and `tenant_connection(pool, {"sub": user_id})` for RLS-scoped access. There is no `@pytest.mark.asyncio` decorator — asyncio mode is automatic.
- RLS policies on business tables are `TO authenticated` and scope via `current_user_memberships()`.

---

## File Structure

**Backend**
- Create `supabase/migrations/0017_invoice_capture.sql` — the two tables, RLS, the live-only partial unique, `purchases.invoice_page_id`.
- Modify `api/services/sync.py:23-40` — `TABLE_ORDER` (reordered), `INSERT_FIELDS`, `UPDATE_FIELDS`, `_PARENT_CHECKS`.
- Create `api/routes/invoices.py` — mint-upload-URL and confirm-upload endpoints.
- Modify `api/main.py` — register the router.

**Kit (`CostSauceKit`)**
- Modify `Store/Schema.swift` — a `"v2"` migration adding `invoices`, `invoice_pages`, `pending_uploads`, and `purchases.invoice_page_id`.
- Modify `Store/Records.swift` — `LocalInvoice`, `LocalInvoicePage`, `PendingUpload`; `LocalPurchase` gains `invoice_page_id`.
- Modify `Store/LocalStore.swift` — the four table-dispatch points, plus invoice and upload-queue reads.
- Modify `Store/LocalEdits.swift` — `createInvoice`, `addInvoicePage`, `tombstoneInvoice`.
- Create `Store/StoragePath.swift` — deterministic key derivation, its own file because the Kit and the confirm endpoint must agree exactly.
- Create `Upload/UploadQueue.swift` and `Upload/ImageEviction.swift` — pure state machine and pure policy, both testable without a network or a filesystem.
- Modify `Sync/SyncEngine.swift` — the two new tables in the pull/apply path.

**App**
- Create `Views/InvoiceCaptureView.swift`, `Views/InvoiceListView.swift`, `Views/InvoicePageView.swift`.
- Create `Upload/BackgroundUploader.swift`.
- Modify `Views/PurchaseEntryView.swift` — accept an optional `invoicePageId`.
- Modify `AppModel.swift` — fold pending uploads into `pendingCount`.

**Tests**
- Create `tests/test_invoices.py`; modify `tests/test_sync_service.py`, `tests/test_rls_cross_org.py`.
- Create `CostSauceKitTests/StoragePathTests.swift`, `UploadQueueTests.swift`, `ImageEvictionTests.swift`.
- Modify `CostSauceKitTests/LocalEditsTests.swift`, `StoreTests.swift`, `SyncEngineTests.swift`.
- Modify `ios/CostSauceUITests/SmokeTests.swift`.

---

## Task List

| # | Task | Independently rejectable deliverable |
|---|---|---|
| 1 | Migration `0017` + RLS | Schema and policies exist; cross-org isolation proven |
| 2 | `sync.py` table config incl. the `TABLE_ORDER` reorder | Both tables sync; the reorder provably does not break the existing apply path |
| 3 | Upload-URL and confirm endpoints | Bytes can be uploaded and confirmed |
| 4 | Kit schema, records, `StoragePath` | Local tables exist; path derivation matches the server byte for byte |
| 5 | `LocalEdits` helpers + `SyncEngine` wiring | An invoice captured offline pushes and converges |
| 6 | Capture UI, quality gates, **and the test seam** | A scan is accepted or refused with a retake prompt |
| 7 | `UploadQueue` + `BackgroundUploader` | A queued page uploads, retries, survives relaunch |
| 8 | `ImageEviction` + badge integration | Bounded cache; un-uploaded pages never evicted; badge counts uploads |
| 9 | Photo-assisted entry | A purchase minted against a visible page carries `invoice_page_id` |
| 10 | XCUITest acceptance | The whole walk runs headless, no camera |

**Task 6 carries the test seam.** The simulator has no camera, so `VNDocumentCameraViewController` cannot be driven by XCUITest at all. The `UITEST`-gated injection point must be built in Task 6, where the scanner's output is first handled — not retrofitted in Task 10. Phase 2b shipped swipe-to-remove permanently unautomatable for exactly this reason.

---

### Task 1: Migration `0017` — invoice tables, RLS, and the purchases link

**Files:**
- Create: `supabase/migrations/0017_invoice_capture.sql`
- Create: `tests/test_invoices.py`

**Interfaces:**
- Consumes: `locations`, `purchases`, `current_user_memberships()`, and the `0012` business-table policy pattern.
- Produces: tables `invoices` and `invoice_pages` carrying the standard sync columns (`client_mutated_at timestamptz NOT NULL`, `server_seq bigint`, `updated_at timestamptz`, `deleted_at timestamptz`, `created_at timestamptz`); unique index `invoice_pages_live_uq` on `(invoice_id, page_no) WHERE deleted_at IS NULL`; column `purchases.invoice_page_id uuid NULL`.

**Why invoices follow the `purchases` policy shape, not the `recipes` one:** `recipes` restricts writes to `role IN ('owner','manager')`, but photographing a delivery is data entry, exactly like recording a purchase — and a bookkeeper can already insert purchases. Gating capture to managers would mean the person receiving the delivery cannot photograph it.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_invoices.py
"""Phase 3a invoice capture: schema shape, the live-only page unique, the
purchases link, and org isolation on the two new tables."""
import pytest
from tests.conftest import apply_migrations
from tests.factories import (
    make_user, make_org, add_member, make_location, make_ingredient)
from api.db import pool_open, tenant_connection


def app_url(url):
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def actors(raw_conn):
    await apply_migrations(raw_conn)
    alice = await make_user(raw_conn, "alice@acme.test")     # owner
    dave = await make_user(raw_conn, "dave@acme.test")       # bookkeeper
    bob = await make_user(raw_conn, "bob@bistro.test")       # other org
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    await add_member(raw_conn, alice, acme, "owner")
    await add_member(raw_conn, dave, acme, "bookkeeper")
    await add_member(raw_conn, bob, bistro, "owner")
    loc = await make_location(raw_conn, acme, "Acme Main")
    b_loc = await make_location(raw_conn, bistro, "Bistro Main")
    ing = await make_ingredient(raw_conn, loc, "Chicken Breast")
    await raw_conn.commit()
    return dict(alice=alice, dave=dave, bob=bob, acme=acme,
                loc=loc, b_loc=b_loc, ing=ing)


@pytest.fixture
async def pool(db_url, actors):
    p = await pool_open(app_url(db_url))
    try:
        yield p
    finally:
        await p.close()


async def _mint_invoice(conn, loc):
    cur = await conn.execute(
        "INSERT INTO invoices (location_id, captured_at, client_mutated_at)"
        " VALUES (%s, now(), now()) RETURNING id", (loc,))
    return (await cur.fetchone())[0]


async def _mint_page(conn, inv, loc, page_no=1):
    cur = await conn.execute(
        "INSERT INTO invoice_pages (invoice_id, location_id, page_no,"
        " storage_path, client_mutated_at)"
        " VALUES (%s, %s, %s, 'org/inv/1.jpg', now()) RETURNING id",
        (inv, loc, page_no))
    return (await cur.fetchone())[0]


async def test_retake_reuses_page_no_after_tombstone(raw_conn, actors):
    """The unique must be LIVE-ONLY, exactly like recipe_items_live_uq: a
    full unique would make a retake impossible without renumbering pages."""
    inv = await _mint_invoice(raw_conn, actors["loc"])
    first = await _mint_page(raw_conn, inv, actors["loc"])
    await raw_conn.execute(
        "UPDATE invoice_pages SET deleted_at = now() WHERE id = %s", (first,))

    await _mint_page(raw_conn, inv, actors["loc"])  # the retake

    cur = await raw_conn.execute(
        "SELECT count(*) FROM invoice_pages"
        " WHERE invoice_id = %s AND deleted_at IS NULL", (inv,))
    assert (await cur.fetchone())[0] == 1


async def test_two_live_pages_with_the_same_page_no_are_refused(raw_conn, actors):
    inv = await _mint_invoice(raw_conn, actors["loc"])
    await _mint_page(raw_conn, inv, actors["loc"])
    with pytest.raises(Exception) as exc:
        await _mint_page(raw_conn, inv, actors["loc"])
    assert "invoice_pages_live_uq" in str(exc.value)


async def test_deleting_a_page_leaves_its_purchase(raw_conn, actors):
    """ON DELETE SET NULL, not CASCADE: a purchase records a real cost the
    business incurred, and deleting the photograph must not delete it."""
    inv = await _mint_invoice(raw_conn, actors["loc"])
    page = await _mint_page(raw_conn, inv, actors["loc"])
    cur = await raw_conn.execute(
        "INSERT INTO purchases (location_id, ingredient_id, purchased_on, qty,"
        " unit, qty_base_units, total_price, invoice_page_id)"
        " VALUES (%s, %s, '2026-01-01', 1, 'lb', 1, 5.00, %s) RETURNING id",
        (actors["loc"], actors["ing"], page))
    pur = (await cur.fetchone())[0]

    await raw_conn.execute("DELETE FROM invoice_pages WHERE id = %s", (page,))

    cur = await raw_conn.execute(
        "SELECT total_price, invoice_page_id FROM purchases WHERE id = %s", (pur,))
    row = await cur.fetchone()
    assert row[0] is not None
    assert row[1] is None


async def test_bookkeeper_can_capture_an_invoice(pool, actors):
    """Photographing a delivery is data entry, like recording a purchase --
    gating it to managers would stop the person receiving the delivery."""
    async with tenant_connection(pool, {"sub": str(actors["dave"])}) as conn:
        await conn.execute(
            "INSERT INTO invoices (location_id, captured_at, client_mutated_at)"
            " VALUES (%s, now(), now())", (actors["loc"],))


async def test_cross_org_sees_no_invoices(pool, actors, raw_conn):
    inv = await _mint_invoice(raw_conn, actors["loc"])
    await _mint_page(raw_conn, inv, actors["loc"])
    await raw_conn.commit()
    async with tenant_connection(pool, {"sub": str(actors["bob"])}) as conn:
        for t in ("invoices", "invoice_pages"):
            cur = await conn.execute(f"SELECT count(*) FROM {t}")
            assert (await cur.fetchone())[0] == 0, f"{t} leaked cross-org"


async def test_cross_org_invoice_insert_blocked_by_with_check(pool, actors):
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(actors["bob"])}) as conn:
            await conn.execute(
                "INSERT INTO invoices (location_id, captured_at, client_mutated_at)"
                " VALUES (%s, now(), now())", (actors["loc"],))
    assert "row-level security" in str(exc.value).lower()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_invoices.py -v`
Expected: FAIL — `psycopg.errors.UndefinedTable: relation "invoices" does not exist`

- [ ] **Step 3: Write the migration**

```sql
-- supabase/migrations/0017_invoice_capture.sql
-- Phase 3a: invoice capture. invoice_line_items is deliberately NOT created
-- here -- nothing in 3a reads or writes it, and shipping an unexercised
-- table is how schemas rot (spec 3a-D3).

CREATE TABLE invoices (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  location_id       uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  captured_at       timestamptz NOT NULL,
  -- Only the two values 3a can actually produce. 3b widens this alongside
  -- the parser that can set the rest: a value no code path reaches is a
  -- value nothing tests.
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
CREATE INDEX invoice_pages_invoice_deleted_idx
  ON invoice_pages (invoice_id, deleted_at);

-- SET NULL, not CASCADE: deleting the photograph must not delete the cost.
ALTER TABLE purchases
  ADD COLUMN invoice_page_id uuid REFERENCES invoice_pages(id) ON DELETE SET NULL;

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice_pages ENABLE ROW LEVEL SECURITY;

-- Shaped after purchases, NOT recipes: capture is data entry, so every
-- member of the org may do it, bookkeepers included.
CREATE POLICY invoice_select ON invoices FOR SELECT TO authenticated USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
CREATE POLICY invoice_write ON invoices FOR ALL TO authenticated
USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
)
WITH CHECK (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);

CREATE POLICY invoice_page_select ON invoice_pages FOR SELECT TO authenticated USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
CREATE POLICY invoice_page_write ON invoice_pages FOR ALL TO authenticated
USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
)
WITH CHECK (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_invoices.py -v`
Expected: PASS, 7 tests

- [ ] **Step 5: Run the full backend suite — the new column touches `purchases`**

Run: `uv run pytest -q`
Expected: PASS, 1451 or more. A failure here means an existing test asserts `purchases`' exact column set (check `tests/test_business_schema.py`); update that assertion, not the migration.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0017_invoice_capture.sql tests/test_invoices.py
git commit -m "feat(3a): invoice and invoice_pages tables, RLS, and the purchases link"
```

---

### Task 2: Sync table config and the `TABLE_ORDER` reorder

**Files:**
- Modify: `api/services/sync.py:23-40`
- Modify: `tests/test_sync_service.py`

**Interfaces:**
- Consumes: Task 1's tables.
- Produces: `TABLE_ORDER == ("ingredients", "recipes", "recipe_items", "invoices", "invoice_pages", "purchases")`; `INSERT_FIELDS["invoices"] == {"captured_at", "parse_status", "deleted_at"}`; `INSERT_FIELDS["invoice_pages"] == {"invoice_id", "page_no", "storage_path", "width", "height", "sha256", "deleted_at"}`; `INSERT_FIELDS["purchases"]` additionally contains `"invoice_page_id"`; `UPDATE_FIELDS["invoices"] == {"parse_status", "deleted_at"}`; `UPDATE_FIELDS["invoice_pages"] == {"storage_path", "width", "height", "sha256", "deleted_at"}`; `_PARENT_CHECKS["invoice_pages"] == (("invoice_id", "invoices", "invoice"),)`.

**The reorder is the risk, not the additions.** `purchases` moves from second to last because it now has an `invoice_pages` FK. Every prior phase's batch-apply depends on this tuple, so the test below asserts the ordering property directly rather than trusting that existing tests would notice.

- [ ] **Step 1: Write the failing test**

```python
# append to tests/test_sync_service.py
from api.services.sync import TABLE_ORDER, INSERT_FIELDS, UPDATE_FIELDS


def test_table_order_is_a_valid_fk_topological_sort():
    """Every table must appear after every table it references. Asserted as
    a property, not as a literal tuple, so a future table cannot be appended
    blindly into a position that breaks the apply path."""
    references = {
        "recipe_items": {"recipes", "ingredients"},
        "purchases": {"ingredients", "invoice_pages"},
        "invoice_pages": {"invoices"},
        "invoices": set(),
        "recipes": set(),
        "ingredients": set(),
    }
    position = {t: i for i, t in enumerate(TABLE_ORDER)}
    assert set(position) == set(references), "TABLE_ORDER and the FK map disagree"
    for table, parents in references.items():
        for parent in parents:
            assert position[parent] < position[table], (
                f"{table} applies before its parent {parent}")


def test_purchases_applies_after_invoice_pages():
    """The specific regression the 3a reorder introduces: a batch carrying a
    purchase AND the page it points at must apply the page first."""
    assert TABLE_ORDER.index("invoice_pages") < TABLE_ORDER.index("purchases")


def test_invoice_field_allowlists_exclude_identity_and_server_owned_columns():
    assert "location_id" not in INSERT_FIELDS["invoices"]
    assert "server_seq" not in INSERT_FIELDS["invoices"]
    # invoice_id and page_no identify the page; repointing is not sync's job.
    assert "invoice_id" not in UPDATE_FIELDS["invoice_pages"]
    assert "page_no" not in UPDATE_FIELDS["invoice_pages"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_sync_service.py -k "table_order or invoice_field" -v`
Expected: FAIL — `AssertionError: TABLE_ORDER and the FK map disagree` (the tuple still lacks both invoice tables)

- [ ] **Step 3: Update the table config**

```python
# api/services/sync.py, replacing lines 23-40
TABLE_ORDER = ("ingredients", "recipes", "recipe_items",
               "invoices", "invoice_pages", "purchases")  # §5.5 FK order
# purchases moved LAST in 3a: it gained an invoice_pages FK, so a batch
# carrying both must apply the page first.

INSERT_FIELDS = {
    "ingredients": {"name", "base_unit", "vendor", "category", "source", "deleted_at"},
    "recipes": {"name", "menu_price", "target_fc_pct", "deleted_at"},
    "recipe_items": {"recipe_id", "ingredient_id", "qty_base_units", "deleted_at"},
    "invoices": {"captured_at", "parse_status", "deleted_at"},
    "invoice_pages": {"invoice_id", "page_no", "storage_path", "width", "height",
                      "sha256", "deleted_at"},
    "purchases": {"ingredient_id", "purchased_on", "recorded_at", "qty", "unit",
                  "qty_in_case", "qty_base_units", "total_price", "source",
                  "invoice_page_id", "deleted_at"},
}
UPDATE_FIELDS = {  # identity fields immutable: repointing is merge's job, never sync's
    "ingredients": {"name", "base_unit", "vendor", "category", "deleted_at"},
    "recipes": {"name", "menu_price", "target_fc_pct", "deleted_at"},
    "recipe_items": {"qty_base_units", "deleted_at"},
    "invoices": {"parse_status", "deleted_at"},
    # storage_path/sha256/width/height are set by the confirm endpoint after
    # the bytes land, so they must be updatable; invoice_id/page_no are the
    # page's identity and never are.
    "invoice_pages": {"storage_path", "width", "height", "sha256", "deleted_at"},
    "purchases": {"purchased_on", "recorded_at", "qty", "unit", "qty_in_case",
                  "qty_base_units", "total_price", "invoice_page_id", "deleted_at"},
}

_PARENT_CHECKS = {
    "purchases": (("ingredient_id", "ingredients", "ingredient"),),
    "recipe_items": (
        ("recipe_id", "recipes", "recipe"),
        ("ingredient_id", "ingredients", "ingredient"),
    ),
    "invoice_pages": (("invoice_id", "invoices", "invoice"),),
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_sync_service.py -v`
Expected: PASS

- [ ] **Step 5: Run every sync test — this changed a shared constant**

Run: `uv run pytest tests/test_sync_pull.py tests/test_sync_push.py tests/test_sync_scenarios.py tests/test_sync_ops_rls.py -q`
Expected: PASS. A failure naming a table order or a pull-page sequence is a real regression from the reorder, not a stale assertion — investigate before editing the test.

- [ ] **Step 6: Commit**

```bash
git add api/services/sync.py tests/test_sync_service.py
git commit -m "feat(3a): sync the invoice tables; purchases applies last for its new FK"
```

---

### Task 3: Upload-URL and confirm endpoints

**Files:**
- Create: `api/routes/invoices.py`
- Modify: `api/main.py`
- Modify: `tests/test_invoices.py`

**Interfaces:**
- Consumes: Task 1's tables.
- Produces: `POST /invoices/{invoice_id}/pages/{page_no}/upload-url` → `{"url": str, "storage_path": str, "expires_at": str}`; `POST /invoices/{invoice_id}/pages/{page_no}/confirm` with body `{"sha256": str, "width": int, "height": int}` → `204`. Both 404 on an invoice outside the caller's orgs, and 409 when a supplied `storage_path` disagrees with the server's derivation.
- Path derivation, which Task 4's Swift `StoragePath` must reproduce exactly: `f"{org_id}/{invoice_id}/{page_no}.jpg"` — lowercase UUIDs, no zero-padding on `page_no`, always the `.jpg` extension.

- [ ] **Step 1: Write the failing test**

```python
# append to tests/test_invoices.py

async def test_upload_url_path_is_org_invoice_page_jpg(app_client, actors, raw_conn):
    inv = await _mint_invoice(raw_conn, actors["loc"])
    await raw_conn.commit()
    r = await app_client.post(
        f"/invoices/{inv}/pages/2/upload-url",
        headers=auth_headers(actors["alice"]))
    assert r.status_code == 200
    body = r.json()
    assert body["storage_path"] == f"{actors['acme']}/{inv}/2.jpg"
    assert body["url"].startswith("http")


async def test_upload_url_404s_for_another_orgs_invoice(app_client, actors, raw_conn):
    inv = await _mint_invoice(raw_conn, actors["loc"])
    await raw_conn.commit()
    r = await app_client.post(
        f"/invoices/{inv}/pages/1/upload-url",
        headers=auth_headers(actors["bob"]))
    assert r.status_code == 404


async def test_confirm_records_sha_and_dimensions(app_client, actors, raw_conn):
    inv = await _mint_invoice(raw_conn, actors["loc"])
    page = await _mint_page(raw_conn, inv, actors["loc"])
    await raw_conn.commit()

    r = await app_client.post(
        f"/invoices/{inv}/pages/1/confirm",
        json={"sha256": "a" * 64, "width": 1700, "height": 2200},
        headers=auth_headers(actors["alice"]))
    assert r.status_code == 204

    cur = await raw_conn.execute(
        "SELECT sha256, width, height FROM invoice_pages WHERE id = %s", (page,))
    assert await cur.fetchone() == ("a" * 64, 1700, 2200)


async def test_confirm_404s_for_a_page_that_does_not_exist(app_client, actors, raw_conn):
    """Confirm exists precisely so the server records that bytes arrived; a
    confirm for a page it has never seen must not silently succeed."""
    inv = await _mint_invoice(raw_conn, actors["loc"])
    await raw_conn.commit()
    r = await app_client.post(
        f"/invoices/{inv}/pages/9/confirm",
        json={"sha256": "b" * 64, "width": 10, "height": 10},
        headers=auth_headers(actors["alice"]))
    assert r.status_code == 404
```

Add the helper the tests above use, next to `app_url` at the top of the file. Copy its body from whichever existing route test already builds a bearer token (`tests/test_purchases_routes.py` has one); do not invent a new token shape:

```python
def auth_headers(user_id):
    """Same bearer-token construction the other route tests use."""
    from tests.test_purchases_routes import auth_headers as _shared
    return _shared(user_id)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_invoices.py -k "upload_url or confirm" -v`
Expected: FAIL — 404 from the app for every case, because the router does not exist yet

- [ ] **Step 3: Write the router**

```python
# api/routes/invoices.py
"""Phase 3a: pre-signed page uploads and their confirmation.

Two endpoints rather than one. A pre-signed PUT succeeding tells the CLIENT
the bytes arrived but leaves the server with no record that they did --
without confirm, storage_path is a claim nobody checked, and 3b's parse
worker would dispatch against pages that may not exist.
"""
from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field

from api.db import tenant_connection
from api.deps import current_claims, pool

router = APIRouter(prefix="/invoices", tags=["invoices"])


def storage_path(org_id: str, invoice_id: str, page_no: int) -> str:
    """The one definition of the key. CostSauceKit's StoragePath.swift
    (Task 4) reproduces this exactly and is pinned against it by a shared
    vector; changing either side alone silently orphans uploads."""
    return f"{org_id}/{invoice_id}/{page_no}.jpg"


class ConfirmBody(BaseModel):
    sha256: str = Field(min_length=64, max_length=64)
    width: int = Field(gt=0)
    height: int = Field(gt=0)


async def _invoice_org(conn, invoice_id: str) -> str:
    """The invoice's org, or 404. RLS already hides other orgs' invoices, so
    a miss here is either genuinely absent or not ours -- both are 404, and
    distinguishing them would leak existence across orgs."""
    cur = await conn.execute(
        "SELECT l.org_id FROM invoices i JOIN locations l ON l.id = i.location_id"
        " WHERE i.id = %s AND i.deleted_at IS NULL", (invoice_id,))
    row = await cur.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="invoice not found")
    return str(row[0])


@router.post("/{invoice_id}/pages/{page_no}/upload-url")
async def mint_upload_url(invoice_id: str, page_no: int,
                          claims=Depends(current_claims), p=Depends(pool)):
    if page_no < 1:
        raise HTTPException(status_code=422, detail="page_no must be positive")
    async with tenant_connection(p, claims) as conn:
        org_id = await _invoice_org(conn, invoice_id)
    path = storage_path(org_id, invoice_id, page_no)
    url, expires_at = await sign_put(path)
    return {"url": url, "storage_path": path, "expires_at": expires_at}


@router.post("/{invoice_id}/pages/{page_no}/confirm", status_code=204)
async def confirm_upload(invoice_id: str, page_no: int, body: ConfirmBody,
                         claims=Depends(current_claims), p=Depends(pool)):
    async with tenant_connection(p, claims) as conn:
        await _invoice_org(conn, invoice_id)
        cur = await conn.execute(
            "UPDATE invoice_pages SET sha256 = %s, width = %s, height = %s,"
            " updated_at = now()"
            " WHERE invoice_id = %s AND page_no = %s AND deleted_at IS NULL"
            " RETURNING id",
            (body.sha256, body.width, body.height, invoice_id, page_no))
        if await cur.fetchone() is None:
            raise HTTPException(status_code=404, detail="page not found")
    return Response(status_code=204)
```

- [ ] **Step 4: Write the signing call**

Nothing in the codebase talks to Supabase Storage yet, so this is new and
belongs to this task. Supabase mints an upload token via
`POST /storage/v1/object/upload/sign/{bucket}/{path}` with the service-role
key, returning `{"url": "/object/upload/sign/<bucket>/<path>?token=..."}` —
a relative path that must be joined onto the storage origin before it is
usable by a client.

```python
# api/routes/invoices.py -- above the router definition
import os
from datetime import datetime, timedelta, timezone

import httpx

BUCKET = "invoices"
UPLOAD_URL_TTL_SECONDS = 3600


async def sign_put(path: str) -> tuple[str, str]:
    """A pre-signed upload URL for `path`, and when it expires.

    Service-role, never the anon key: this signs a write into a PRIVATE
    bucket, and the anon key cannot. The token is scoped to this exact
    object path, so it grants nothing beyond the one page it was minted for.

    Minted per attempt rather than cached -- the client uploads over a
    background session that may not run until hours later (a phone that left
    the building), by which point a cached URL has expired.
    """
    base = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.post(
            f"{base}/storage/v1/object/upload/sign/{BUCKET}/{path}",
            headers={"Authorization": f"Bearer {key}"},
            json={"expiresIn": UPLOAD_URL_TTL_SECONDS},
        )
    if response.status_code != 200:
        raise HTTPException(
            status_code=502, detail="could not sign the upload URL")
    signed = response.json()["url"]
    expires_at = (
        datetime.now(timezone.utc) + timedelta(seconds=UPLOAD_URL_TTL_SECONDS)
    ).isoformat()
    return f"{base}/storage/v1{signed}", expires_at
```

The bucket itself is created once, out of band, as a **private** bucket named
`invoices`. Record that in the Task 10 runbook as a deployment prerequisite —
it is not created by a migration, so a fresh environment silently 502s on
every upload until someone makes it.

For the tests, monkeypatch `sign_put` to return a fixed
`("https://storage.test/put/abc", "2026-08-03T12:00:00+00:00")` rather than
reaching a real Supabase — these tests assert this API's behaviour, not
Supabase's.

- [ ] **Step 5: Register the router**

```python
# api/main.py -- beside the existing router registrations
from api.routes import invoices
app.include_router(invoices.router)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `uv run pytest tests/test_invoices.py -v`
Expected: PASS, 11 tests

- [ ] **Step 7: Commit**

```bash
git add api/routes/invoices.py api/main.py tests/test_invoices.py
git commit -m "feat(3a): pre-signed page upload URLs and their confirmation"
```

---

### Task 4: Kit schema, records, and `StoragePath`

**Files:**
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Store/Schema.swift`
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Store/Records.swift`
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Store/LocalStore.swift`
- Create: `ios/CostSauceKit/Sources/CostSauceKit/Store/StoragePath.swift`
- Create: `ios/CostSauceKit/Tests/CostSauceKitTests/StoragePathTests.swift`
- Modify: `ios/CostSauceKit/Tests/CostSauceKitTests/StoreTests.swift`

**Interfaces:**
- Consumes: Task 3's `storage_path` definition.
- Produces: `StoragePath.forPage(orgId:invoiceId:pageNo:) -> String`; records `LocalInvoice(id:location_id:captured_at:parse_status:client_mutated_at:server_seq:updated_at:deleted_at:created_at:)`, `LocalInvoicePage(id:invoice_id:location_id:page_no:storage_path:width:height:sha256:client_mutated_at:server_seq:updated_at:deleted_at:created_at:)` (all columns `String`/`String?` except `server_seq: Int64`, per Global Constraints — `page_no`, `width`, `height` are TEXT locally), and `PendingUpload(page_id:local_path:state:attempts:last_error:created_at:)`.
- Also produces the upload-queue store accessors, because they belong with the table this task creates and **Task 6 calls `enqueueUpload` before Task 7 exists**: `LocalStore.enqueueUpload(pageId:localPath:now:) throws`, `LocalStore.pendingUploads() throws -> [PendingUpload]`, `LocalStore.updateUpload(_ upload: PendingUpload) throws`, `LocalStore.pendingUploadCount() throws -> Int`.
- `LocalStore.knownTables` gains both table names.

**Four dispatch points must all be updated, or the failure is silent:** `knownTables` (`LocalStore.swift:22`), `upsert` (`:137`), `insertStub` (`:219`), and the wipe (`:442-445`). A missed `insertStub` case throws `unknownTable` only when an offline insert is first enqueued — not at build time.

- [ ] **Step 1: Write the failing test**

```swift
// ios/CostSauceKit/Tests/CostSauceKitTests/StoragePathTests.swift
import Testing
@testable import CostSauceKit

@Suite struct StoragePathTests {

    /// Pinned against api/routes/invoices.py's `storage_path`. These two
    /// definitions must agree byte for byte: the client mints the key and
    /// the server refuses one that disagrees, so a divergence here does not
    /// fail loudly -- it orphans every upload.
    @Test func matchesTheServersDerivation() {
        #expect(StoragePath.forPage(
            orgId: "019fc76f-45b6-7547-83b2-f95775ad2c81",
            invoiceId: "019fc770-0000-7000-8000-000000000001",
            pageNo: 2
        ) == "019fc76f-45b6-7547-83b2-f95775ad2c81/019fc770-0000-7000-8000-000000000001/2.jpg")
    }

    /// No zero-padding: the server writes `f"{page_no}.jpg"`, so page 10
    /// is "10.jpg" and never "010.jpg".
    @Test func pageNumberIsNotZeroPadded() {
        let path = StoragePath.forPage(orgId: "o", invoiceId: "i", pageNo: 10)
        #expect(path == "o/i/10.jpg")
    }

    /// Deterministic: the same page always derives the same key, which is
    /// what makes an upload retry overwrite instead of duplicate.
    @Test func isDeterministicAcrossCalls() {
        let a = StoragePath.forPage(orgId: "o", invoiceId: "i", pageNo: 1)
        let b = StoragePath.forPage(orgId: "o", invoiceId: "i", pageNo: 1)
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/CostSauceKit && swift test --filter StoragePathTests`
Expected: FAIL to build — `cannot find 'StoragePath' in scope`

- [ ] **Step 3: Write `StoragePath`**

```swift
// ios/CostSauceKit/Sources/CostSauceKit/Store/StoragePath.swift
// The storage key for an invoice page, derived rather than stored.
//
// Its own file, and its own test suite, because this is a CONTRACT with
// api/routes/invoices.py's `storage_path()`. The client mints the key (spec
// §4: a deterministic function of the client-minted invoice UUID plus page
// number is what makes a retry overwrite rather than duplicate) and the
// server refuses one that disagrees with its own derivation. A divergence
// therefore never surfaces as a crash -- it surfaces as uploads landing
// nowhere anything reads.

public enum StoragePath {
    /// `{org_id}/{invoice_uuid}/{page_no}.jpg` -- lowercase UUIDs exactly as
    /// minted, no zero-padding on the page number, always `.jpg`.
    public static func forPage(orgId: String, invoiceId: String, pageNo: Int) -> String {
        "\(orgId)/\(invoiceId)/\(pageNo).jpg"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/CostSauceKit && swift test --filter StoragePathTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Add the schema migration**

```swift
// ios/CostSauceKit/Sources/CostSauceKit/Store/Schema.swift
// Inside `migrator`, AFTER the existing registerMigration("v1") block.
//
// A second migration rather than an edit to "v1": v1 has shipped, and GRDB
// records which migrations ran. Editing it would leave every existing
// install without these tables.
migrator.registerMigration("v2") { db in
    try db.execute(sql: """
        CREATE TABLE invoices (
            id TEXT PRIMARY KEY,
            location_id TEXT NOT NULL,
            captured_at TEXT NOT NULL,
            parse_status TEXT NOT NULL,
            client_mutated_at TEXT NOT NULL,
            server_seq INTEGER NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            created_at TEXT NOT NULL
        )
        """)

    try db.execute(sql: """
        CREATE TABLE invoice_pages (
            id TEXT PRIMARY KEY,
            invoice_id TEXT NOT NULL,
            location_id TEXT NOT NULL,
            page_no TEXT NOT NULL,
            storage_path TEXT NOT NULL,
            width TEXT,
            height TEXT,
            sha256 TEXT,
            client_mutated_at TEXT NOT NULL,
            server_seq INTEGER NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            created_at TEXT NOT NULL
        )
        """)
    try db.execute(sql: """
        CREATE INDEX invoice_pages_invoice_deleted_idx
            ON invoice_pages(invoice_id, deleted_at)
        """)

    // Local-only, like pending_ops: the upload outbox (spec 3a-D2). Never
    // synced, never pushed -- it tracks bytes, not rows.
    try db.execute(sql: """
        CREATE TABLE pending_uploads (
            page_id TEXT PRIMARY KEY,
            local_path TEXT NOT NULL,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL,
            last_error TEXT,
            created_at TEXT NOT NULL
        )
        """)
    try db.execute(sql: """
        CREATE INDEX pending_uploads_state_idx ON pending_uploads(state)
        """)

    try db.execute(sql: "ALTER TABLE purchases ADD COLUMN invoice_page_id TEXT")
}
```

- [ ] **Step 6: Add the records**

```swift
// ios/CostSauceKit/Sources/CostSauceKit/Store/Records.swift -- append

// MARK: - invoices

public struct LocalInvoice: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "invoices"

    public var id: String
    public var location_id: String
    public var captured_at: String
    public var parse_status: String
    public var client_mutated_at: String
    public var server_seq: Int64
    public var updated_at: String
    public var deleted_at: String?
    public var created_at: String

    public init(
        id: String, location_id: String, captured_at: String, parse_status: String,
        client_mutated_at: String, server_seq: Int64, updated_at: String,
        deleted_at: String?, created_at: String
    ) {
        self.id = id
        self.location_id = location_id
        self.captured_at = captured_at
        self.parse_status = parse_status
        self.client_mutated_at = client_mutated_at
        self.server_seq = server_seq
        self.updated_at = updated_at
        self.deleted_at = deleted_at
        self.created_at = created_at
    }
}

// MARK: - invoice_pages

/// `page_no`, `width` and `height` are `String` here, not `Int`: every
/// synced column crosses this boundary as a verbatim string (this file's
/// header comment), and a page number is no exception.
public struct LocalInvoicePage: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "invoice_pages"

    public var id: String
    public var invoice_id: String
    public var location_id: String
    public var page_no: String
    public var storage_path: String
    public var width: String?
    public var height: String?
    public var sha256: String?
    public var client_mutated_at: String
    public var server_seq: Int64
    public var updated_at: String
    public var deleted_at: String?
    public var created_at: String

    public init(
        id: String, invoice_id: String, location_id: String, page_no: String,
        storage_path: String, width: String?, height: String?, sha256: String?,
        client_mutated_at: String, server_seq: Int64, updated_at: String,
        deleted_at: String?, created_at: String
    ) {
        self.id = id
        self.invoice_id = invoice_id
        self.location_id = location_id
        self.page_no = page_no
        self.storage_path = storage_path
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.client_mutated_at = client_mutated_at
        self.server_seq = server_seq
        self.updated_at = updated_at
        self.deleted_at = deleted_at
        self.created_at = created_at
    }
}

// MARK: - pending_uploads (local only, never synced)

public struct PendingUpload: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "pending_uploads"

    public enum State: String, Codable, Sendable {
        case queued
        case uploading
        case uploaded
        case failed
    }

    public var page_id: String
    public var local_path: String
    public var state: String
    public var attempts: Int
    public var last_error: String?
    public var created_at: String

    public init(
        page_id: String, local_path: String, state: State, attempts: Int,
        last_error: String?, created_at: String
    ) {
        self.page_id = page_id
        self.local_path = local_path
        self.state = state.rawValue
        self.attempts = attempts
        self.last_error = last_error
        self.created_at = created_at
    }
}
```

Add `invoice_page_id: String?` to `LocalPurchase` (declared property, init
parameter, and assignment) as the last stored-column property before
`client_mutated_at`. Its `fromPull` gains the same key.

- [ ] **Step 7: Update all four `LocalStore` dispatch points**

```swift
// LocalStore.swift:22 -- knownTables
private static let knownTables: Set<String> = [
    "ingredients", "recipes", "recipe_items", "invoices", "invoice_pages", "purchases",
]

// LocalStore.swift:137 -- upsert, add before the `default:` arm
case "invoices":
    try LocalInvoice.fromPull(change).save(db)
case "invoice_pages":
    try LocalInvoicePage.fromPull(change).save(db)

// LocalStore.swift:219 -- insertStub, add before the `default:` arm
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

// LocalStore.swift:442 -- the wipe, alongside the existing four
try db.execute(sql: "DELETE FROM invoices")
try db.execute(sql: "DELETE FROM invoice_pages")
try db.execute(sql: "DELETE FROM pending_uploads")
```

- [ ] **Step 8: Add a store test proving all four points are wired**

```swift
// append to StoreTests.swift

/// The four dispatch points fail SILENTLY if one is missed -- a forgotten
/// insertStub case throws only when an offline insert is first enqueued,
/// long after build time. This drives all four in one pass.
@Test func invoiceTablesAreWiredThroughEveryDispatchPoint() throws {
    let store = try LocalStore.inMemory()
    try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")

    // upsert (pull path)
    try store.applyPullPage([
        StoreTests.invoiceChange(id: "inv-1", serverSeq: 1),
        StoreTests.invoicePageChange(id: "pg-1", invoiceId: "inv-1", pageNo: "1", serverSeq: 2),
    ], cursor: 2)
    #expect(try store.liveInvoices().count == 1)

    // insertStub (offline insert path)
    try store.enqueue(PendingOp(
        op_id: "op-1", table: "invoices", row_id: "inv-2", location_id: "loc-1",
        client_mutated_at: "2026-08-03 10:00:00+00", kind: .insert,
        fields: ["captured_at": "2026-08-03 10:00:00+00", "parse_status": "unparsed"],
        state: .queued, reason: nil, created_at: "2026-08-03 10:00:00+00"))
    #expect(try store.liveInvoices().count == 2)

    // wipe
    try store.wipeSyncedData()
    #expect(try store.liveInvoices().isEmpty)
}
```

Add `invoiceChange` and `invoicePageChange` builders to `StoreTests` beside
the existing `recipeChange`/`recipeItemChange`, following their exact shape
(a `PullChange` with every column as a `SyncValue`, `deleted_at` defaulting
to `.null`). Add `LocalStore.liveInvoices()` returning
`SELECT * FROM invoices WHERE deleted_at IS NULL ORDER BY captured_at DESC, id`
— newest first, because an invoice list is read newest first, unlike the
name-ordered reads elsewhere.

- [ ] **Step 9: Run the full Kit suite**

Run: `cd ios/CostSauceKit && swift test`
Expected: PASS. Existing count is 171; this adds 4.

- [ ] **Step 10: Commit**

```bash
git add ios/CostSauceKit/Sources/CostSauceKit/Store ios/CostSauceKit/Tests
git commit -m "feat(3a): local invoice tables, records, and the storage-path contract"
```

---

### Task 5: `LocalEdits` invoice helpers and `SyncEngine` wiring

**Files:**
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Store/LocalEdits.swift`
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Sync/SyncEngine.swift`
- Modify: `ios/CostSauceKit/Tests/CostSauceKitTests/LocalEditsTests.swift`
- Modify: `ios/CostSauceKit/Tests/CostSauceKitTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: Task 4's records and `StoragePath`.
- Produces: `LocalEdits.createInvoice(now:) throws -> String`; `LocalEdits.addInvoicePage(invoiceId:pageNo:orgId:now:) throws -> (pageId: String, storagePath: String)`; `LocalEdits.tombstoneInvoice(id:now:) throws` (fan-out: every live page plus the invoice, one transaction, one timestamp — the same shape as `tombstoneRecipe`).

- [ ] **Step 1: Write the failing test**

```swift
// append to LocalEditsTests.swift

@Test func createInvoiceEnqueuesInsertWithCapturedAtAndUnparsedStatus() throws {
    let store = try seededStore([])
    let edits = LocalEdits(store: store, locationId: "loc-1")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let id = try edits.createInvoice(now: now)

    let op = try #require(try store.pendingOps(state: .queued).first { $0.row_id == id })
    #expect(op.table == "invoices")
    #expect(op.kind == .insert)
    #expect(Set(op.fields.keys) == ["captured_at", "parse_status"])
    #expect(fieldValue(op, "parse_status") == "unparsed")
    #expect(fieldValue(op, "captured_at") == Kernel.canonicalTimestamp(now))
}

@Test func addInvoicePageDerivesTheSameStoragePathTheServerWill() throws {
    let store = try seededStore([])
    let edits = LocalEdits(store: store, locationId: "loc-1")
    let invoiceId = try edits.createInvoice()

    let (pageId, path) = try edits.addInvoicePage(
        invoiceId: invoiceId, pageNo: 1, orgId: "org-1")

    #expect(path == StoragePath.forPage(orgId: "org-1", invoiceId: invoiceId, pageNo: 1))
    let op = try #require(try store.pendingOps(state: .queued).first { $0.row_id == pageId })
    #expect(op.table == "invoice_pages")
    #expect(Set(op.fields.keys) == ["invoice_id", "page_no", "storage_path"])
}

@Test func addInvoicePageOnTombstonedInvoiceThrowsAndEnqueuesNothing() throws {
    let store = try seededStore([])
    let edits = LocalEdits(store: store, locationId: "loc-1")
    let invoiceId = try edits.createInvoice()
    try edits.tombstoneInvoice(id: invoiceId)
    let before = try store.pendingCount()

    #expect(throws: KernelError.self) {
        _ = try edits.addInvoicePage(invoiceId: invoiceId, pageNo: 2, orgId: "org-1")
    }

    #expect(try store.pendingCount() == before)
}

@Test func tombstoneInvoiceFansOutToEveryLivePageInOneTransaction() throws {
    let store = try seededStore([])
    let edits = LocalEdits(store: store, locationId: "loc-1")
    let invoiceId = try edits.createInvoice()
    _ = try edits.addInvoicePage(invoiceId: invoiceId, pageNo: 1, orgId: "org-1")
    _ = try edits.addInvoicePage(invoiceId: invoiceId, pageNo: 2, orgId: "org-1")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    try edits.tombstoneInvoice(id: invoiceId, now: now)

    let stamp = Kernel.canonicalTimestamp(now)
    let tombstones = try store.pendingOps(state: .queued).filter {
        $0.kind == .update && ($0.fields["deleted_at"] ?? nil) == stamp
    }
    // Two pages plus the invoice itself, all sharing one timestamp.
    #expect(tombstones.count == 3)
    #expect(try store.livePages(invoiceId: invoiceId).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/CostSauceKit && swift test --filter "Invoice"`
Expected: FAIL to build — `value of type 'LocalEdits' has no member 'createInvoice'`

- [ ] **Step 3: Write the helpers**

```swift
// ios/CostSauceKit/Sources/CostSauceKit/Store/LocalEdits.swift -- append

/// Mirrors `POST /invoices`. `INSERT_FIELDS.invoices` is `{captured_at,
/// parse_status, deleted_at}`; this sends the first two. `parse_status` is
/// always "unparsed" from a device -- 'failed' is 3b's parser's to set, and
/// the schema CHECK admits no other value in 3a.
public func createInvoice(now: Date = Date()) throws -> String {
    let rowId = UUIDv7.generate(now: now)
    let opId = UUIDv7.generate(now: now)
    let mutatedAt = Kernel.canonicalTimestamp(now)
    try store.enqueue(PendingOp(
        op_id: opId, table: "invoices", row_id: rowId, location_id: locationId,
        client_mutated_at: mutatedAt, kind: .insert,
        fields: ["captured_at": mutatedAt, "parse_status": "unparsed"],
        state: .queued, reason: nil, created_at: mutatedAt))
    return rowId
}

/// Mirrors `POST /invoices/{id}/pages`. Returns the new page's row id AND
/// its storage path, because the caller needs the path immediately -- it is
/// where the JPEG is written and what the upload targets, both before any
/// network call (parent spec §12 step 3).
///
/// The invoice must be live, the same guard every other mutation here runs.
public func addInvoicePage(
    invoiceId: String, pageNo: Int, orgId: String, now: Date = Date()
) throws -> (pageId: String, storagePath: String) {
    guard let invoice = try store.invoice(id: invoiceId), invoice.deleted_at == nil else {
        throw KernelError("invoice is not live")
    }
    guard pageNo > 0 else {
        throw KernelError("page_no must be positive")
    }
    let path = StoragePath.forPage(orgId: orgId, invoiceId: invoiceId, pageNo: pageNo)
    let rowId = UUIDv7.generate(now: now)
    let opId = UUIDv7.generate(now: now)
    let mutatedAt = Kernel.canonicalTimestamp(now)
    try store.enqueue(PendingOp(
        op_id: opId, table: "invoice_pages", row_id: rowId, location_id: locationId,
        client_mutated_at: mutatedAt, kind: .insert,
        fields: ["invoice_id": invoiceId, "page_no": String(pageNo), "storage_path": path],
        state: .queued, reason: nil, created_at: mutatedAt))
    return (rowId, path)
}

/// One `deleted_at` update op per live page plus one for the invoice, all
/// sharing a single timestamp, in ONE transaction -- the same fan-out shape
/// as `tombstoneRecipe`.
public func tombstoneInvoice(id: String, now: Date = Date()) throws {
    guard let invoice = try store.invoice(id: id), invoice.deleted_at == nil else {
        throw KernelError("invoice is not live")
    }
    let mutatedAt = Kernel.canonicalTimestamp(now)
    let pages = try store.livePages(invoiceId: id)
    try store.enqueueAll(pages.map { page in
        PendingOp(
            op_id: UUIDv7.generate(now: now), table: "invoice_pages", row_id: page.id,
            location_id: locationId, client_mutated_at: mutatedAt, kind: .update,
            fields: ["deleted_at": mutatedAt],
            state: .queued, reason: nil, created_at: mutatedAt)
    } + [
        PendingOp(
            op_id: UUIDv7.generate(now: now), table: "invoices", row_id: id,
            location_id: locationId, client_mutated_at: mutatedAt, kind: .update,
            fields: ["deleted_at": mutatedAt],
            state: .queued, reason: nil, created_at: mutatedAt)
    ])
}
```

Add the two reads this needs to `LocalStore`, beside `recipe(id:)` and
`liveRecipeItems(recipeId:)`:

```swift
public func invoice(id: String) throws -> LocalInvoice? {
    try dbQueue.read { db in
        try LocalInvoice.fetchOne(db, sql: "SELECT * FROM invoices WHERE id = ?", arguments: [id])
    }
}

/// Ordered by page number, which is the order a human reads an invoice.
/// `page_no` is TEXT (Global Constraints), so `CAST(... AS INTEGER)` is
/// required -- a plain string sort puts page 10 before page 2.
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
```

`enqueueAll(_:)` is the existing batch helper `tombstoneRecipe` already uses;
if it is named differently there, use that name rather than adding a second.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/CostSauceKit && swift test --filter "Invoice"`
Expected: PASS, 4 tests

- [ ] **Step 5: Add the offline-convergence sync test**

```swift
// append to SyncEngineTests.swift

/// An invoice captured with no connectivity pushes on reconnect, and the
/// page arrives with its invoice -- the FK order Task 2 pinned, exercised
/// end to end through the engine rather than asserted on a constant.
@Test func invoiceCapturedOfflinePushesAndConverges() async throws {
    let (engine, store, server) = try makeEngineWithFakeServer()
    let edits = LocalEdits(store: store, locationId: "loc-1")
    let invoiceId = try edits.createInvoice()
    _ = try edits.addInvoicePage(invoiceId: invoiceId, pageNo: 1, orgId: "org-1")

    try await engine.syncNow()

    #expect(server.rows(table: "invoices").count == 1)
    #expect(server.rows(table: "invoice_pages").count == 1)
    #expect(try store.pendingOps(state: .queued).isEmpty)
}
```

Use whatever the file's existing engine-plus-`FakeSyncServer` construction
helper is called — do not add a second one. `FakeSyncServer` must accept the
two new tables; if it validates table names against a list, add them there.

- [ ] **Step 6: Run the full Kit suite**

Run: `cd ios/CostSauceKit && swift test`
Expected: PASS, 180

- [ ] **Step 7: Commit**

```bash
git add ios/CostSauceKit
git commit -m "feat(3a): LocalEdits invoice helpers and offline invoice convergence"
```

---

### Task 6: Capture UI, the quality gates, and the test seam

**Files:**
- Create: `ios/CostSauce/Views/InvoiceCaptureView.swift`
- Create: `ios/CostSauce/Capture/ScannedPageSource.swift`
- Create: `ios/CostSauceKit/Sources/CostSauceKit/Capture/PageQuality.swift`
- Create: `ios/CostSauceKit/Tests/CostSauceKitTests/PageQualityTests.swift`

**Interfaces:**
- Consumes: Task 5's `createInvoice` / `addInvoicePage`.
- Produces: `PageQuality.assess(width:height:laplacianVariance:) -> PageQuality.Verdict` where `Verdict` is `.accept` or `.retake(reason: String)`; `PageQuality.minimumLongEdge: Int` and `PageQuality.minimumSharpness: Double`; `PageQuality.laplacianVariance(of: CGImage) -> Double` (the Accelerate measurement, kept separate from the pure judgement so thresholds stay testable without an image); protocol `ScannedPageSource` with `func pages(presentingFrom: UIViewController) async -> [CGImage]`, implemented by `DocumentScannerSource` (real) and `FixturePageSource` (UITEST); `InvoiceFiles.write(_:invoiceId:pageNo:) throws -> String`.

**This task carries the acceptance test's only viable seam.** `VNDocumentCameraViewController` cannot run in the simulator — there is no camera — so if capture reaches the scanner directly, Task 10's walk is impossible and 3a ships with its central flow unautomatable, exactly as 2b did with swipe-to-remove. `InvoiceCaptureView` therefore depends on the `ScannedPageSource` protocol, never on VisionKit directly, and `AppModel` picks the implementation from the `UITEST` environment variable it already reads.

**Setting the two thresholds is part of this task, and must be recorded.** The spec deliberately gives no values: a sharpness cutoff picked from intuition either passes blurry pages or rejects good ones. Calibrate against real photographs — if Travis's bad-photo fixture set (which gates 3b) has arrived, use it; otherwise photograph a handful of invoices deliberately badly. Write the chosen numbers and the sample they came from into `PageQuality`'s doc comment. A threshold with no recorded provenance cannot be re-tuned by anyone later.

The variance-of-Laplacian is computed on a grayscale downscale of the page and is plain image processing, never text recognition — the parent spec's D4 bars on-device OCR, not on-device image statistics.

- [ ] **Step 1: Write the failing test**

```swift
// ios/CostSauceKit/Tests/CostSauceKitTests/PageQualityTests.swift
import Testing
@testable import CostSauceKit

@Suite struct PageQualityTests {

    @Test func acceptsASharpFullResolutionPage() {
        let verdict = PageQuality.assess(
            width: 1700, height: 2200,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        #expect(verdict == .accept)
    }

    /// Long edge, not width: an invoice photographed in landscape is still
    /// the same number of pixels across its longest dimension.
    @Test func measuresTheLongEdgeRegardlessOfOrientation() {
        let portrait = PageQuality.assess(
            width: 100, height: PageQuality.minimumLongEdge,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        let landscape = PageQuality.assess(
            width: PageQuality.minimumLongEdge, height: 100,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        #expect(portrait == .accept)
        #expect(landscape == .accept)
    }

    @Test func refusesAPageBelowTheResolutionFloor() {
        let verdict = PageQuality.assess(
            width: PageQuality.minimumLongEdge - 1,
            height: PageQuality.minimumLongEdge - 1,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        #expect(verdict != .accept)
    }

    @Test func refusesABlurryPage() {
        let verdict = PageQuality.assess(
            width: 1700, height: 2200,
            laplacianVariance: PageQuality.minimumSharpness - 0.01)
        #expect(verdict != .accept)
    }

    /// The reason is shown to a cook holding a phone over a delivery, so it
    /// has to say which problem to fix -- "retake" alone is useless when the
    /// page is sharp but too small, or large but blurred.
    @Test func namesWhichGateFailed() {
        guard case .retake(let blurReason) = PageQuality.assess(
            width: 1700, height: 2200,
            laplacianVariance: PageQuality.minimumSharpness - 0.01)
        else { Issue.record("expected a retake verdict"); return }
        #expect(blurReason.lowercased().contains("blur"))

        guard case .retake(let sizeReason) = PageQuality.assess(
            width: 10, height: 10,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        else { Issue.record("expected a retake verdict"); return }
        #expect(sizeReason.lowercased().contains("close"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/CostSauceKit && swift test --filter PageQualityTests`
Expected: FAIL to build — `cannot find 'PageQuality' in scope`

- [ ] **Step 3: Write `PageQuality`**

```swift
// ios/CostSauceKit/Sources/CostSauceKit/Capture/PageQuality.swift
// The two gates a scanned page must pass before it is accepted (parent spec
// §12 step 2). Pure arithmetic over measurements the caller supplies, so it
// is testable without an image, a camera, or a simulator.
//
// This is image STATISTICS, not text recognition: the parent spec's D4 bars
// on-device OCR and nothing else. The caller computes the variance of the
// Laplacian over a grayscale downscale (Accelerate) and passes the number in.

import Foundation

public enum PageQuality: Equatable {

    public enum Verdict: Equatable {
        case accept
        case retake(reason: String)
    }

    /// CALIBRATION: replace both numbers, and this note, with the values you
    /// measured and the sample you measured them against, before this task is
    /// considered done. A threshold whose provenance is not written down
    /// cannot be re-tuned by anyone later -- they will not know whether it
    /// was measured or guessed.
    public static let minimumLongEdge: Int = 1600
    public static let minimumSharpness: Double = 100.0

    public static func assess(
        width: Int, height: Int, laplacianVariance: Double
    ) -> Verdict {
        // Long edge, not width: a landscape invoice has the same detail.
        guard max(width, height) >= minimumLongEdge else {
            return .retake(reason: "Move closer — this page is too small to read.")
        }
        guard laplacianVariance >= minimumSharpness else {
            return .retake(reason: "That came out blurry — hold still and try again.")
        }
        return .accept
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/CostSauceKit && swift test --filter PageQualityTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Write the page source and its fixture twin**

```swift
// ios/CostSauce/Capture/ScannedPageSource.swift
// Capture's seam. InvoiceCaptureView depends on THIS, never on VisionKit
// directly, because VNDocumentCameraViewController cannot run in the
// simulator -- there is no camera. Without this protocol the acceptance
// walk in Task 10 is impossible to write, and 3a would ship its central
// flow permanently unautomatable, exactly as Phase 2b shipped
// swipe-to-remove.

import CoreGraphics
import UIKit
import VisionKit

@MainActor
protocol ScannedPageSource {
    /// The scanned pages, in order, or an empty array if the user cancelled.
    func pages(presentingFrom presenter: UIViewController) async -> [CGImage]
}

@MainActor
struct DocumentScannerSource: ScannedPageSource {
    func pages(presentingFrom presenter: UIViewController) async -> [CGImage] {
        await withCheckedContinuation { continuation in
            let controller = VNDocumentCameraViewController()
            let delegate = ScannerDelegate(continuation: continuation)
            controller.delegate = delegate
            // The delegate is retained by the controller's coordinator box
            // below; VNDocumentCameraViewController does not retain it.
            objc_setAssociatedObject(
                controller, &ScannerDelegate.associationKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            presenter.present(controller, animated: true)
        }
    }
}

/// Supplies fixture pages where the scanner's output would land, so the
/// whole capture -> upload -> entry walk runs headless.
@MainActor
struct FixturePageSource: ScannedPageSource {
    let images: [CGImage]

    func pages(presentingFrom presenter: UIViewController) async -> [CGImage] {
        images
    }
}
```

```swift
// ios/CostSauce/Capture/ScannedPageSource.swift -- continued

/// VisionKit's delegate, bridged to one `async` call.
///
/// `hasResumed` is not defensive clutter: this delegate has THREE terminal
/// callbacks (finish, cancel, fail) and a continuation resumed twice traps
/// the process, while one never resumed hangs capture forever with no error.
/// Dismissal happens here rather than at the call site because all three
/// paths must dismiss, and only this type sees all three.
@MainActor
final class ScannerDelegate: NSObject, VNDocumentCameraViewControllerDelegate {
    nonisolated(unsafe) static var associationKey: UInt8 = 0

    private var continuation: CheckedContinuation<[CGImage], Never>?

    init(continuation: CheckedContinuation<[CGImage], Never>) {
        self.continuation = continuation
    }

    private func finish(_ controller: VNDocumentCameraViewController, with pages: [CGImage]) {
        guard let continuation else { return }
        self.continuation = nil
        controller.dismiss(animated: true)
        continuation.resume(returning: pages)
    }

    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
    ) {
        let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage }
        finish(controller, with: pages)
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        finish(controller, with: [])
    }

    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFailWithError error: Error
    ) {
        // Empty, not a thrown error: a failed scan is indistinguishable from
        // a cancelled one as far as this screen is concerned -- nothing was
        // captured either way, and nothing has been minted yet to roll back.
        finish(controller, with: [])
    }
}
```

In `AppModel`, expose the source, chosen the same way the existing `UITEST`
flag is read:

```swift
/// UITEST substitutes a fixture page for the camera the simulator does not
/// have. Same environment flag AppModel already consults to wipe the
/// Keychain and store on launch.
var pageSource: any ScannedPageSource {
    ProcessInfo.processInfo.environment["UITEST"] == "1"
        ? FixturePageSource(images: [Self.fixtureInvoicePage()])
        : DocumentScannerSource()
}
```

`fixtureInvoicePage()` renders a legible synthetic invoice into a `CGImage`
at a resolution and sharpness that pass both gates — draw it with Core
Graphics rather than bundling an asset, so the fixture cannot drift out of
sync with the thresholds.

- [ ] **Step 6: Write the capture view's ingest**

The ordering below is the whole point of this method and is fixed by the
parent spec §12 step 3 — row and bytes on disk before any network call.

```swift
// ios/CostSauce/Views/InvoiceCaptureView.swift -- the ingest

/// Turns scanned images into a live invoice. Order is load-bearing:
///  1. assess quality -- a refused page mints NOTHING, so a retake does not
///     leave an orphan row or a stray file behind;
///  2. mint the invoice, but only once the FIRST page has been accepted --
///     minting it up front would leave an empty invoice behind whenever
///     every page is refused or the user backs out;
///  3. mint the page row, which hands back the storage key;
///  4. write the JPEG;
///  5. enqueue the upload;
///  6. only now, touch the network.
@MainActor
private func ingest(_ images: [CGImage]) async {
    guard let edits = appModel.edits, let orgId = appModel.orgId else { return }
    var pageNo = 1
    do {
        for image in images {
            let variance = PageQuality.laplacianVariance(of: image)
            switch PageQuality.assess(
                width: image.width, height: image.height, laplacianVariance: variance
            ) {
            case .retake(let reason):
                retakeMessage = reason
                continue  // Nothing minted, nothing written.
            case .accept:
                break
            }

            if invoiceId == nil {
                invoiceId = try edits.createInvoice()
            }
            guard let invoiceId else { return }

            let (pageId, _) = try edits.addInvoicePage(
                invoiceId: invoiceId, pageNo: pageNo, orgId: orgId)
            let localPath = try InvoiceFiles.write(image, invoiceId: invoiceId, pageNo: pageNo)
            try appModel.store?.enqueueUpload(pageId: pageId, localPath: localPath)
            pageNo += 1
        }
        appModel.syncSoon()
    } catch let error as KernelError {
        captureErrorMessage = error.message
    } catch {
        captureErrorMessage = error.localizedDescription
    }
}
```

`InvoiceFiles.write(_:invoiceId:pageNo:)` JPEG-encodes into
`Application Support/invoices/{invoice}/{page}.jpg`, creating the directory
with `NSFileProtectionComplete` (§13) exactly as `LocalStore.protectDirectory`
already does for the database, and returns the absolute path.
`PageQuality.laplacianVariance(of:)` is the Accelerate convolution feeding
Step 3's pure `assess` — keep the measurement and the judgement separate, so
the thresholds stay testable without an image.

- [ ] **Step 7: Run the Kit suite and build the app**

Run: `cd ios/CostSauceKit && swift test`
Then: `cd ios && xcodebuild build -project CostSauce.xcodeproj -scheme CostSauce -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D'`
Expected: PASS, 185; `BUILD SUCCEEDED` with no new warnings

- [ ] **Step 8: Commit**

```bash
git add ios/CostSauceKit/Sources/CostSauceKit/Capture ios/CostSauceKit/Tests ios/CostSauce
git commit -m "feat(3a): document-scanner capture, quality gates, and the fixture seam"
```

---

### Task 7: The upload queue and the background uploader

**Files:**
- Create: `ios/CostSauceKit/Sources/CostSauceKit/Upload/UploadQueue.swift`
- Create: `ios/CostSauceKit/Tests/CostSauceKitTests/UploadQueueTests.swift`
- Create: `ios/CostSauce/Upload/BackgroundUploader.swift`

**Interfaces:**
- Consumes: Task 4's `PendingUpload` record and its four store accessors, Task 3's two endpoints.
- Produces: `UploadQueue.next(from: [PendingUpload]) -> PendingUpload?`; `UploadQueue.backoffSeconds(attempts:) -> Double`; `UploadQueue.transition(_:on:) -> PendingUpload` where the event is `.started`, `.succeeded`, or `.failed(String)`; `ApiClient.uploadURL(forPage:)` and `ApiClient.confirmPage(_:sha256:width:height:)`.

**Two member names to verify before writing this, not assume:** the uploader below reaches `appModel.api` and `appModel.orgId` (Task 6's ingest also uses `orgId`). Check what `AppModel` actually calls its `ApiClient` and its bound org id, and use those names — the store binds `(user_id, org_id, location_id)`, so the org id exists, but possibly reached via `store.meta()` rather than as a property.

- [ ] **Step 1: Write the failing test**

```swift
// ios/CostSauceKit/Tests/CostSauceKitTests/UploadQueueTests.swift
import Testing
import Foundation
@testable import CostSauceKit

@Suite struct UploadQueueTests {

    private func upload(
        _ id: String, state: PendingUpload.State, attempts: Int = 0, createdAt: String = "1"
    ) -> PendingUpload {
        PendingUpload(page_id: id, local_path: "/tmp/\(id).jpg", state: state,
                      attempts: attempts, last_error: nil, created_at: createdAt)
    }

    @Test func takesTheOldestQueuedUploadFirst() {
        let next = UploadQueue.next(from: [
            upload("b", state: .queued, createdAt: "2"),
            upload("a", state: .queued, createdAt: "1"),
        ])
        #expect(next?.page_id == "a")
    }

    /// One at a time: a background session uploading four 12MB pages at once
    /// on kitchen Wi-Fi is slower than four in sequence, and starves the op
    /// push sharing the connection.
    @Test func skipsAnUploadAlreadyInFlight() {
        let next = UploadQueue.next(from: [
            upload("a", state: .uploading),
            upload("b", state: .queued),
        ])
        #expect(next == nil)
    }

    @Test func neverReturnsAnAlreadyUploadedPage() {
        #expect(UploadQueue.next(from: [upload("a", state: .uploaded)]) == nil)
    }

    @Test func backoffGrowsWithAttemptsAndIsCapped() {
        let first = UploadQueue.backoffSeconds(attempts: 1)
        let later = UploadQueue.backoffSeconds(attempts: 5)
        #expect(first < later)
        // A page must not become unreachable because it failed all night.
        #expect(UploadQueue.backoffSeconds(attempts: 99) <= 3600)
    }

    @Test func failureRecordsTheReasonAndCountsTheAttempt() {
        let after = UploadQueue.transition(
            upload("a", state: .uploading, attempts: 1), on: .failed("503"))
        #expect(after.state == PendingUpload.State.failed.rawValue)
        #expect(after.attempts == 2)
        #expect(after.last_error == "503")
    }

    /// A failed upload returns to the queue rather than dying: the local
    /// file is still the only copy, so giving up would strand it (§13).
    @Test func aFailedUploadIsRetryableNotTerminal() {
        let failed = UploadQueue.transition(
            upload("a", state: .uploading, attempts: 1), on: .failed("timeout"))
        #expect(UploadQueue.next(from: [failed])?.page_id == "a")
    }

    @Test func successIsTerminal() {
        let done = UploadQueue.transition(upload("a", state: .uploading), on: .succeeded)
        #expect(done.state == PendingUpload.State.uploaded.rawValue)
        #expect(UploadQueue.next(from: [done]) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/CostSauceKit && swift test --filter UploadQueueTests`
Expected: FAIL to build — `cannot find 'UploadQueue' in scope`

- [ ] **Step 3: Write `UploadQueue`**

```swift
// ios/CostSauceKit/Sources/CostSauceKit/Upload/UploadQueue.swift
// The upload outbox's decisions, as pure functions over rows -- no network,
// no filesystem, no URLSession -- so every rule below is unit-testable.
// BackgroundUploader (app target) performs the transfers; this decides what
// to send next and what a result means.
//
// Separate from pending_ops on purpose (spec 3a-D2): a stalled 12MB page
// must never block the JSON op batch behind it.

import Foundation

public enum UploadQueue {

    public enum Event: Equatable {
        case started
        case succeeded
        case failed(String)
    }

    /// The oldest queued or previously-failed upload, or nil when one is
    /// already in flight. One at a time: parallel large uploads on kitchen
    /// Wi-Fi finish later than sequential ones and starve the op push
    /// sharing the connection.
    public static func next(from uploads: [PendingUpload]) -> PendingUpload? {
        if uploads.contains(where: { $0.state == PendingUpload.State.uploading.rawValue }) {
            return nil
        }
        return uploads
            .filter {
                $0.state == PendingUpload.State.queued.rawValue
                    || $0.state == PendingUpload.State.failed.rawValue
            }
            .min { ($0.created_at, $0.page_id) < ($1.created_at, $1.page_id) }
    }

    /// Exponential, capped at an hour. The cap matters: the local file is
    /// still the only copy of that page, so a page that failed all night
    /// must not back off into never being retried at all.
    public static func backoffSeconds(attempts: Int) -> Double {
        min(pow(2.0, Double(max(attempts, 1))), 3600)
    }

    /// `.failed` returns the row to the retryable set rather than ending it
    /// -- giving up would strand the only copy of the page (§13).
    public static func transition(_ upload: PendingUpload, on event: Event) -> PendingUpload {
        var next = upload
        switch event {
        case .started:
            next.state = PendingUpload.State.uploading.rawValue
        case .succeeded:
            next.state = PendingUpload.State.uploaded.rawValue
            next.last_error = nil
        case .failed(let reason):
            next.state = PendingUpload.State.failed.rawValue
            next.attempts = upload.attempts + 1
            next.last_error = reason
        }
        return next
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/CostSauceKit && swift test --filter UploadQueueTests`
Expected: PASS, 7 tests

- [ ] **Step 5: Write `BackgroundUploader`**

```swift
// ios/CostSauce/Upload/BackgroundUploader.swift
// Performs the transfers UploadQueue selects. All policy lives in the Kit's
// pure UploadQueue; this owns only the URLSession and the ordering below.

import CryptoKit
import Foundation
import CostSauceKit

@MainActor
final class BackgroundUploader: NSObject, URLSessionTaskDelegate {
    private let appModel: AppModel
    /// Set by the app delegate's
    /// handleEventsForBackgroundURLSession and called once the session
    /// reports it has finished delivering events. WITHOUT this, iOS treats
    /// the app as unresponsive and kills uploads that complete while it is
    /// suspended -- which is most of them, since these are large files on
    /// slow connections.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "sauce.invoice.upload")
        // A kitchen phone leaves the building mid-upload constantly; let the
        // system retry when connectivity returns rather than failing now.
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
    }

    /// Uploads the single page `UploadQueue.next` selects, if any.
    func pumpOnce() async {
        guard let store = appModel.store,
              let queued = try? store.pendingUploads(),
              let upload = UploadQueue.next(from: queued) else { return }
        do {
            // Minted per attempt, never cached: a URL signed before a night
            // offline has long expired by the time the session runs.
            let signed = try await appModel.api.uploadURL(forPage: upload.page_id)
            try store.updateUpload(UploadQueue.transition(upload, on: .started))

            let fileURL = URL(fileURLWithPath: upload.local_path)
            var request = URLRequest(url: signed.url)
            request.httpMethod = "PUT"
            // fromFile, never fromData: a background session rejects a body
            // held in memory, and these files are megabytes.
            let (_, response) = try await session.upload(for: request, fromFile: fileURL)

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw KernelError("upload rejected")
            }

            let bytes = try Data(contentsOf: fileURL)
            try await appModel.api.confirmPage(
                upload.page_id,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                width: signed.width, height: signed.height)

            try store.updateUpload(UploadQueue.transition(upload, on: .succeeded))
            appModel.refreshPendingCount()
        } catch {
            // Retryable, never terminal: the local file is still the only
            // copy of this page (§13), so giving up would strand it.
            try? store.updateUpload(
                UploadQueue.transition(upload, on: .failed(error.localizedDescription)))
            try? await Task.sleep(
                for: .seconds(UploadQueue.backoffSeconds(attempts: upload.attempts + 1)))
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
```

Add `ApiClient.uploadURL(forPage:)` and `ApiClient.confirmPage(_:sha256:width:height:)`
calling Task 3's two endpoints, following the existing client's request-building
and error-mapping conventions. In the app delegate:

```swift
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    uploader.backgroundCompletionHandler = completionHandler
}
```

**The local file is deleted here under no circumstances.** Eviction is Task
8's, and only ever for pages already uploaded.

- [ ] **Step 6: Run the Kit suite and build**

Run: `cd ios/CostSauceKit && swift test` then the Task 6 `xcodebuild build` command
Expected: PASS, 192; `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add ios/CostSauceKit/Sources/CostSauceKit/Upload ios/CostSauceKit/Tests ios/CostSauce/Upload
git commit -m "feat(3a): the upload outbox and its background uploader"
```

---

### Task 8: Eviction and the unsynced badge

**Files:**
- Create: `ios/CostSauceKit/Sources/CostSauceKit/Upload/ImageEviction.swift`
- Create: `ios/CostSauceKit/Tests/CostSauceKitTests/ImageEvictionTests.swift`
- Modify: `ios/CostSauce/AppModel.swift`

**Interfaces:**
- Consumes: Task 4's `PendingUpload`.
- Produces: `ImageEviction.evictable(candidates:now:) -> [String]` taking `[ImageEviction.Candidate]` (`pageId`, `bytes`, `capturedAt`, `isUploaded`) and returning page ids to delete, oldest first; `ImageEviction.maximumBytes` and `ImageEviction.maximumAge`; `AppModel.pendingCount` includes pending uploads.

- [ ] **Step 1: Write the failing test**

```swift
// ios/CostSauceKit/Tests/CostSauceKitTests/ImageEvictionTests.swift
import Testing
import Foundation
@testable import CostSauceKit

@Suite struct ImageEvictionTests {

    private func candidate(
        _ id: String, bytes: Int, ageDays: Int, uploaded: Bool = true
    ) -> ImageEviction.Candidate {
        ImageEviction.Candidate(
            pageId: id, bytes: bytes,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
                .addingTimeInterval(-Double(ageDays) * 86_400),
            isUploaded: uploaded)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// THE load-bearing rule (spec 3a-D4). The local file is the only copy
    /// until storage acknowledges, so evicting it would destroy the page.
    @Test func neverEvictsAnUnuploadedPageEvenWhenHugeAndAncient() {
        let evicted = ImageEviction.evictable(
            candidates: [candidate("a", bytes: 500_000_000, ageDays: 3650, uploaded: false)],
            now: now)
        #expect(evicted.isEmpty)
    }

    @Test func keepsEverythingWhenUnderBothBounds() {
        let evicted = ImageEviction.evictable(
            candidates: [candidate("a", bytes: 1_000, ageDays: 1)], now: now)
        #expect(evicted.isEmpty)
    }

    @Test func evictsPagesPastTheAgeBound() {
        let evicted = ImageEviction.evictable(
            candidates: [
                candidate("old", bytes: 1_000, ageDays: 400),
                candidate("new", bytes: 1_000, ageDays: 1),
            ], now: now)
        #expect(evicted == ["old"])
    }

    @Test func evictsOldestFirstUntilUnderTheByteBound() {
        let big = ImageEviction.maximumBytes / 2 + 1
        let evicted = ImageEviction.evictable(
            candidates: [
                candidate("oldest", bytes: big, ageDays: 3),
                candidate("middle", bytes: big, ageDays: 2),
                candidate("newest", bytes: big, ageDays: 1),
            ], now: now)
        #expect(evicted.first == "oldest")
        #expect(!evicted.contains("newest"))
    }

    /// An un-uploaded page still counts toward the total -- it occupies the
    /// disk -- but can never be the thing evicted to get under it.
    @Test func anUnuploadedPageIsNotSacrificedToGetUnderTheBound() {
        let big = ImageEviction.maximumBytes
        let evicted = ImageEviction.evictable(
            candidates: [
                candidate("pending", bytes: big, ageDays: 10, uploaded: false),
                candidate("done", bytes: big, ageDays: 1),
            ], now: now)
        #expect(!evicted.contains("pending"))
        #expect(evicted.contains("done"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/CostSauceKit && swift test --filter ImageEvictionTests`
Expected: FAIL to build — `cannot find 'ImageEviction' in scope`

- [ ] **Step 3: Write `ImageEviction`**

```swift
// ios/CostSauceKit/Sources/CostSauceKit/Upload/ImageEviction.swift
// Which cached page images may be deleted. Pure: it takes measurements and
// returns page ids, touching no filesystem, so every rule is testable.
//
// Spec 3a-D4: deleting on upload-ack would break photo-assisted entry in
// exactly the walk-in-cooler dead spot the product exists for; keeping
// everything grows without ceiling on the owner's phone.

import Foundation

public enum ImageEviction {

    public struct Candidate: Equatable, Sendable {
        public let pageId: String
        public let bytes: Int
        public let capturedAt: Date
        public let isUploaded: Bool

        public init(pageId: String, bytes: Int, capturedAt: Date, isUploaded: Bool) {
            self.pageId = pageId
            self.bytes = bytes
            self.capturedAt = capturedAt
            self.isUploaded = isUploaded
        }
    }

    /// CALIBRATION, same rule as PageQuality's: replace these with measured
    /// values and record what you measured, before this task is done.
    public static let maximumBytes: Int = 500 * 1_024 * 1_024
    public static let maximumAge: TimeInterval = 90 * 86_400

    /// Page ids safe to delete, oldest first. An un-uploaded page is never
    /// returned, at any age or size: until storage acknowledges, the local
    /// file is the only copy in existence (§13).
    public static func evictable(candidates: [Candidate], now: Date) -> [String] {
        let evictableCandidates = candidates
            .filter(\.isUploaded)
            .sorted { ($0.capturedAt, $0.pageId) < ($1.capturedAt, $1.pageId) }

        var evicted: [String] = []
        // Un-uploaded pages still occupy the disk, so they count toward the
        // total -- they simply cannot be what gets sacrificed to get under it.
        var total = candidates.reduce(0) { $0 + $1.bytes }

        for candidate in evictableCandidates {
            let tooOld = now.timeIntervalSince(candidate.capturedAt) > maximumAge
            if tooOld || total > maximumBytes {
                evicted.append(candidate.pageId)
                total -= candidate.bytes
            }
        }
        return evicted
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/CostSauceKit && swift test --filter ImageEvictionTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Fold pending uploads into the badge**

In `AppModel.refreshPendingCount()`, add the count of `pending_uploads` rows
not in state `uploaded` to the existing `pending_ops` count.

```swift
// AppModel.swift, inside refreshPendingCount()
// §9: a captured-but-unuploaded page is unsynced data living only in the
// app container. Counting only pending_ops would make the app read as safe
// in precisely the delete-and-reinstall situation §13 exists to prevent.
pendingCount = try store.pendingCount() + store.pendingUploadCount()
```

Add `LocalStore.pendingUploadCount()` returning
`SELECT count(*) FROM pending_uploads WHERE state != 'uploaded'`.

- [ ] **Step 6: Erase image FILES on identity switch and wipe**

Spec §11: on an identity switch the local store binds to `(user_id, org_id)`
and refuses to flush, and image files are part of what must be erased.
`LocalStore.wipeSyncedData()` (extended in Task 4) clears the `invoice_pages`
and `pending_uploads` *rows*, but the JPEGs live on the filesystem and would
survive it — leaving another org's invoice photographs in the container on a
shared or resold phone. That is the same class of problem
`NSFileProtectionComplete` exists to prevent, and rows-only cleanup does not
address it.

```swift
// ios/CostSauceKit/Tests/CostSauceKitTests/StoreTests.swift -- append

/// §11: wiping for an identity switch must take the IMAGES, not just the
/// rows. A rows-only wipe leaves another org's invoice photographs sitting
/// in the app container.
@Test func wipeReturnsEveryLocalImagePathSoTheFilesCanBeDeleted() throws {
    let store = try LocalStore.inMemory()
    try store.bind(userId: "user-1", orgId: "org-1", locationId: "loc-1")
    try store.enqueueUpload(pageId: "pg-1", localPath: "/tmp/a.jpg")
    try store.enqueueUpload(pageId: "pg-2", localPath: "/tmp/b.jpg")

    let orphanedPaths = try store.wipeSyncedData()

    #expect(Set(orphanedPaths) == ["/tmp/a.jpg", "/tmp/b.jpg"])
    #expect(try store.pendingUploadCount() == 0)
}
```

Change `wipeSyncedData()` to return `[String]` — the `local_path` of every
row it is about to delete, collected *before* the `DELETE`, inside the same
transaction:

```swift
// LocalStore.swift, in wipeSyncedData(), before the DELETE statements
let orphanedPaths = try String.fetchAll(
    db, sql: "SELECT local_path FROM pending_uploads")
// ... existing DELETEs, plus the three added in Task 4 ...
return orphanedPaths
```

Its caller in `AppModel` deletes each returned path, then removes the now-empty
`Application Support/invoices` directory. Returning the paths rather than
deleting inside the Kit keeps `LocalStore` free of filesystem concerns beyond
the database file it already owns, and keeps this testable without touching a
real disk.

- [ ] **Step 7: Run the Kit suite and build**

Run: `cd ios/CostSauceKit && swift test` then the Task 6 `xcodebuild build` command
Expected: PASS, 198; `BUILD SUCCEEDED`. Every existing `wipeSyncedData()` call
site must be updated for the new return value — `_ = try store.wipeSyncedData()`
where the paths are not wanted.

- [ ] **Step 8: Commit**

```bash
git add ios/CostSauceKit ios/CostSauce/AppModel.swift
git commit -m "feat(3a): bounded image cache, upload-aware badge, and image erasure on wipe"
```

---

### Task 9: Photo-assisted manual entry

**Files:**
- Create: `ios/CostSauce/Views/InvoiceListView.swift`
- Create: `ios/CostSauce/Views/InvoicePageView.swift`
- Modify: `ios/CostSauce/Views/PurchaseEntryView.swift`
- Modify: `ios/CostSauceKit/Sources/CostSauceKit/Store/LocalEdits.swift`
- Modify: `ios/CostSauceKit/Tests/CostSauceKitTests/LocalEditsTests.swift`

**Interfaces:**
- Consumes: Tasks 4–6.
- Produces: `LocalEdits.createPurchase(...)` gains a trailing `invoicePageId: String? = nil` parameter; `PurchaseEntryView.init(appModel:invoicePageId:)` with `invoicePageId` defaulting to `nil`.

The defaulted parameter matters: every existing `createPurchase` and
`PurchaseEntryView` call site keeps compiling and behaving identically, so
this task adds a path rather than migrating one.

- [ ] **Step 1: Write the failing test**

```swift
// append to LocalEditsTests.swift

@Test func createPurchaseCarriesTheInvoicePageItWasKeyedFrom() throws {
    let store = try seededStore([
        StoreTests.ingredientChange(id: "ing-1", name: "Flour", baseUnit: "lb", serverSeq: 1),
    ])
    let edits = LocalEdits(store: store, locationId: "loc-1")

    let id = try edits.createPurchase(
        ingredientId: "ing-1", purchasedOn: "2026-08-03", qty: "10", unit: "lb",
        qtyInCase: nil, totalPrice: "55.10", invoicePageId: "pg-1")

    let op = try #require(try store.pendingOps(state: .queued).first { $0.row_id == id })
    #expect(fieldValue(op, "invoice_page_id") == "pg-1")
    // 3a-D5: a human keyed this while looking at a photo. It is manual.
    #expect(fieldValue(op, "source") == "manual")
}

/// The parameter is defaulted, so every pre-3a call site is unchanged --
/// and must not start sending an explicit null.
@Test func createPurchaseWithoutAPageOmitsTheKeyEntirely() throws {
    let store = try seededStore([
        StoreTests.ingredientChange(id: "ing-1", name: "Flour", baseUnit: "lb", serverSeq: 1),
    ])
    let edits = LocalEdits(store: store, locationId: "loc-1")

    let id = try edits.createPurchase(
        ingredientId: "ing-1", purchasedOn: "2026-08-03", qty: "10", unit: "lb",
        qtyInCase: nil, totalPrice: "55.10")

    let op = try #require(try store.pendingOps(state: .queued).first { $0.row_id == id })
    #expect(!op.fields.keys.contains("invoice_page_id"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/CostSauceKit && swift test --filter createPurchaseCarries`
Expected: FAIL to build — extra argument `invoicePageId` in call

- [ ] **Step 3: Extend `createPurchase`**

Add `invoicePageId: String? = nil` as the last parameter before `now:`, and
inside, only when it is non-nil:

```swift
// Omitted entirely when nil, never sent as an explicit null -- the same
// "was a value supplied" rule every other optional field here follows.
if let invoicePageId {
    fields["invoice_page_id"] = invoicePageId
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/CostSauceKit && swift test --filter createPurchase`
Expected: PASS

- [ ] **Step 5: Build the two views**

`InvoiceListView` lists `store.liveInvoices()` newest first, each row showing
its capture date, page count, and an upload indicator driven by
`pending_uploads`. Tapping pushes `InvoicePageView`.

`InvoicePageView` shows one page, zoomable, with the page selector when
there is more than one, and an "Add purchase from this page" button pushing
`PurchaseEntryView(appModel:invoicePageId:)`. The image loads from the local
file when present and from a signed download URL when it has been evicted —
eviction removes the file, never the row.

`PurchaseEntryView` gains `let invoicePageId: String?` (defaulted `nil`) and
passes it straight through to `createPurchase`. Nothing else about it
changes; its validation and op-minting are untouched.

- [ ] **Step 6: Run the Kit suite and build**

Run: `cd ios/CostSauceKit && swift test` then the Task 6 `xcodebuild build` command
Expected: PASS, 199; `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add ios/CostSauce ios/CostSauceKit
git commit -m "feat(3a): photo-assisted purchase entry against a captured page"
```

---

### Task 10: XCUITest acceptance and the runbook

**Files:**
- Modify: `ios/CostSauceUITests/SmokeTests.swift`
- Create: `docs/runbooks/phase-3a-acceptance.md`

**Interfaces:**
- Consumes: everything above, particularly Task 6's `FixturePageSource`.

- [ ] **Step 1: Write the failing test**

```swift
// append to SmokeTests.swift

/// Capture -> upload -> photo-assisted purchase -> synced, against a real
/// local stack. Runs headless because Task 6's ScannedPageSource seam feeds
/// a fixture page where the scanner's output would land -- the simulator has
/// no camera, so without that seam this test could not exist at all.
func testInvoiceCaptureUploadAndPhotoAssistedPurchase() throws {
    let app = XCUIApplication()
    app.launchEnvironment = [
        "API_BASE_URL": apiBaseURL,
        "UITEST": "1",
        "REVIEWER_EMAIL": reviewerEmail,
        "REVIEWER_CODE": reviewerCode,
    ]
    app.launch()
    loginAndAwaitBootstrap(app)

    let captureButton = app.buttons["Capture Invoice"]
    XCTAssertTrue(captureButton.waitForExistence(timeout: 10), "capture entry point never appeared")
    captureButton.tap()

    // The fixture page passes both quality gates, so it is accepted without
    // a retake prompt and the invoice is minted.
    XCTAssertTrue(
        app.staticTexts["1 page"].waitForExistence(timeout: 10),
        "the captured page never landed on an invoice")

    // The badge counts the un-uploaded page (§9): unsynced until it lands.
    let syncedChip = app.buttons["Synced \u{2713}"]
    XCTAssertTrue(
        syncedChip.waitForExistence(timeout: 30),
        "sync chip never reached Synced -- the page upload or its ops did not complete")

    app.buttons["Add purchase from this page"].tap()

    let ingredientField = app.textFields["Ingredient name"]
    XCTAssertTrue(ingredientField.waitForExistence(timeout: 10))
    ingredientField.tap()
    addStagedIngredient(ingredientField, "Chicken Breast", app: app)

    let qtyField = app.textFields["Qty"]
    XCTAssertTrue(qtyField.waitForExistence(timeout: 5))
    qtyField.tap()
    qtyField.typeText("10")
    let priceField = app.textFields["Total price"]
    priceField.tap()
    priceField.typeText("32.00")
    app.buttons["Save"].tap()

    XCTAssertTrue(
        syncedChip.waitForExistence(timeout: 30),
        "sync chip never returned to Synced after the photo-assisted purchase")

    print("CHECKPOINT 1 (capture+purchase synced): the runbook's SQL asserts one invoices row, one invoice_pages row with a non-null sha256, and a purchase whose invoice_page_id matches that page")
}
```

- [ ] **Step 2: Run it against the stack and watch it fail**

Stand the stack up exactly as `docs/runbooks/phase-2b-acceptance.md` §2
describes — its §2.2 seed script is reproduced verbatim in that runbook, so
copy it to a scratch path and run it. **Reseed only while `uvicorn` is
down**, or every request 500s on stale prepared-statement plans. Then:

Run: `cd ios && xcodebuild test -project CostSauce.xcodeproj -scheme CostSauce -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D' -only-testing:CostSauceUITests/SmokeTests/testInvoiceCaptureUploadAndPhotoAssistedPurchase`
Expected: FAIL — "capture entry point never appeared", until the entry point is wired

- [ ] **Step 3: Wire the entry point and make it pass**

Add the "Capture Invoice" affordance where Task 9's `InvoiceListView` is
reached. Give it a 44×44pt target with `.contentShape(Rectangle())` — the
same fix the Dashboard "+" needed.

- [ ] **Step 4: Verify against the server**

```bash
docker exec cs-3a-smoke psql -U postgres -d postgres -c \
  "SELECT i.id, count(p.id) AS pages, bool_and(p.sha256 IS NOT NULL) AS all_confirmed
     FROM invoices i JOIN invoice_pages p ON p.invoice_id = i.id
    GROUP BY i.id;" -c \
  "SELECT pu.total_price, pu.invoice_page_id IS NOT NULL AS linked
     FROM purchases pu WHERE pu.invoice_page_id IS NOT NULL;"
```

Expected: one invoice, one page, `all_confirmed = t` (proving the confirm
endpoint ran, not merely the PUT), and one linked purchase.

- [ ] **Step 5: Run the whole suite — nothing may regress**

Run: `cd ios && xcodebuild test -project CostSauce.xcodeproj -scheme CostSauce -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D'`
Expected: 4/4 tests pass

- [ ] **Step 6: Write the runbook**

`docs/runbooks/phase-3a-acceptance.md`, following
`phase-2b-acceptance.md`'s structure: local stack, the seed script inline
(uncommitted but reproduced in full), the checkpoint SQL, and an explicit
coverage-gap section. **State plainly that the real
`VNDocumentCameraViewController` path is never exercised by any automated
test** — only `FixturePageSource` is — so the camera, its permission prompt,
and multi-page retake need one manual device pass before release, exactly as
2b's swipe-to-remove does.

- [ ] **Step 7: Commit**

```bash
git add ios/CostSauceUITests/SmokeTests.swift docs/runbooks/phase-3a-acceptance.md
git commit -m "test(3a): headless capture-to-synced-purchase acceptance walk"
```
