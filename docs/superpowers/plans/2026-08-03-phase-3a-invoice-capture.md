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

`sign_put(path)` is the Supabase Storage signing call; implement it beside this
router using the same service-role client the codebase already configures, and
have it return `(url, expires_at_iso)`. If no such client exists yet, add it
here — it is this task's deliverable, not a later one's.

- [ ] **Step 4: Register the router**

```python
# api/main.py -- beside the existing router registrations
from api.routes import invoices
app.include_router(invoices.router)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `uv run pytest tests/test_invoices.py -v`
Expected: PASS, 11 tests

- [ ] **Step 6: Commit**

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

### Tasks 6–10

Written in the continuation of this plan. Boundaries, files, and interfaces
are fixed in the File Structure and Task List above; Tasks 1–5 establish
every type and signature they consume.
