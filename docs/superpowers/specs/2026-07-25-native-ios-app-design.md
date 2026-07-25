# CostSauce — Native iOS App: Design

**Date:** 2026-07-25
**Status:** Design approved pending user review of this document
**Supersedes:** the iOS-related items in `NEXT_STEPS.md` Stages 2–4

---

## 1. Context

CostSauce today is a single-tenant FastAPI + SQLite demo (`product/app.py`, ~880 lines) with a
static marketing site (`site/`) and a live Vercel deployment. It has no accounts, no tenancy, no
automated invoice ingest, and no tests.

The business already sells what this design must support: $49/$99/$149 tiers, a Pro tier promising
three locations and multiple users, and an ICP of owner-operators who photograph supplier invoices
on their phones.

This document specifies the native iOS app and the backend it requires. A design review by five
independent adversarial lenses (sync correctness, security/tenancy, iOS architecture, App Store
compliance, data migration) produced 39 findings, of which 28 survived refutation. Their conclusions
are folded in below rather than recorded separately.

### Defects in the current system that this design must fix

These were confirmed by execution, not inspection:

| ID | Defect | Location |
|---|---|---|
| B1 | An unvalidated `date` string is committed, then crashes the drift engine. Every drift endpoint returns 500 permanently. No `DELETE` endpoint exists, so recovery needs manual SQL. | `product/app.py:404`, `:657`, `:164` |
| B2 | Invoice upload accepts any file type; `/uploads` is served via `StaticFiles`, so an uploaded `.html` returns as `text/html` on the same origin (stored XSS). | `product/app.py:830-849`, `:373` |
| B3 | `ceil_to_half(plate_cost / (target/100))` returns **$14.50 where the exact answer is $14.00**. 127 realistic plate-cost/target combinations are exactly $0.50 high. **Three implementations, three behaviours:** `product/app.py:149` and `product/static/js/app.js:566-570` both round a float with no guard; `site/js/calculator.js:60` works in integer cents *with* a `1e-6` epsilon (`Math.ceil((cents - 1e-6) / stepCents) * stepCents`) but still float-divides at `:136`. The marketing calculator and the product therefore disagree on boundary values today. All three must converge on §8's exact formula. | `product/app.py:149`, `:217`; `product/static/js/app.js:566-570`; `site/js/calculator.js:60`, `:136` |
| B4 | `status` compares unrounded `fc_pct` to target while displaying the rounded value, so 30.04% renders "30.0%" and is flagged `watch`. | `product/app.py:211`, `:224` |
| B5 | `todayISO()` uses `toISOString()`, so a 6pm PST purchase is dated tomorrow. | `static/js/app.js:78` |
| B6 | Seed data attaches invented prices and invented drift percentages to real trademarked distributors (Sysco, US Foods, Reinhart, FreshPoint, Regalis). | `product/app.py:254-263` |

B3 is shipped and actively tells restaurant owners to overprice dishes. It is fixed in Phase 1b, and
the JS duplicate is fixed in Phase 1d.

---

## 2. Locked decisions

Settled during brainstorming and review. Not to be relitigated during implementation.

| # | Decision | Rationale |
|---|---|---|
| D1 | Full-parity native iOS client; web client remains at full parity | User requirement |
| D2 | Local-first with sync, not a thin client | Restaurant back-of-house has poor connectivity; the owner holds the invoice where the signal is worst |
| D3 | Org → locations in the schema from day one | Retrofitting tenancy means migrating every table and rewriting every query |
| D4 | Server-side vision-LLM invoice parsing only; no on-device OCR | Best accuracy on crumpled thermal invoices; least parsing code to maintain |
| D5 | Auth = email magic link + Sign in with Apple | SIWA is **not** required by guideline 4.8 (that applies only to third-party *social* login). It is kept for iOS signup conversion, as a deliberate choice |
| D6 | Supabase (Postgres, RLS, Auth, Storage) + FastAPI as the compute service | Buys the auth/tenancy subsystem; preserves the working drift and costing logic |
| D7 | **Multi-user ships fully in v1** | The pricing page already sells it; it changes roles, Storage policies, deletion semantics and entitlement, so it is cheaper to build than to retrofit |
| D8 | **Account deletion uses a 30-day grace period with export-first** | Kinder to an owner who fat-fingers it; requires the retention window be stated in the privacy policy |
| D9 | **US-only App Store release; external link to manage plan** | Guideline 3.1.1(a) permits a plain external link with no entitlement and 0% commission. Matches the US-only ICP and keeps Stripe |
| D10 | **SIWA retained, with a separately verified contact email required at onboarding** | Apple private-relay addresses would otherwise silently break the weekly drift digest, the stated churn mitigation |

