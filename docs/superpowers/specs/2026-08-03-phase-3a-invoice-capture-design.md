# Phase 3a — Invoice capture, upload, and photo-assisted entry

**Date:** 2026-08-03
**Status:** Design approved, plan not yet written
**Predecessor:** Phase 2b (iOS recipe editing), `origin/main` at `5a91da2`
**Parent spec:** `docs/superpowers/specs/2026-07-25-native-ios-app-design.md` (§4.4 schema, §10 storage, §12 pipeline, §13 error handling)

---

## 1. Why this phase is a slice, not all of Phase 3

Phase 3 as written in the parent spec §12 spans seven largely independent subsystems: invoice
schema and RLS; sync integration; a storage bucket with pre-signed uploads; iOS document-scanner
capture with quality gates; a hand-rolled background uploader; a server-side vision-LLM parse
worker; and a review-and-confirm screen that mints purchases. That is several specs' worth of work,
and two of those subsystems are blocked on decisions and artifacts only Travis can supply.

**3a is the half that has no LLM dependency at all**: get invoice pages captured, durably stored
locally, uploaded, and immediately useful. It is deliberately unblocked — it does not wait on the
bad-photo fixture set or on a vision-LLM vendor choice, both of which gate 3b.

## 2. Decisions

| | Decision | Why |
|---|---|---|
| **3a-D1** | 3a ships **photo-assisted manual entry**, not a dormant capture feature | §12 step 6 names "the existing photo-assisted manual entry" as the mandatory parse-failure fallback. That fallback **does not exist** — not in the iOS app, not in the legacy `product/`. 3b needs it built regardless, so building it now gives 3a real standalone value and reduces 3b to adding the parser on top |
| **3a-D2** | **Two queues**: rows ride the existing sync protocol, bytes ride a separate background upload queue | A server-authoritative design cannot mint an invoice row offline, contradicting the parent spec's D2 ("the owner holds the invoice where the signal is worst"). A single unified queue would weld a fast JSON batch protocol to slow resumable binary transfers with incompatible retry semantics — one stalled 12MB page would block every queued op behind it |
| **3a-D3** | `invoice_line_items` is **deferred to 3b** | Nothing in 3a reads or writes it. Creating the table now would ship an unexercised schema |
| **3a-D4** | Local images are a **bounded cache, oldest-first eviction**, and only uploaded pages are evictable | Deleting on upload-ack (the literal reading of §13) would break photo-assisted entry in exactly the walk-in-cooler dead spot the product exists for. Keeping everything grows without ceiling on the owner's phone |
| **3a-D5** | `purchases.source` stays `'manual'` in 3a | A human keyed the value while looking at a photo. Recording it as anything else would be false. 3b adds an `'ocr'` value along with the parser that earns it |

## 3. Scope

**In:** the `invoices` and `invoice_pages` tables with RLS and sync integration; the private storage
bucket and pre-signed upload endpoint; iOS document-scanner capture with resolution and sharpness
gates; the local image store and background upload queue with eviction; the `purchases →
invoice_pages` link; photo-assisted manual purchase entry against a captured page; pending uploads
counted in the unsynced badge.

