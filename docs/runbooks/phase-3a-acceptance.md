# Phase 3a Acceptance Runbook: invoice capture, upload, photo-assisted entry

Audience: whoever needs to re-run Phase 3a's end-to-end proof — capturing an
invoice page offline-first, uploading its bytes through a pre-signed PUT,
confirming them server-side, and keying a purchase in against the visible
page — or verify it before 3b (the parser) builds on top of it. Assumes the
reader has applied `0001`–`0017` and has read
`docs/runbooks/phase-2b-acceptance.md`; this document only restates what is
different.

**Backend target:** two additions this phase — migration
`0017_invoice_capture.sql` (the `invoices`/`invoice_pages` tables, RLS, and
`purchases.invoice_page_id`) and `api/routes/invoices.py` (the
pre-signed-upload mint and its confirm). The acceptance run is local
(disposable Postgres + `uv run uvicorn` + a storage stub), same shape as
2b's.

---

## 1. What shipped in this task

- **`ios/CostSauceUITests/SmokeTests.swift`** (modified): a new journey,
  `testInvoiceCaptureUploadAndPhotoAssistedPurchase` — reviewer login →
  Invoices tab → capture (the `UITEST` fixture page stands in for the
  camera) → the invoice list's row indicator flips to **Uploaded** (the
  §9-visible proof that the PUT *and* the confirm both landed) → open the
  page → "Add purchase from this page" → fuzzy-pick "Chicken Breast", 10 lb
  / $32.00 → save → synced. One checkpoint `print` marks where this
  document's SQL runs.
- **`ios/CostSauce/Views/MainTabView.swift`** (modified): the Invoices tab
  — the entry point Task 9's `InvoiceListView` needed (its own toolbar
  already carried the "Capture Invoice" affordance).
- **`api/models.py`** (modified) + **`tests/test_sync_service.py`**
  (modified): the finding in §6.1.
- **`ios/CostSauce/Upload/BackgroundUploader.swift`** (modified): the
  UITEST session seam in §6.2.
- This document.

---

## 2. Local stack

### 2.1 Disposable Postgres 17

```bash
docker run -d --name cs-3a-smoke -e POSTGRES_PASSWORD=postgres -p 55443:5432 postgres:17
for i in $(seq 1 30); do
  docker exec cs-3a-smoke pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
```

Port `55443` is arbitrary (55441/55442 belong to 2a/2b's own runbooks so
all three can coexist).

### 2.2 Seed script

`scratch/seed_3a.py`, not committed (same convention as 2a/2b). It is
**identical to `phase-2b-acceptance.md` §2.2's `seed_2b.py`** — copy it
from there verbatim. The 3a walk only needs the unpriced "Chicken Breast",
but the whole `SmokeTests` suite runs in §5 and the 2b journeys need
"Ground Beef"/"Onion" pre-priced.

```bash
DB_URL="postgresql://postgres:postgres@127.0.0.1:55443/postgres" \
  PYTHONPATH=. uv run python scratch/seed_3a.py
```

2b's gotcha stands: **reseed only while `uvicorn` is down**, or every
request 500s on stale prepared-statement plans.

### 2.3 The storage stub — new in 3a

`api/routes/invoices.py`'s `sign_put` POSTs to
`{SUPABASE_URL}/storage/v1/object/upload/sign/{bucket}/{path}` and hands
the device `{SUPABASE_URL}/storage/v1{signed}`. No local Supabase runs in
this stack, so a ~50-line stub signs anything and accepts the PUT the
signature authorizes, discarding the bytes — the walk's proof of arrival
is the **confirm row** (`sha256`/`width`/`height` recorded in
`invoice_pages`), not storage's copy.

`scratch/storage_stub_3a.py`, not committed:

```python
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SIGN_PREFIX = "/storage/v1/object/upload/sign/"


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1, not the default 1.0: CFNetwork rejects 1.0-framed responses
    # on upload tasks with a bare NSURLErrorUnknown ("unknown error").
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        # Consume the body BEFORE responding: with HTTP/1.1 keep-alive an
        # unread body is parsed as the next request line.
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if not self.path.startswith(SIGN_PREFIX):
            self.send_response(404)
            self.end_headers()
            return
        # sign_put reads json()["url"] and prefixes {base}/storage/v1 itself.
        signed = self.path[len("/storage/v1"):] + "?token=smoke"
        body = json.dumps({"url": signed}).encode()
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
        while length > 0:
            chunk = self.rfile.read(min(length, 1 << 16))
            if not chunk:
                break
            length -= len(chunk)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        print(f"stub: {fmt % args}", file=sys.stderr, flush=True)


ThreadingHTTPServer(("127.0.0.1", 8402), Handler).serve_forever()
```

```bash
python3 scratch/storage_stub_3a.py &
```

### 2.4 Start the API

2b's env plus the two storage variables. `SUPABASE_ANON_KEY` stays unset
**on purpose**: `AppModel` only builds a GoTrue client when *both* URL and
anon key are present, so the reviewer-only login every journey depends on
still renders even though `SUPABASE_URL` now points at the stub.

```bash
export JWT_SECRET="smoke-test-secret-3a"
export JWT_ISSUER="costsauce-tests"
export DATABASE_URL="postgres://app_user:app_pw@127.0.0.1:55443/postgres"
export REVIEWER_OTP_ENABLED=1
export REVIEWER_EMAIL="reviewer@example.com"
export REVIEWER_CODE="123456"
export REVIEWER_USER_ID="00000000-0000-7000-8000-0000000d1501"
export SUPABASE_URL="http://127.0.0.1:8402"
export SUPABASE_SERVICE_ROLE_KEY="smoke-service-role"
unset SUPABASE_ANON_KEY
uv run uvicorn api.main:app --port 8401 &

curl -sS http://127.0.0.1:8401/config
# -> {"supabase_url":"http://127.0.0.1:8402","supabase_anon_key":null}
```

