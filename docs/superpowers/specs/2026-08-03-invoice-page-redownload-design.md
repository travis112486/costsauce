# Design: closing the eviction loop — signed page re-download and a wired sweep

Phase 3a shipped a "bounded image cache" that is bounded in policy only.
`ImageEviction` is pure, tested, and has **zero callers**: nothing sweeps, so
the cache grows without ceiling exactly as if the policy did not exist. The
obvious fix — wire the sweep — is unsafe on its own, because an evicted page
is currently unrecoverable: `InvoicePageView` says "Photo Not on This
Device" and there is no endpoint that could get it back. Wiring a sweep
today would start permanently destroying invoice photographs.

So the two 3a deferrals are one piece of work, and this document specifies
it: **pages become re-downloadable, and only then does the sweep turn on.**

Neither half needs the vision-LLM vendor choice or the bad-photo fixture
set. Both were filed under 3b only because that is when the download
endpoint was expected to arrive.

---

## 1. Scope

**In:**

- A signed-download endpoint mirroring the existing signed-upload one.
- `InvoicePageView` re-downloading an evicted page on demand.
- A sweeper that actually deletes evictable files, driven by the existing
  pure policy.
- The storage stub and runbook changes the acceptance walk needs.

**Out (unchanged from 3a's deferral list):**

- Background (`BGTaskScheduler`) sweeping. The sweep entry point is written
  once and a background trigger can call it later; scheduling is a separate,
  smaller decision. See §4.
- Calibrating `PageQuality`'s thresholds or `ImageEviction`'s budget. Both
  remain the defensible-starting-point values 3a shipped and both still say
  so in their source.
- Prefetching. Nothing downloads a page the user has not asked to see.

---

## 2. Backend: one new endpoint

`POST /invoices/{invoice_id}/pages/{page_no}/download-url`

A near-exact mirror of `mint_upload_url`, reusing `_invoice_org` and
`storage_path` unchanged, so the key a download resolves against is by
construction the key the upload wrote to.

### 2.1 Why not proxy the bytes

The rejected alternative was `GET …/image` streaming the JPEG through
FastAPI. It saves a round trip and costs the architecture: 3a deliberately
split transport in two — rows through the sync protocol, bytes direct to
storage — precisely so a stalled multi-megabyte page cannot sit in front of
the op queue. Proxying puts image traffic back through the API process and
gives up that separation for one saved request.

The other rejected alternative was embedding signed URLs in the sync pull.
URLs expire in an hour, so every page not opened immediately carries a dead
URL, and it mints one for every page whether or not anyone ever looks.

### 2.2 Confirmed-only, and the status code that says so

The endpoint reads the page row first:

```sql
SELECT sha256 FROM invoice_pages
 WHERE invoice_id = %s AND page_no = %s AND deleted_at IS NULL
```

- Row absent, or the invoice is another org's → **404**, via `_invoice_org`,
  exactly as the upload endpoints do. Distinguishing "absent" from "not
  yours" would leak the existence of another org's invoice.
- Row present but `sha256 IS NULL` → **409**. The page exists and is
  legitimately ours, but its bytes were never confirmed, so a signed URL
  would resolve to nothing in the bucket. 404 would be a lie about a row the
  caller can see in its own list; 409 says "this page is not in a state that
  has bytes", which is the truth and is actionable.
- Otherwise → 200 with `{"url": ..., "expires_at": ...}`.

`sha256` is the right gate rather than the upload outbox because the outbox
is per-device local state: a page uploaded from the owner's phone must be
downloadable on the bookkeeper's.

### 2.2.1 Why the sweep can never strand a page

These two gates use different signals (§4.1 uses the outbox), and the
relationship between them is what makes the whole feature safe, so it is
worth stating outright:

> The outbox only reaches `uploaded` when the PUT **and** the confirm both
> succeeded. Confirm is what writes `sha256`. Therefore
> **outbox `uploaded` ⟹ the server has `sha256` ⟹ the download endpoint
> returns 200.**

The sweep deletes only pages whose outbox says `uploaded`, so **every file
the sweep is permitted to delete is, by construction, one the download
endpoint can give back.** The 409 branch in §2.2 is consequently unreachable
for any page this device evicted; it exists for pages that were never
successfully uploaded from anywhere and therefore never had a local file to
lose either.

### 2.3 A gotcha that will silently break a copy-paste

Supabase's two signing endpoints do not agree on their response shape:

| operation | endpoint | response key |
|---|---|---|
| upload | `POST /storage/v1/object/upload/sign/{bucket}/{path}` | `url` |
| download | `POST /storage/v1/object/sign/{bucket}/{path}` | `signedURL` |

`sign_put` reads `response.json()["url"]`. A `sign_get` written by copying it
would raise `KeyError` at runtime against real Supabase while passing
happily against a stub that returned `url`. **The exact key must be verified
against the real response during implementation and pinned by a test that
asserts the stub and the production reader agree.** This document records
the expectation, not a verified fact.

---

## 3. `ImageEviction`: inject the budget

Today the policy reads two module-level `static let`s. The sweep needs real
values and the acceptance walk needs tiny ones, so the budget becomes a
parameter:

```swift
public static func evictable(
    candidates: [Candidate],
    now: Date,
    maximumBytes: Int = ImageEviction.maximumBytes,
    maximumAge: TimeInterval = ImageEviction.maximumAge
) -> [String]
```

The statics stay as the defaults, so every existing `ImageEvictionTests`
case passes untouched, and the function stays pure. Under `UITEST=1` the
sweeper injects a budget small enough that one captured page exceeds it,
which is what lets the walk prove a real file was really deleted — the same
seam rule as `AppModel.pageSource` substituting the camera and
`BackgroundUploader` substituting an ephemeral session. Production reads the
defaults.

---

## 4. The sweeper

**Trigger: `scenePhase → .active`, and once at the end of a capture
session** — after the whole scan is ingested, not after each page. Sweeping
between pages of one multi-page invoice would measure a cache that is still
mid-growth and could evict page 1 while page 3 is still being written.

No entitlement, no `Info.plist` task identifiers, and fully driveable from
XCUITest, so the sweep is covered by automation rather than joining the
manual-device-pass list. Sweeping only while the app is in use is sufficient
because the cache only *grows* while the app is in use.

`BGTaskScheduler` is deliberately deferred, not rejected. The sweep is a
single `async` entry point; a background task can call the same function
later without rewriting it.

### 4.1 New store query

`LocalStore.evictionCandidates()` returns, for every live page, its id,
`invoice_id`, `page_no`, `created_at`, and whether its `pending_uploads` row
has reached `uploaded`.

The query returns rows; **the sweeper filters to those that actually have a
file on disk** before measuring. Pages pulled from another device have a row
and no file, so they must not appear in the byte total — counting bytes that
are not there would evict real files to get under a budget the device was
never over.

**`isUploaded` comes from the outbox, not from the row's `sha256`.** A page
this device just uploaded does not have a local `sha256` until a later pull
brings the server's confirmation back. Trusting `sha256` would make a
freshly-uploaded page look un-uploaded — harmless — but the converse matters
more: the outbox reaching `uploaded` is the only local proof that storage
acknowledged, and `ImageEviction`'s core invariant is that an un-uploaded
page is never deleted at any age or size, because until then the local file
is the only copy in existence.

### 4.2 `ImageSweeper` (app target)

Lives in the app target, not the Kit, because it needs `FileManager` and
`InvoiceFiles`. It stats each candidate's file for its byte count, hands the
measurements to the pure `ImageEviction`, and deletes the returned pages'
files through the existing `InvoiceFiles.delete(atPath:)`.

**It deletes files, never rows.** The `invoice_pages` row survives eviction;
that is what makes the page re-downloadable and what keeps the purchase's
`invoice_page_id` provenance link intact.

---

## 5. `InvoicePageView`: three states

| condition | behaviour |
|---|---|
| local file exists | show it (unchanged) |
| no file, download succeeds | show the in-memory image |
| no file, offline | "Photo Needs a Connection" + **Retry** |
| no file, download fails (incl. 409) | "Photo Couldn't Be Loaded" + **Retry** |

"Offline" means a transport-level failure — no route to the host. Every
other outcome, including the 409 of §2.2, is the generic error state: a 409
is unreachable for a page this device evicted (§2.2.1), and inventing a
third message for a case the user cannot act on differently is not worth the
string.

### 5.1 Memory only

A re-downloaded page is held as a `UIImage` for as long as the view is up and
is **never written back to disk**.

Writing it back would thrash. The age rule evicts any uploaded page older
than 90 days regardless of total size, so a restored old page would be
deleted again on the very next foreground sweep — and old invoices are
exactly the ones people re-open, during a dispute. Memory-only also keeps
`ImageEviction`'s arithmetic exactly as tested, requires no new column, and
preserves a clean invariant: **the disk cache holds only pages this device
captured.**

The cost is that re-opening the page after an app restart downloads again.
That is acceptable for a rare, deliberate act.

### 5.2 The purchase button never disables

"Add purchase from this page" stays enabled in **every** state, including
offline-with-no-photo. Someone standing in a walk-in cooler with no signal
and the paper invoice in their hand must still be able to key the purchase
in. Photo-assisted entry is an aid, not a precondition — the same reasoning
that made 3a's quality gates err toward accepting.

---

## 6. Testing

**Backend**
- 200 and a well-formed URL for a confirmed page.
- 409 for a page whose `sha256` is null.
- 404 for another org's invoice, and for an absent one.
- The response-key pin from §2.3.

**Kit**
- `evictable` with injected budgets: age-only eviction, size-only eviction,
  and the invariant that an un-uploaded page is never returned.
- `evictionCandidates()` reports `isUploaded` from the outbox state,
  including the just-uploaded-but-not-yet-pulled case.

**XCUITest** — extends the existing 3a walk rather than adding a journey:
capture → force a sweep under a tiny `UITEST` budget → assert the fallback
state appears → re-download → assert the image returns.

### 6.1 The storage stub must retain bytes

Today `storage_stub_3a.py` discards PUT bodies, because 3a's proof of
arrival was the confirm row rather than storage's copy. A download test
needs the bytes back, so the stub gains an in-memory `{path: bytes}` map, a
`POST /storage/v1/object/sign/…` branch, and a `GET` that serves what the
PUT stored. This is a change to the runbook's stub listing, and
`docs/runbooks/phase-3a-acceptance.md` must be updated in the same commit —
a runbook whose stub no longer matches the tests it documents is worse than
no runbook.

---

## 7. Deployment note

No new prerequisites. The signed-download path uses the same private
`invoices` bucket and the same `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`
that 3a already requires.

---

## 8. What this leaves for later

- Background sweeping (§4).
- Budget and quality-threshold calibration, still waiting on the bad-photo
  fixture set.
- Everything on the 3a manual-device-pass list; this work adds nothing to it.