**Out:** the vision LLM and any parse worker (3b); `invoice_line_items` (3b, 3a-D3); the
review-and-confirm screen that mints purchases from parsed lines (3b); `source='ocr'` (3b, 3a-D5);
the bad-photo fixture set (3b's acceptance gate); invoice-level metadata such as vendor or invoice
number (no parser to populate it, and asking the owner to key it defeats the purpose); PDF or
photo-library import (the document scanner is the capture path).

## 4. Schema — migration `0017`

Both new tables are syncable and carry the standard column set (`client_mutated_at`, `server_seq`,
`updated_at`, `deleted_at`, `created_at`) per the parent spec §4.2.

```
invoices       (id, location_id → locations ON DELETE CASCADE, captured_at,
                parse_status text NOT NULL DEFAULT 'unparsed'
                  CHECK (parse_status IN ('unparsed','failed')), …sync columns)

invoice_pages  (id, invoice_id → invoices ON DELETE CASCADE, location_id, page_no int,
                storage_path text, width int, height int, sha256 text, …sync columns)
```

`invoice_pages` carries a **live-only partial unique** on `(invoice_id, page_no)` — the same shape
as the existing `recipe_items_live_uq` — so a tombstoned retake does not collide with its
replacement.

`storage_path` is written by the **client**, not the server. §4.4 requires storage keys to be a
deterministic function of the client-minted invoice UUID plus page number, which is precisely what
makes a retry overwrite rather than duplicate. The server verifies the path on confirm rather than
minting it.

**One change to an existing table:**

```
ALTER TABLE purchases ADD COLUMN invoice_page_id uuid
  REFERENCES invoice_pages(id) ON DELETE SET NULL;
```

Nullable, and `SET NULL` rather than `CASCADE`: a purchase records a real cost the business
incurred, and deleting the photograph of its invoice must not delete the cost.

The `parse_status` CHECK admits only the two values 3a can actually produce. 3b widens it (adding
`'parsed'`, and whatever it needs for in-flight work) in its own migration, alongside the parser
that can set them — a value no code path can reach is a value nothing tests.

## 5. Sync integration, and the ordering subtlety

`api/services/sync.py`'s `TABLE_ORDER` is currently:

```python
("ingredients", "recipes", "recipe_items", "purchases")   # §5.5 FK order
```

Because `purchases` now references `invoice_pages`, the FK topological order must become:

```python
("ingredients", "recipes", "recipe_items", "invoices", "invoice_pages", "purchases")
```

**This reorders an existing entry rather than appending to the list** — `purchases` moves last.
That is a change to the batch-apply path every prior phase depends on, so it needs deliberate
testing, not just the new tables' own coverage. The order above is a valid topological sort:
`recipe_items` depends on `recipes` and `ingredients`, `purchases` depends on `ingredients` and now
`invoice_pages`, and `invoice_pages` depends on `invoices`.

`INSERT_FIELDS` / `UPDATE_FIELDS` allowlists gain entries for both new tables, and the Swift side
gains matching `LocalStore` schema, record types, `LocalEdits` helpers, and `SyncEngine` handling.

## 6. Storage

Private bucket; object path `{org_id}/{invoice_uuid}/{page_no}.jpg`, per the parent spec §10. RLS
policies for both new tables mirror the existing `0004` org-scoping policies; the cross-org RLS
test (parent spec §14) extends to cover them.

Two endpoints, not one:

- **Mint** a pre-signed PUT URL for a given page. The server derives the object path from the page's
  own `(org_id, invoice_id, page_no)` and refuses a client-supplied path that disagrees — the client
  computing the same key deterministically (§4) is what makes retries idempotent, not a licence to
  choose where bytes land.
- **Confirm** the upload, recording `sha256`, `width`, and `height` against the page row. This is
  the step §4 refers to. It exists because a pre-signed PUT succeeding tells the *client* the bytes
  arrived but leaves the server with no record that they did; without it, `storage_path` is a claim
  no one checked, and 3b's worker would be dispatching against pages that may not exist.

## 7. iOS capture

Capture uses `VNDocumentCameraViewController` — the system document *scanner*, with edge detection,
perspective correction, shadow removal, multi-page, and per-page retake. §12 step 1 permits this
explicitly and calls it the single highest-leverage lever on parse quality; it does not contradict
the parent spec's D4, which rejected on-device *OCR*.

Before a page is accepted, two gates run, failing to a "retake this page" prompt:

1. a minimum long-edge resolution, and
2. a variance-of-Laplacian sharpness threshold.

Both are plain image processing (Accelerate / Core Image), not text recognition, so they stay clear
of the on-device-OCR prohibition.

**Neither threshold has a value in this spec, deliberately.** A sharpness cutoff picked from
intuition either passes blurry pages or rejects good ones, and the only honest way to set it is
against real invoice photographs. The plan fixes both numbers, and states how it calibrated them.
The same applies to the eviction bounds in §8. These are the one place 3a and 3b touch: the
bad-photo fixture set that gates 3b is also the natural calibration set for these gates, so if it
arrives early, use it here.

### 7.1 Write order

§12 step 3 requires the row and storage key to be persisted **before** the upload starts.
Concretely, in this order:

1. mint the `invoices` and `invoice_pages` rows locally, including the derived `storage_path`;
2. write the JPEG into the app container at
   `Application Support/invoices/{invoice_uuid}/{page_no}.jpg`, under `NSFileProtectionComplete`
   (§13);
3. enqueue the sync ops for the rows;
4. enqueue the upload.

Nothing is lost by a failure at any point after capture, because both the row and the bytes are on
disk before a single network call.

## 8. The upload queue

A new local table — `page_id`, `local_path`, `state`, `attempts`, `last_error`, `created_at` —
deliberately **separate from `pending_ops`** (D2). It drives a hand-rolled
`URLSessionConfiguration.background(withIdentifier:)` plus `uploadTask(with:fromFile:)` against the
pre-signed URL; the parent spec §12 step 3 already notes the Supabase Storage SDK cannot drive a
background session and says to budget for hand-rolling it.

Retries use backoff. **The local file is never deleted until storage acknowledges** (§13).

**Eviction (3a-D4):** oldest-first, bounded by both age and total bytes, and applied *only* to pages
that have already uploaded. A page that has not uploaded is never evictable, at any age or size.

## 9. The unsynced badge

§13 requires a visible, non-dismissable "N changes not yet synced" badge, because
delete-and-reinstall is standard restaurant IT and destroys the local container while the Keychain
token survives.

**That count must now include pending uploads, not just pending ops.** A captured-but-unuploaded
invoice page is unsynced data living only in the app container; leaving it out of the count would
make the app read as safe in precisely the situation §13 exists to prevent.

## 10. Photo-assisted manual entry (3a-D1)

From an invoice, the owner views a page and keys purchases in against it, with the page image
visible while typing. Each resulting purchase carries `invoice_page_id`, giving an audit trail from
cost back to source document — and giving 3b's confirm screen the linkage it will need.

This reuses the existing purchase-entry validation and op-minting path unchanged; the only additions
are the page-image presentation and the `invoice_page_id` it passes through.

## 11. Error handling

Inherits the parent spec §13 governing rule — never let a server-side problem cost the owner local
data — with these specifics:

- **Upload failures** retry with backoff; the local copy survives until storage acknowledges.
- **Capture interrupted** (backgrounded, killed) leaves already-written pages intact; the invoice is
  resumable rather than restarted.
- **Identity switch** binds invoice rows and local image files to `(user_id, org_id)` exactly as the
  local store already does — a switch refuses to flush and offers export, and image files are part
  of what must be exported and erased.
- **Storage rejects the pre-signed URL** (expired, revoked) is retryable per-page and never silently
  dropped, matching §13's rule for parse failures.

## 12. Testing

| Layer | Coverage |
|---|---|
| Kit unit tests | Upload-queue state machine; eviction policy (including "never evict an un-uploaded page"); deterministic `storage_path` derivation; the new tables' `LocalEdits` helpers |
| Backend (pytest, real Postgres) | Both new tables' RLS under the existing cross-org test; the reordered `TABLE_ORDER` batch-apply path (§5), asserted directly rather than incidentally |
| Sync scenarios | An invoice and its pages captured offline and pushed on reconnect; a retaken page tombstoning and replacing its predecessor without violating the live-only unique |
| XCUITest acceptance | Capture → upload → photo-assisted purchase → synced, against a real local stack |

**The simulator has no camera**, so `VNDocumentCameraViewController` cannot be driven by XCUITest at
all. The acceptance test therefore requires a `UITEST`-gated injection point that supplies a fixture
image where the scanner's output would otherwise land. This must be designed in from the start:
Phase 2b shipped with swipe-to-remove permanently unautomatable because no such seam existed, and
that gap now needs a manual device pass before every release.

## 13. What 3a hands to 3b

Pages captured, stored, uploaded, and addressable by a deterministic storage key; the
`purchases.invoice_page_id` link; and a working photo-assisted entry path for parse failures to fall
back to. 3b then adds `invoice_line_items`, the vision-LLM worker, the review-and-confirm screen,
and `source='ocr'` — gated, per the parent spec §12, on a fixture set of genuinely bad photos
(crumpled, thermal, glare, folded) assembled and passing **before any LLM spend is approved**.

## 14. Deferred, with triggers

| Deferred | Trigger to revisit |
|---|---|
| Invoice-level metadata (vendor, invoice number, totals) | 3b's parser can populate it without the owner keying it |
| PDF and photo-library import | An owner reports invoices arriving by email rather than on paper |
| Multi-invoice batch capture | Owners routinely photograph a stack in one sitting |
| Server-side image re-compression | Storage cost becomes material, or upload times on kitchen Wi-Fi prove painful |