---

## 3. Simulator

Same as 2b §3 — an eligible OS 26.2 destination. This run used
"iPhone 17 Pro" (`id=F71924C7-9272-4A35-AA66-82061A1E4A9D`).

---

## 4. Run the 3a journey

```bash
cd ios
xcodegen generate
xcodebuild test -project CostSauce.xcodeproj -scheme CostSauce \
  -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D' \
  -only-testing:CostSauceUITests/SmokeTests/testInvoiceCaptureUploadAndPhotoAssistedPurchase
```

At `CHECKPOINT 1` (and any time after — the state is terminal), assert
against the server:

```bash
docker exec cs-3a-smoke psql -U postgres -d postgres -c \
  "SELECT i.id, count(p.id) AS pages, bool_and(p.sha256 IS NOT NULL) AS all_confirmed
     FROM invoices i JOIN invoice_pages p ON p.invoice_id = i.id
    GROUP BY i.id;" -c \
  "SELECT pu.total_price, pu.source, pu.invoice_page_id IS NOT NULL AS linked,
          pu.invoice_page_id IN (SELECT id FROM invoice_pages) AS matches_page
     FROM purchases pu WHERE pu.invoice_page_id IS NOT NULL;"
```

Recorded result, 2026-08-03: one invoice, `pages = 1`,
**`all_confirmed = t`** (the confirm endpoint ran — not merely the PUT;
the row carried `width=1694 height=2200` and a 64-char sha), and one
purchase `total_price = 32.00`, `source = manual`, `linked = t`,
`matches_page = t`. The storage path on the row matched the
`{org}/{invoice}/{page}.jpg` derivation exactly.

---

## 5. Run the whole suite — nothing may regress

Reseed (API down), restart the API, then:

```bash
xcodebuild test -project CostSauce.xcodeproj -scheme CostSauce \
  -destination 'platform=iOS Simulator,id=F71924C7-9272-4A35-AA66-82061A1E4A9D'
```

Recorded result, 2026-08-03: **4/4** — the 3a walk plus both 2b journeys
and the 2a purchase journey, one invocation.

---

## 6. Findings this task recorded (both reproduced live, then fixed)

### 6.1 `SyncOpIn.table` lagged `TABLE_ORDER` — every invoice push 422'd

The first wired run pushed the captured invoice and got
`POST /sync → 422`; zero rows landed and the upload-url mint then 404'd.
`api/models.py`'s `SyncOpIn.table` is a `Literal` allowlist sitting **in
front of** `api/services/sync.py`'s own constants, and Task 2 widened only
the latter. No unit test caught it because none pushed the new tables
through the *wire model*. Fixed by widening the Literal;
`tests/test_sync_service.py::test_sync_op_wire_model_accepts_every_table_in_table_order`
now pins the Literal to `TABLE_ORDER`, so the next new table fails in a
unit test instead of an acceptance walk.

### 6.2 The simulator cannot run a background-session upload at all

With the real `URLSessionConfiguration.background`, the PUT failed
instantly with a bare `NSURLErrorUnknown` — `pending_uploads.last_error =
"unknown error"`, and the stub's log showed **no request ever left the
process**. This is a simulator limitation of the background-transfer
daemon, not a stack problem. `BackgroundUploader` now substitutes an
`.ephemeral` (foreground) session **only under `UITEST=1`**, through the
identical delegate-bridged transfer path — the same seam rule as
`AppModel.pageSource` substituting the camera. Production keeps the
background configuration.

A second, related finding: the sync chip's "Synced ✓" reflects
`syncState` alone and says nothing about the upload outbox — an early
version of the walk passed its chip wait while the PUT was failing. The
walk now asserts the invoice row's own **Uploaded** indicator, which flips
only when the outbox reaches `uploaded` (PUT *and* confirm).

---

## 7. Deployment prerequisites (not created by any migration)

- A **private** storage bucket named **`invoices`** must exist in each real
  Supabase environment. It is created once, out of band; a fresh
  environment without it silently 502s on every upload-url mint.
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` must be set in the API's
  environment wherever uploads should work.

---

## 8. Coverage gaps — what no automated test exercises

State these plainly; each needs a **manual device pass before release**,
exactly as 2b's swipe-to-remove does:

1. **The real document scanner.** `VNDocumentCameraViewController` cannot
   run in the simulator, so only `FixturePageSource` is ever exercised.
   The camera, its permission prompt, multi-page scans, and the retake
   prompt against genuinely bad photographs are untested by automation.
2. **The real background `URLSession` path.** §6.2's seam means automation
   never exercises the background configuration: the relaunch handshake
   (`handleEventsForBackgroundURLSession` → parked completion handler),
   uploads finishing while the app is suspended, and
   `waitsForConnectivity` behavior all need the device pass.
3. **Quality-gate refusal in the walk.** The fixture page deliberately
   passes both gates; the refusal path is unit-tested
   (`PageQualityTests`) but the retake UI loop is only exercised manually.
4. **Eviction sweeps.** `ImageEviction` is pure policy with unit tests;
   nothing wires a periodic sweep yet, so no automated test deletes a real
   file. (Related deferral: an evicted page currently shows "Photo Not on
   This Device" — the signed-download fallback arrives with 3b's
   re-download endpoint.)

---

## 9. Teardown

```bash
kill %1 %2 2>/dev/null   # uvicorn, storage stub
docker rm -f cs-3a-smoke
```