Explicitly rejected: StoreKit IAP (15–30% on a $49–149/mo product, plus per-Apple-ID entitlement that
breaks D7); Firebase/Firestore (NoSQL against deeply relational costing data); all-custom
FastAPI + Neon (hand-rolled auth and tenancy is where security bugs breed). CRDTs and hybrid logical
clocks are **not adopted now** — distributed-systems machinery for a one-or-two-device workload — but
they are deferred rather than permanently rejected; see §17 for the trigger that would revive them.

---

## 3. Architecture

```
   ┌──────────────────┐        ┌──────────────────┐
   │   iOS (SwiftUI)  │        │   Web SPA        │
   │  local store =   │        │  (existing site  │
   │  source of truth │        │   + migration)   │
   │  when offline    │        │                  │
   └────────┬─────────┘        └────────┬─────────┘
            │  auth, image upload       │
            │       ┌───────────────────┘
            │       ▼
            │   ┌───────────────────────────┐
            │   │  Supabase                 │
            │   │  • Postgres 17 + RLS      │
            │   │  • Auth (magic link, SIWA)│
            │   │  • Storage (invoice pages)│
            │   └───────────┬───────────────┘
            │  sync+compute │
            └───────┬───────┘
                    ▼
        ┌───────────────────────────┐
        │  CostSauce API (FastAPI)  │
        │  • normalization kernel   │
        │  • drift engine           │
        │  • recipe costing         │
        │  • sync endpoints         │
        │  • invoice parse worker   │
        └───────────┬───────────────┘
                    ▼
        ┌───────────────────────────┐
        │  Vision LLM (Phase 3)     │
        └───────────────────────────┘
```

**Both clients call FastAPI for data operations** so normalization and fuzzy matching have one
authoritative implementation. Auth and image upload go directly to Supabase.

**Supabase project:** `khohfrfqzbieaiikqlsa` (`CostSauce-Prod`), region `us-east-2`, Postgres 17.6.1.

### 3.1 The costing kernel exists in three languages

Offline plate-cost display requires the math on-device, and the web SPA already has its own copy.
Python, Swift, and JavaScript each implement it. This is accepted, and constrained by a shared
contract (§9).

---

## 4. Data model

### 4.1 Tenancy

```
organizations (id uuid pk, name, plan, sync_counter bigint not null default 0,
               deletion_scheduled_at timestamptz null, created_at)
memberships   (id uuid pk, user_id uuid → auth.users, org_id uuid → organizations,
               role text check (role in ('owner','manager','bookkeeper')), created_at)
locations     (id uuid pk, org_id uuid → organizations, name,
               target_fc_pct numeric(5,2), drift_threshold_pct numeric(5,2))
profiles      (user_id uuid pk → auth.users, apple_sub text unique null,
               contact_email citext not null, contact_email_verified_at timestamptz null)
```

The global `settings` key-value table (`app.py:87`) is retired; its values become `locations`
columns. Defaults (30, 5) move to column defaults.

### 4.2 Sync columns

Every syncable table (`ingredients`, `purchases`, `recipes`, `recipe_items`, `invoices`,
`invoice_pages`, `invoice_line_items`) carries:

| Column | Purpose |
|---|---|
| `id uuid` | **Client-minted.** An offline device must create rows without a round trip |
| `location_id uuid` | Explicit tenancy path on every table, including children |
| `client_mutated_at timestamptz` | Device clock. **The only input to conflict resolution.** Server rejects values more than 5 minutes in the future |
| `server_seq bigint` | Allocated from `organizations.sync_counter` under `FOR UPDATE` **in the same transaction as the row write**. The sync cursor |
| `updated_at timestamptz` | Server-stamped. **Display only.** Never read by sync logic |
| `deleted_at timestamptz` | Tombstone. Monotonic: `NULL → timestamp` only, enforced by a `BEFORE UPDATE` trigger |

Splitting these three timestamps is not incidental. A single server-stamped `updated_at` used for
both LWW and the cursor means *last device to reconnect wins* (a 30-day-stale iPad edit beats
today's phone edit), and means rows committed out of timestamp order are filtered out of the cursor
window permanently with no self-heal.

`recipe_items` additionally carries `UNIQUE (recipe_id, ingredient_id)` — see §5.4.

### 4.3 Ordering

`get_ingredient_drift` currently relies on `ORDER BY date DESC, id DESC` (`app.py:157`), using
`AUTOINCREMENT` as an insertion-order tiebreaker. Same-date ties are routine: one invoice with two
chicken-breast lines, a split delivery, a CSV import. Random UUIDs make the winner a coin flip, and
the winner determines `latest_price`, which determines plate cost, drift, status, and suggested
price.

- `purchased_on date NOT NULL` — a real date type; window math is integer-day arithmetic, never
  `Date`/`Calendar`
- `recorded_at timestamptz NOT NULL` — client mint time, carried through sync
- UUIDv7 for primary keys, for tiebreak determinism (not for index locality; at ~10k rows/year that
  is irrelevant)

**The single written rule, used identically in all three languages:**
`ORDER BY purchased_on DESC, recorded_at DESC, id DESC`

### 4.4 Invoices

```
invoices          (id, location_id, captured_at, parse_status, …)
invoice_pages     (id, invoice_id, page_no, storage_path, width, height, sha256, parse_status)
invoice_line_items(id, invoice_id, page_no, line_no, raw_text, parsed_qty, parsed_unit,
                   parsed_total, confidence, …, UNIQUE (invoice_id, page_no, line_no))
```

One row per filename cannot represent a three-page US Foods invoice. Storage keys are a
deterministic function of the client-minted invoice UUID plus page number, so a retry overwrites
rather than duplicating.

---

## 5. Sync protocol

```
GET  /sync?since=<server_seq>   → rows with server_seq > cursor, ORDER BY server_seq, tombstones included
POST /sync                      → batch of local changes; returns per-row results and a new cursor
```

### 5.1 Cursor

`server_seq` is allocated from a per-org counter under `SELECT sync_counter FROM organizations
WHERE id=$org FOR UPDATE` inside the write transaction. This serializes allocation with commit order
by construction. At ~10k writes/year/location the row lock costs nothing.

Rejected alternatives: a `sync_changes` table with AFTER triggers and a `pg_snapshot_xmin`
watermark (real infrastructure for a one-restaurant workload); a `now() - safety_lag` cursor
(correct only while every transaction stays under a tunable).

### 5.2 Conflict resolution

Last-write-wins on `client_mutated_at`, applied **per changed field, not per row**.

The client tracks which fields changed and sends only those. Without this, a device that edited only
`recipes.name` pushes a whole row carrying a stale `menu_price` and wins — silently reverting a
price the owner set. No per-field timestamp columns and no merge UI are needed; the discipline is
simply not sending fields you did not change.

### 5.3 Idempotency

Every change carries a client-minted `op_id` uuid; every batch a `batch_id`.

```
sync_ops (op_id uuid pk, org_id uuid, applied_at timestamptz, result_json jsonb)   -- 7-day TTL
```

Written in the **same transaction** as the mutation. Replaying a known `op_id` returns the stored
result and touches nothing.

This replaces the naive "dedupe on row id + `updated_at`", which is uncomputable by a client that
never sees the server-stamped value.

### 5.4 Recipe items

`update_recipe` (`app.py:790`) deletes all `recipe_items` and re-inserts them on every save. Ported
to client-minted UUIDs with soft deletes, one offline edit plus one online edit yields a five-line
burger with ten rows: plate cost $3.31 → $6.62, status flips to `danger`, and the app recommends
repricing from $11.00 to $22.50. Every individual row converges correctly, so nothing detects it.

Fix: `UNIQUE (recipe_id, ingredient_id)`; save becomes an upsert diff (update qty in place, insert
new lines, tombstone removed lines); both clients round-trip `item.id`, which
`static/js/app.js:469` does not do today.

Rejected: collapsing items into a JSONB column (destroys "which recipes use this ingredient", which
the merge endpoint and the in-use guard both need); `items_version` + 409 + merge dialog
(over-built for a five-line list).

### 5.5 Apply semantics

- Batches apply in FK topological order — ingredients → recipes → recipe_items → purchases — in one
  transaction
- A multi-page pull applies as one local transaction; the cursor advances only on commit
- `GET /sync` has a hard page cap
- Clients expose `sync_state` (`caught_up` / `catching_up`) and **suppress `suggested_price` while
  not caught up**
- Per-row 403s move to a terminal "needs attention" state with UI, never an infinite retry

---

## 6. Identity, auth, and deletion

### 6.1 Identity keys on provider `sub`, never on email

Magic link creates user U1. The same human later signs in with Apple using Hide My Email; Supabase
does not link them; U2 is created with zero memberships; the owner opens the app to zero recipes and
zero price history. That is a churn event.

The reflexive fix — linking on matching email — is an account-takeover primitive, and Apple's
forwarding address can change while `sub` stays stable.

- `profiles.apple_sub` persists Apple's `sub`; identity keys on it
- An Apple sign-in resolving to a user with no membership does **not** auto-create an org. It offers
  "connect this Apple ID to your existing CostSauce account", gated by a magic-link round trip to the
  original address, then `linkIdentity()`
- `profiles.contact_email` is separately supplied and verified at onboarding (D10), and is what drift
  digests and alerts use
- The sending domain and every from-address are registered with Apple for Email Communication, with
  SPF verified and bounces monitored

### 6.2 Deletion (D8 — 30-day grace, export first)

Guideline 5.1.1(v) requires in-app account deletion, reachable without contacting support. With
multi-user (D7) there are two distinct operations:

**Delete my account** — if the caller is *not* the last owner, removes only their `memberships` row
and their `profiles` row. Immediate. Org data is untouched. If the caller **is** the last owner, this
action does not silently orphan the organization: it presents the "delete organization" flow below
and requires that confirmation instead. An owner may alternatively transfer ownership to another
member first, after which their own deletion is the ordinary membership case.

**Delete organization** — available to owners. On confirm, immediately:
- set `organizations.deletion_scheduled_at = now()`
- cancel the Stripe subscription
- revoke Sign in with Apple via Apple's `/auth/revoke` (mandatory for SIWA accounts)
- offer a full data export (CSV of ingredients, purchases, recipes; invoice images as a zip)
- client wipes its local store and photo cache, then signs out

After 30 days a scheduled job hard-deletes the org, all locations, ingredients, purchases, recipes,
recipe_items, invoices, invoice_pages, invoice_line_items, and every Supabase Storage object under
the org prefix. Within the window an owner may cancel and restore.

**`POST /sync` checks `deletion_scheduled_at` before applying any batch** and discards writes for a
scheduled-deleted org. A device offline through the deletion must not resurrect the data.

The 30-day window and what is retained during it must be stated in the privacy policy.

---

## 7. Security and tenancy

The claim that RLS provides defense-in-depth is false if FastAPI holds a privileged role — it is the
only DB client on the data path, so a `service_role` connection bypasses RLS 100% of the time.

- **Named role:** `app_user`, `NOINHERIT`, **no `BYPASSRLS`**, not the table owner
- **Per pooled checkout, in a transaction:**
  `SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', $1, true)`.
  `SET LOCAL` only — a session GUC surviving a connection checkout hands org B org A's claims
- `ALTER TABLE … FORCE ROW LEVEL SECURITY` on every tenant table
- Every policy carries **`WITH CHECK` as well as `USING`**, written against the `memberships`
  subquery rather than a JWT claim (required for D7 multi-user)
- **`POST /sync` strips `org_id`/`location_id` from the payload** and re-derives them from
  `sub → memberships`. Each row's `location_id` must be in the caller's org or the row fails
- JWT validation checks audience, issuer, and expiry, and handles key rotation

### 7.1 Every ported query carries an org predicate

`find_ingredient_match` (`app.py:110`) runs `SELECT id, name FROM ingredients` across the whole
table and substring-matches. This is not primarily a security problem — it is a **guaranteed
correctness failure at customer #2**, whose "chkn brst" binds to customer #1's ingredient row.

### 7.2 Storage

- Private bucket; path `{org_id}/{invoice_uuid}/{page_no}.jpg`
- Policies key on **org membership, not `auth.uid()`** — the Supabase reference policy keys on the
  uploading user and would break D7 multi-user
- Uploads are validated: either routed through FastAPI (magic-byte check, re-encode to JPEG, which
  also strips EXIF and kills polyglots, Content-Type set server-side) or via a signed upload URL with
  anything whose sniffed type is not `image/*` quarantined. **Signed URLs alone do not fix B2** — the
  Storage SDK's `contentType` is caller-supplied and replayed on GET
- Downloads set `Content-Disposition: attachment` and `X-Content-Type-Options: nosniff`
- The vision worker receives a narrow per-job signed URL, never a service key

---

## 8. Money and the numeric contract

`ceil_to_half(4.20/0.30)` returns $14.50 where the exact answer is $14.00 (B3). Swift `Double`
reproduces the bug identically, so a golden vector captured from current output would **pass**.

```
total_price      numeric(12,2)
qty_base_units   numeric(14,4)
unit_price       numeric(14,6) GENERATED ALWAYS AS (total_price / qty_base_units) STORED
menu_price       numeric(10,2)
target_fc_pct    numeric(5,2)
```

- Suggested price computes as `ceil(plate_cents * 100 / target_pct / 50) * 50` — never
  `/(target/100)`
- `unit_price` is generated, not stored independently. Today `create_purchase` rounds `base_qty`,
  `total_price` and `unit_price` separately, so qty × unit_price never reproduces total_price —
  fatal on the invoice-confirm reconciliation screen the OCR flow requires
- `status` compares the **rounded** `fc_pct` against target (fixes B4)
- Golden vector expectations come from an **exact rational oracle**, never from current Python
  output, compared as exact strings with zero tolerance

Not adopted: "Decimal end to end." Display-rounding divergence between Python `round()` and Swift
`.rounded()` is cosmetic. The load-bearing subset is exact `ceil_to_half`, the generated
`unit_price`, and an honest oracle.

---

## 9. The shared kernel and golden vectors

`normalize_name`, `find_ingredient_match`, `WEIGHT_TO_LB`, `normalize_purchase`, the drift window,
the costing formula, and the ordering rule form a kernel contract implemented in Python, Swift, and
JavaScript.

`golden-vectors.json` is committed once and run by pytest, XCTest, **and a JS test target**. The
web SPA is a real third implementation: `static/js/app.js:566-570` duplicates ceil-to-half and
consumes a 2-decimal-rounded `latest_price` from `:506`, so the web recipe preview and the saved
plate cost already disagree today.

Two vector classes are required:

1. **Value vectors** — pre-selected inputs → exact expected outputs. Cases must include `case` /
   `qty_in_case`, kg/g → lb, and the `base_unit == 'each'` rejection path
2. **Row-selection vectors** — *unordered row sets* covering same-date ties, tombstones, and boundary
   dates at exactly −90 and −91 days. Pre-sorted inputs encode the ordering rather than testing it,
   so they cannot catch a broken tiebreak

---

## 10. Drift engine port

Preserve the existing semantics exactly, then make them honest and set-based:

- Baseline is `rows[1:]` — **excluded by position, so same-date siblings remain in the baseline**.
  Use `rn > 1`, not `purchased_on < latest_on`; the latter silently changes results for multi-line
  invoices
- The 90-day window is anchored on `latest_date`, **not today**
- Add `WHERE deleted_at IS NULL` to drift row selection
- Return `baseline_n` and `window_start`; **refuse to emit `drift_pct` below a small baseline floor**
  rather than returning the current dishonest `0.0` (`app.py:167`)
- Collapse the N+1: `dashboard()` calls `get_ingredient_drift` per ingredient and `cost_recipe` calls
  it again per item — roughly 1700 round trips per dashboard load at stated scale, each re-fetching
  full purchase history and re-evaluating RLS. Survivable in-process against SQLite; not survivable
  over a network. Use one windowed set-based query

### 10.1 Completeness contract on `cost_recipe`

`app.py:186` is an INNER JOIN with no error branch and `:195` falls back to `price = 0.0`. An
ingredient with no purchases makes a dish cost $0 forever — **already true today**. Sync adds two new
routes into that state (tombstones arriving over sync; partial-failure retry landing `recipe_items`
before `ingredients`), and the in-use guard at `:578` is an endpoint check that no sync writer
inherits.

- LEFT JOIN with a per-item `is_resolvable` flag
- If any component is missing, tombstoned, or has no purchase history: return `plate_cost` with
  `complete: false` and **`status` and `suggested_price` null**
- Never emit a reprice recommendation from a partial cost

**Generalized rule: any invariant enforced only in a route handler is unenforced on the sync path.**
The ones that matter move into deferred constraint triggers. FKs are added `NOT VALID` then
validated.

---

## 11. Offline ingredient creation and merge

The kernel has one authoritative implementation on the server, *and* purchases must be enterable
offline with an immediate plate cost. Both cannot be true without a merge path: an offline delivery
mints a duplicate ingredient UUID with a foreign-key child, the drift alert for that item — the
entire product — silently returns 0.0 and never fires, and every recipe still points at the stale
original.

- The offline entry UX **picks from the locally-synced list with local fuzzy ranking**. "Create new
  ingredient" is a deliberate secondary action that shows the top three near-matches first
- `POST /ingredients/{keep_id}/merge {from_id}` ships day one: repoints `purchases.ingredient_id` and
  `recipe_items.ingredient_id`, tombstones the loser
- A post-sync "possible duplicates" queue is seeded by running server-side fuzzy match over
  client-minted ingredients

Retrofitting a merge against three years of forked history costs far more than building it now.

---

## 12. Invoice pipeline (Phase 3)

1. Capture via `VNDocumentCameraViewController` — the system document *scanner* (edge detection,
   perspective correction, shadow removal, multi-page, per-page retake). This is permitted and does
   not contradict D4, which rejected on-device *OCR*. It is the single highest-leverage lever on
   parse quality
2. Gate upload on a minimum long-edge resolution and a variance-of-Laplacian sharpness check, with a
   "retake this page" prompt
3. Upload via `URLSessionConfiguration.background(withIdentifier:)` + `uploadTask(with:fromFile:)`
   against a pre-signed URL. The Supabase Storage SDK cannot drive a background session; budget for
   hand-rolling it. Persist the invoice row and storage key **before** the upload starts
4. Worker sends pages to the vision LLM, writing to `invoice_line_items`
5. **The owner reviews and confirms.** Only confirmed lines become `purchases`
6. Low confidence or failure → `parse_status='failed'` → the existing photo-assisted manual entry

Never auto-write purchases from OCR. OCR will read $4.50 as $450, and B1 demonstrated how thoroughly
one bad row poisons this system.

**Phase 3 acceptance requires a fixture set of genuinely bad photos — crumpled, thermal, glare,
folded — assembled and passing before any LLM spend is approved.**

---

## 13. Error handling

Governing rule: **never let a server-side problem cost the owner local data.** The review found the
rule as originally written covered only server-side failures, so it is extended:

- **Expired auth after long offline.** Local data stays readable and editable; re-auth prompt on
  foreground; queued writes held until it succeeds
- **Delete-and-reinstall** is standard restaurant IT and destroys the local container and pending
  queue while the Keychain token survives, so the app relaunches looking healthy with Saturday's
  three deliveries gone. Required: a visible, non-dismissable "N changes not yet synced" badge; an
  "Export pending changes" action; `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`;
  `kSecAttrSynchronizable = false`; and a `didCompleteFirstRun` `UserDefaults` flag that wipes the
  Keychain before reading a token
- **Identity switch.** The local store binds to `(user_id, org_id)`. On re-auth as a different
  identity, refuse to flush; offer export; require an explicit "switch account and erase"
- **Upload failures** retry with backoff; the local copy is not deleted until storage acknowledges
- **Parse failures** are retryable per-invoice and never silently dropped
- `NSFileProtectionComplete` on the local store — another business's cost data on a lost phone is a
  real problem
- `DELETE /purchases/{id}` exists so bad data is fixable in-product (fixes B1's recovery gap)

---

## 14. Testing

The repository has zero tests today, so this is greenfield.

| Layer | Coverage |
|---|---|
| `golden-vectors.json` | Value + row-selection vectors, run by pytest, XCTest, and a JS target |
| Backend (pytest, real Postgres) | Business logic; **cross-org RLS test** — org A cannot read org B under any query; end-to-end deletion including the 30-days-offline-push-after-deletion case |
| Sync scenarios | Two offline edits asserting item **count** (not merely convergence); 30-days-offline asserting the **newer** edit wins; replay-after-concurrent-edit; reverse-commit-order |
| iOS | XCTest for local store and costing kernel; XCUITest capture → confirm smoke |
| Regression | B1–B6 locked down permanently |

The cross-org RLS test and the deletion test are non-negotiable. Everything else fails visibly; a
tenancy leak fails silently.

---

## 15. Compliance artifacts (Phase 1, not Phase 5)

- **Privacy policy URL** — a mandatory App Store Connect field (5.1.1(i)). Names the LLM provider as
  a subprocessor, what is sent, the 30-day deletion retention window (D8), and no-training. The
  subprocessor contract must be zero-retention
- **First-parse consent screen** plus a per-org "no AI parsing" switch that falls back to manual entry
- **`PrivacyInfo.xcprivacy`** — a hard upload rejection since May 2024. `NSPrivacyTracking false`,
  matching `NSPrivacyCollectedDataTypes`, and `NSPrivacyAccessedAPITypes` declarations for
  FileTimestamp / UserDefaults / DiskSpace
- **App Privacy labels** — Email, User Content (photos), Financial Info, User ID; all Linked, App
  Functionality, Tracking = No
- **Billing surface (D9).** The app is free. Sign-in only: no signup, no purchase UI, no call to
  action for purchase. Plan limits render as read-only state ("Starter — 30 of 30 invoices used"),
  never a button. A plain external "Manage plan at costsauce.com" link is permitted under 3.1.1(a).
  Entitlement is server-derived from `organizations.plan` via `/me`. **Re-verify 3.1.1(a) text at
  submission — it is under active litigation**
- **Reviewer path, built in Phase 1.** A magic-link app cannot hand App Review a password, so the
  backend needs a fixed-OTP affordance scoped to one address, rate-limited, feature-flagged, and
  asserted in tests. That account lands in a pre-populated sample org
- **Seed hygiene.** Replace real distributor names (B6) with fictional ones. The seed becomes an
  `is_sample = true` org: banner-labeled, one-tap deletable, excluded from sync into any real org.
  This satisfies both the 2.1 placeholder-content risk and the 4.2 minimum-functionality risk. Test:
  no `source='seed'` row exists in a non-sample org

---

## 16. Phase plan

**Phase 1a — Tenancy, identity, deletion.** Organizations / memberships / locations / profiles; RLS
with FORCE and WITH CHECK; the `app_user` role and `SET LOCAL` checkout pattern; magic link + SIWA
with `sub`-keyed identity and the explicit link flow; verified contact email; **full multi-user roles
and invites (D7)**; account and organization deletion end-to-end with the 30-day grace job (D8); the
reviewer OTP affordance; seed migration into a flagged sample org. Ships with the cross-org RLS test
and the deletion test. **No sync yet.**

**Phase 1b — Engine port.** NUMERIC money and generated `unit_price`; ordering columns and the
written ORDER BY rule; the set-based drift query preserving `rows[1:]` and anchored-window semantics,
with org predicates; the completeness contract on `cost_recipe`; the merge endpoint and shared
normalization kernel; golden vectors with an exact oracle across Python and JS. Fixes B3, B4.

**Phase 1c — Sync protocol.** The `client_mutated_at` / `server_seq` / `updated_at` split;
field-level dirty tracking; `op_id` / `sync_ops` idempotency; the recipe_items upsert diff; the
monotonic-delete trigger; FK-ordered atomic apply; the `deletion_scheduled_at` guard; page cap. Full
scenario test suite.

**Phase 1d — Web client migration.** The SPA is the third costing implementation and must move with
the schema: round-trip `item.id`, stop consuming 2-decimal prices, adopt the new money and ordering
contracts. Fixes the JS half of B3, and B5.

**Phase 2a — iOS offline loop.** Sync engine; auth and Keychain; pending-queue badge and export;
dashboard; ingredient list and detail; purchase entry with local fuzzy pick; settings; multi-user
member management.

**Phase 2b — iOS recipe editing.** Gated on 1c's item-diff sync being proven.

**Phase 3 — Invoice OCR.** Requires `invoice_pages`, the bad-photo fixture set, and LLM spend
approval.

**Phase 4 — Push notifications.** APNs plus a scheduled drift check (`BGProcessingTask` is the right
primitive here, not for uploads).

**Phase 5 — App Store submission.** US-only (D9).

CSV import stays web-only and is never built on iOS — the file is emailed to a desktop.

---

## 17. Deferred, with triggers

| Deferred | Trigger that makes it urgent |
|---|---|
| Hybrid logical clocks, `base_hlc` / 409, conflict-resolution UI | A third active device in one org. Until then server arrival order plus `client_mutated_at` is a defensible total order |
| `sync_changes` + AFTER triggers + `pg_snapshot_xmin` watermark | The per-org counter fails to keep up (it will not at 10k writes/yr), or read replicas are added. Write the reverse-commit-order test now regardless |
| Tombstone GC and the 410 re-baseline protocol | **Never GC tombstones.** Revisit only above ~100k per-org tombstones or a full pull over ~10 MB |
| Auto-undelete integrity pass on sync-apply | §10.1's loud LEFT JOIN covers visibility. Auto-undelete silently resurrects deliberately deleted rows — a policy decision, not a bug fix |
| Per-device heartbeat gating of drift push | A multi-device org complains an alert was computed on stale data |
| WASM-compiling the kernel for web | JS drift recurs after golden vectors are added to the JS target |
| Multi-location UI; worldwide availability; StoreKit | First multi-location customer; first non-US lead. Schema already supports locations |
| iCloud-backup exclusion for the photo cache | Tidy practice, not a boundary violation — the owner's own data in the owner's own iCloud |

---

## 18. Open decisions

These do not block Phase 1 but must be answered before the phase named:

1. **LLM subprocessor and spend (blocks Phase 3).** Which vision provider? Will you contract
   zero-retention / no-training and name them publicly in the privacy policy? Are you funding
   page-tiling and retry calls for bad photos, or does low confidence fall straight to manual entry?
2. **Conflict visibility (blocks Phase 2a).** Silent LWW everywhere, or a "changed on another device"
   banner for `menu_price`, `target_fc_pct` and `drift_threshold_pct` only? §5.2's field-level
   tracking makes silent LWW acceptable; this is a taste call.
3. **Legal review threshold (blocks Phase 3).** Is a self-authored privacy policy and DPA acceptable
   to launch, or do you want counsel before the first paying customer's invoice photos reach a
   third-party LLM?
4. **`deploy/` reconstruction (independent).** The live Vercel demo's serverless wrapper is not in
   git. Phase 1 replaces that backend, so rebuild it only if you want the current demo patchable in
   the interim.
