# Phase 1d — Web Client Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the web SPA off the legacy demo backend onto the Phase 1a-1c FastAPI + Supabase stack: JWT auth, location-scoped routes, string money end-to-end, `item.id` round-trip, `shared/kernel.js` as the one JS costing implementation — fixing the JS half of B3, and B5 — plus the four small backend routes the SPA needs (locations list, location settings, CSV import, static serving).

**Architecture:** The migrated SPA lives in a new top-level `web/` (the legacy `product/` stays frozen — spec §1's B1-B6 cite its line numbers as evidence). FastAPI serves `web/` at `/app/` and `shared/` at `/shared/` (same-origin: no CORS). The browser obtains its JWT directly from Supabase Auth (magic link via REST; reviewer OTP as the no-email path), then calls the API with `Authorization: Bearer`. All money/qty/pct values are server-rounded strings displayed verbatim; the only client-side math is `shared/kernel.js` (preview costing, date handling) and pixel math for charts.

**Tech Stack:** Vanilla ES-module JS (no build step), FastAPI StaticFiles, python-multipart (CSV upload), node:test for web lib tests.

## Global Constraints

- **Legacy `product/` and `site/` are read-only in this phase.** The migrated SPA is created in `web/`. Never edit `product/app.py` or `product/static/`.
- **Money contract:** the SPA never re-rounds server values — `money()`/`pct()` format the server's strings (or show em-dash for `null`); no `toFixed` on API values. Client-side *preview* math uses `shared/kernel.js` only (`fcStatus`, `suggestedPriceCents` — this is the B3 JS fix). Ids are UUID strings — every `parseInt(...id)` dies.
- **B5 fix:** no `new Date().toISOString()` for dates. Default date inputs from local date parts (`getFullYear/getMonth/getDate` zero-padded).
- **Null-handling contract:** costed payloads may carry `fc_pct/status/suggested_price = null` with `complete: false` (spec §10.1 — loud, not silent); the SPA must render an explicit "incomplete" state, never `NaN`/`undefined`.
- **Auth:** magic link is Supabase Auth's own REST (`POST {supabase_url}/auth/v1/otp` with the anon key, JSON `{"email", "create_user": false, "options": {"email_redirect_to": location.origin + "/app/"}}`; the emailed link lands back on the SPA with `#access_token=...` in the URL fragment). Reviewer OTP path posts to the API's `/auth/reviewer-otp`. Token kept in `localStorage` (`cs_token`); 401 → clear token, show login. `GET /config` supplies `{supabase_url, supabase_anon_key}` from env (`SUPABASE_URL`, `SUPABASE_ANON_KEY` — the anon key is public by design).
- **Phase boundaries:** invoice upload/list UI is REMOVED (Phase 3; the legacy upload was B2's stored-XSS hole). No sync UI (`/sync` is the offline client's; the SPA stays online-only per spec §3). CSV import is web-only and lands here (`source='import'`).
- **New backend routes in this phase (contracts frozen in Tasks 1-3):** `GET /orgs/{org_id}/locations`, `PATCH /locations/{location_id}`, `POST /locations/{location_id}/purchases/import`, `GET /config`, static mounts. Nothing else server-side changes; existing route response shapes must NOT change.
- **Testing:** TDD for backend routes (pytest, existing conventions: `app_client`, `seeded_biz`, `auth()`/`mint`, factories). Web pure logic lives in `web/js/lib.mjs` and is tested by `tests/js/web-lib.test.mjs` (auto-discovered by tests/test_js_kernel.py's rglob; node:test + assert/strict, imports via relative path like kernel.test.mjs). DOM glue (`web/js/app.js`) is not unit-tested — keep it thin; everything computable goes in lib.mjs.
- **Local test gate:** `uv run --extra dev pytest -q` green after every task. Commits: `feat(1d): ...` / `test(1d): ...` / `docs(1d): ...`, one per task.
- **Dependency:** `python-multipart` must be added to pyproject (FastAPI needs it for `UploadFile`/`Form`) in Task 2, with `uv lock` refreshed.
- Live deploy of any of this is out of scope (runbook note only; no API host exists yet — 1a checklist).

## File Structure

```
api/routes/locations.py        # Task 1: GET /orgs/{org}/locations, PATCH /locations/{id}
api/routes/imports.py          # Task 2: POST /locations/{id}/purchases/import
api/main.py                    # Tasks 1-3: router registrations, /config, static mounts
pyproject.toml + uv.lock       # Task 2: python-multipart
web/index.html                 # Task 3 placeholder shell; Task 4 real app shell
web/css/style.css              # Task 4: copied from product/static/css + login/incomplete styles
web/brand/logo-mark-v2.svg     # Task 4: copied
web/js/lib.mjs                 # Tasks 4-6: pure helpers (fmt, payload builders, dates, chart math)
web/js/auth.mjs                # Task 4: token store, magic-link/OTP flows, fragment capture
web/js/api.mjs                 # Task 4: fetch wrapper (Bearer, 401, JSON errors)
web/js/app.js                  # Tasks 4-6: views (module; imports lib/auth/api + /shared/kernel.js)
tests/test_locations_routes.py # Task 1
tests/test_purchase_import.py  # Task 2
tests/test_static_and_config.py# Task 3
tests/js/web-lib.test.mjs      # Tasks 4-6 (grows per task)
docs/runbooks/phase-1d-deploy.md # Task 7
```

---

### Task 1: Locations routes — discovery + settings

**Files:** Create `api/routes/locations.py`; Modify `api/main.py` (import + `app.include_router(locations.router)` after `dashboard`), `api/models.py` (add `LocationPatch`); Test `tests/test_locations_routes.py`.

**Interfaces (frozen):**
- `GET /orgs/{org_id}/locations` → 200 `[{id, name, target_fc_pct: str, drift_threshold_pct: str}]` ordered `name, id`. Membership check first, exactly like `api/routes/sync.py::_require_member_org` (`SELECT 1 FROM organizations WHERE id = %s` under RLS → 404 when invisible — an org can legitimately have zero locations, so an empty list alone cannot signal non-membership). Query: `SELECT id::text, name, target_fc_pct::text, drift_threshold_pct::text FROM locations WHERE org_id = %s ORDER BY name, id`.
- `PATCH /locations/{location_id}` body `LocationPatch{name?: str, target_fc_pct?: Decimal (gt=0), drift_threshold_pct?: Decimal (gt=0)}` — all optional, at least one present else 422 (model validator); `name` stripped, non-empty when present. → 200 `{id, name, target_fc_pct: str, drift_threshold_pct: str}`; 403 unless the caller's role in the location's org is owner/manager (same membership-join check as `merge_ingredients`, `api/routes/ingredients.py:157-163`); 404 unknown/cross-org. `locations` has no sync columns/triggers — a plain UPDATE.

- [ ] **Step 1: failing tests** — `tests/test_locations_routes.py` (conventions from tests/test_ingredients_routes.py): list returns alice's acme locations with string numerics ("30.00"-style); bob listing acme → 404; unknown org → 404; unauthenticated → 401; PATCH by owner updates all three fields (verify via re-list, string equality); PATCH by bookkeeper (carol via `add_member(..., "bookkeeper")`) → 403; PATCH `{}` → 422; PATCH `target_fc_pct: "0"` → 422; cross-org PATCH → 404; dashboard reflects a PATCHed `drift_threshold_pct` (GET dashboard shows the new threshold string).
- [ ] **Step 2:** run focused → FAIL (404/405). **Step 3:** implement per interfaces, mirroring existing route-file style. **Step 4:** focused then full `uv run --extra dev pytest -q` → PASS. **Step 5:** commit `feat(1d): locations discovery and settings routes`.

---

### Task 2: CSV purchase import route

**Files:** Create `api/routes/imports.py`; Modify `api/main.py` (register), `pyproject.toml` (+`python-multipart`, then `uv lock`); Test `tests/test_purchase_import.py`.

**Interfaces (frozen):**
- `POST /locations/{location_id}/purchases/import` — multipart form: `file` (UploadFile, optional) OR `csv_text` (Form str, optional); file wins if both; neither → 422. CSV headers (case-insensitive, trimmed) required: `item,vendor,date,qty,unit,total`; extra columns ignored; any missing → 400 `"CSV missing required column(s): <comma-list>"` (legacy-compatible).
- Per row: match `item` against the location's live ingredients using `api.kernel.match_ingredient` over the same candidate query `_candidates` uses; matched → use it; unmatched → create ingredient `{name: item.strip(), base_unit: 'each' if unit.lower() in ('each','case') else 'lb', vendor: <row vendor or None>, category: 'Imported', source: 'import'}`; on `UniqueViolation` (normalized-name race) → re-run the match and adopt the winner. Insert the purchase with the kernel's `normalize_purchase` for `qty_base_units` (same as `POST /purchases`), `source='import'`. Row failures (bad date, kernel error) → `errors.append({row: <line number, header = row 1, first data row = 2>, error: str})` and continue; whole request is ONE `tenant_connection` transaction with a per-row SAVEPOINT (reuse the `api/services/sync.py::apply_op` pattern) so failed rows don't poison it.
- Response 200 `{rows_processed: int, created: int, matched: int, errors: [{row, error}]}` (legacy shape; `rows_processed` counts data rows attempted). No role gate (ingredients/purchases writable by every role). 404 unknown/cross-org location.

- [ ] **Step 1: failing tests** — `tests/test_purchase_import.py`: csv_text with 2 rows (one fuzzy-matching an existing ingredient, one new) → `{rows_processed:2, created:1, matched:1, errors:[]}`, purchases have `source='import'` and correct string money, new ingredient `source='import'`/`category='Imported'`; file-upload variant works (bytes via `files={"file": ("p.csv", b"...", "text/csv")}`); missing column → 400 naming it; bad-date row → error entry with correct row number while other rows land; two rows with the same new name in one CSV → one created + one matched (no UniqueViolation leak); non-member → 404; header-only CSV → zeros.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement; add `python-multipart>=0.0.9` to pyproject dependencies; `uv lock`. **Step 4:** focused + full suite → PASS. **Step 5:** commit `feat(1d): CSV purchase import — web-only, source=import`.

---

### Task 3: Static serving + /config

**Files:** Modify `api/main.py`; Create `web/index.html` (placeholder shell: `<div id="app"></div>` + title — Task 4 replaces it); Test `tests/test_static_and_config.py`.

**Interfaces (frozen):**
- `GET /config` → 200 `{"supabase_url": <env SUPABASE_URL or null>, "supabase_anon_key": <env SUPABASE_ANON_KEY or null>}` — nulls when unset, never 500 (SPA then offers reviewer-OTP login only).
- `app.mount("/shared", StaticFiles(directory=<repo>/shared), name="shared")`; `app.mount("/app", StaticFiles(directory=<repo>/web, html=True), name="web")`; `GET /` → `RedirectResponse("/app/")`. Directories resolved from `Path(__file__).resolve().parents[1]` (CWD-independent); wrap each mount in `if dir.is_dir()` so an API-only container still boots. Mounting at `/app` keeps every API route un-shadowed.
- [ ] **Step 1: failing tests** — `tests/test_static_and_config.py`: `/config` with env monkeypatched returns both values; without env → both null; `GET /` → redirect to `/app/` (307/302 acceptable — assert `resp.headers["location"]`); `GET /app/` → 200 text/html containing `id="app"`; `GET /shared/kernel.js` → 200 containing `export`; spot-check an existing authed route still works through the same app (`GET /locations/{loc}/ingredients` via seeded_biz) — no shadowing.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** focused + full → PASS. **Step 5:** commit `feat(1d): serve web client and shared kernel; /config bootstrap`.

---

### Task 4: Web scaffold — auth, api wrapper, shell, bootstrap

**Files:** Create real `web/index.html`, `web/css/style.css` + `web/brand/logo-mark-v2.svg` (copy from `product/static/`, append login/incomplete-chip styles), `web/js/auth.mjs`, `web/js/api.mjs`, `web/js/lib.mjs`, `web/js/app.js` (shell + login view + bootstrap + empty view stubs; view bodies land in Tasks 5-6); Test `tests/js/web-lib.test.mjs`.

**Interfaces (frozen for Tasks 5-6):**
- `web/js/api.mjs`: `setToken/getToken/clearToken` (localStorage key `cs_token`); `async api(path, {method, body} = {})` → parsed JSON or throws `ApiError{status, detail}`; adds `Authorization: Bearer` when a token exists; JSON-encodes object bodies, passes `FormData` through untouched (no content-type header); on 401 → `clearToken()`, dispatch `window` CustomEvent `cs:signed-out`, then throw.
- `web/js/auth.mjs`: `parseFragment(hash) -> token|null` (pure; `"#access_token=abc&t=x"` → `"abc"`); `captureTokenFromFragment()` (uses parseFragment on `location.hash`, stores, strips via `history.replaceState`); `async requestMagicLink(email, config)` (POST `${config.supabase_url}/auth/v1/otp`, headers `{apikey: config.supabase_anon_key, "content-type": "application/json"}`); `async reviewerLogin(email, code)` (POST `/auth/reviewer-otp`, stores `access_token`).
- `web/js/lib.mjs` (pure, unit-tested): `money(s)` (`"3.31"` → `"$3.31"`, null/undefined → `"—"`; no re-rounding); `pct(s)` (null → `"—"`, else `s + "%"`); `signedPct(s)` (`"14.1"` → `"+14.1%"`, `"-2.0"` → `"-2.0%"`); `todayLocalISO(now = new Date())` → local `YYYY-MM-DD` from date parts (B5: `new Date(2026, 6, 27, 18)` → `"2026-07-27"` regardless of the toISOString date); `centsFromString(s)` (exact, string-split: `"12.34"`→1234, `"0.1"`→10, `"14.005"` throws, negatives ok); `pickDefaultMembership(me)` (single membership → it; several → null meaning "ask"; none → null).
- Bootstrap in `app.js`: on load → `captureTokenFromFragment()`; no token → login view (magic-link form only when `/config` has a supabase_url; reviewer OTP form always); token → `GET /me` → org picker (auto when exactly 1) → `GET /orgs/{org}/locations` → location picker (auto when exactly 1; zero → explicit "no locations" message) → persist `{org_id, location_id}` (`localStorage cs_ctx`, revalidated on load) → render tabs dashboard | ingredients | recipes | import | settings. `#restaurant-name` = location name. Sign-out clears token + ctx. `cs:signed-out` listener re-renders login.
- `index.html`: `<script type="module" src="/app/js/app.js">`; all asset URLs under `/app/...`.

- [ ] **Step 1: failing tests** — `tests/js/web-lib.test.mjs` importing `../../web/js/lib.mjs` and `../../web/js/auth.mjs` (parseFragment only — it's pure): the cases named above, plus `parseFragment("")` → null. Run `uv run --extra dev pytest tests/test_js_kernel.py -q` → FAIL (missing module).
- [ ] **Step 2: implement.** Keep every decision the tests can reach pure (pickers, fragment parsing, formatting); DOM flow gets exercised by Task 7's scripted smoke.
- [ ] **Step 3:** `uv run --extra dev pytest tests/test_js_kernel.py tests/test_static_and_config.py -q` (the static test's `id="app"` assertion must still hold against the real index) then full suite → PASS. **Step 4:** commit `feat(1d): web scaffold — supabase auth, bearer api wrapper, org/location bootstrap`.

---

### Task 5: Views I — dashboard, ingredients, purchases

**Files:** Modify `web/js/app.js`, `web/js/lib.mjs`; Test `tests/js/web-lib.test.mjs` (extend). Read `product/static/js/app.js:111-432` first for the UX being preserved.

- **Dashboard** → `GET /locations/{loc}/dashboard`. Topbar from `location.name`; `summary.avg_fc_pct` string-or-null via `pct()`; add an `incomplete_count` stat card; menu rows with `status: null` render an `incomplete` chip and `—` for fc/suggested (never NaN). Movers bars: widths via `barWidths(movers)` in lib.mjs (pure, tested: proportional to `|Number(drift_pct)|`, max 100, handles one element and negative drift) — floats fine, pixels only.
- **Ingredients list** → `GET /locations/{loc}/ingredients` (shape has no drift/trailing columns — drop that column; drift lives on the dashboard). Row delete → `DELETE .../ingredients/{id}` with 409-in-use and 404 toasts.
- **Detail/history** → `GET .../ingredients/{id}/history` returns `{purchases: [...DESC]}` with string numerics + `purchased_on`: table renders strings verbatim; sparkline uses `sparklinePoints(purchasesAsc, w, h)` in lib.mjs (pure, tested: known 3-point series → exact coords; single point centers; empty → []), fed `purchases.slice().reverse()`, `Number(unit_price)` inside the helper only. Add per-purchase delete → `DELETE .../purchases/{id}` (B1 recovery, new capability).
- **Quick purchase entry:** the new API never auto-creates. Debounced `GET .../ingredients/match` (`{match, near_matches}`) resolves the name; unmatched → inline "create ingredient" step (`POST .../ingredients`; on 409 duplicate adopt `detail.matches[0].id`). Then `POST /locations/{loc}/purchases` with `buildPurchasePayload(form)` from lib.mjs (pure, tested: full form → `{ingredient_id, purchased_on, qty, unit, qty_in_case, total_price}` as strings; empty qty_in_case omitted; no parseFloat anywhere). Date input defaults `todayLocalISO()`. Success toast shows the response `unit_price` string.

- [ ] **Step 1:** extend web-lib tests (failing) for `barWidths`, `sparklinePoints`, `buildPurchasePayload`. **Step 2:** implement. **Step 3:** JS tests + full suite → PASS. **Step 4:** commit `feat(1d): dashboard, ingredients, purchases views on the new contracts`.

---

### Task 6: Views II — recipes (item.id round-trip), import, settings

**Files:** Modify `web/js/app.js`, `web/js/lib.mjs`; Test `tests/js/web-lib.test.mjs` (extend). Read `product/static/js/app.js:439-781` first.

- **Recipes list** → `GET /locations/{loc}/recipes`: strings verbatim; null fc/status/suggested → incomplete chip + `—`.
- **Editor — the B-fix:** each editing line is `{id: <item id | null>, ingredient_id, qty_base_units}`; `id` comes from the costed payload's `items[].id` and is never dropped (the legacy bug: `product/static/js/app.js:469` rebuilt rows without it). `buildRecipePayload(editing, isCreate)` in lib.mjs (pure, tested across the matrix: create → no `id` keys at all; update → kept lines carry `id`, new lines omit it, removed lines absent; qty/menu_price/target as input strings; UUID ingredient_id untouched). Server 409 (id-less duplicate line) → toast the server detail verbatim.
- **Exact live preview (B3 JS fix):** lib.mjs gets `ratFromString(s)` (decimal string → `{n: BigInt, d: BigInt}`, tested) and `previewCost(lines, priceIndex)` — plate cents computed exactly from `unit_price` (6dp string) × `qty_base_units` (4dp string) summed as rationals, converted to cents with kernel `roundHalfAway`; then `fcStatus(plateCents, menuCents, targetBp)` and `suggestedPriceCents(plateCents, targetBp)` from `/shared/kernel.js` (node tests import `../../shared/kernel.js` directly). Pin with two suggested-price vectors ported from `shared/golden-vectors.json`, including one boundary case the legacy float `Math.ceil(x*2)/2` (`product/static/js/app.js:568`) gets wrong — assert the kernel path returns the vector's expected value (this test IS the B3-JS regression net).
- **Import view:** CSV only — the invoice upload form, invoice pill list, and `invoice_id` attach are removed. FormData → `POST /locations/{loc}/purchases/import`; render `rows_processed/created/matched` + per-row errors (legacy UX).
- **Settings view** → current location's row from `GET /orgs/{org}/locations`; save via `PATCH /locations/{loc}` with `buildSettingsPayload(form, current)` (pure, tested: only changed fields; nothing changed → null = don't send). 403 → "owner or manager required" toast. The legacy restaurant-name field maps to location `name` (updates the topbar on success).

- [ ] **Step 1:** extend web-lib tests (failing): `buildRecipePayload` matrix, `ratFromString`, `previewCost` golden-pinned B3 cases, `buildSettingsPayload`. **Step 2:** implement. **Step 3:** JS + full suite → PASS. **Step 4:** commit `feat(1d): recipes item.id round-trip with exact kernel preview; CSV import and settings views`.

---

### Task 7: Acceptance smoke, docs, runbook

**Files:** Create `docs/runbooks/phase-1d-deploy.md`; Modify `docs/runbooks/phase-1c-deploy.md` (one line in §8: SPA smoke now possible at `/app/` once a host exists).

- [ ] **Step 1: scripted local acceptance smoke** (the agent runs it; the runbook records it as the acceptance script): start a disposable postgres:17 container; apply all migrations and seed one user/org/location plus reviewer identity (short throwaway script under the scratch dir reusing `tests/conftest.apply_migrations` + `tests/factories` — document the exact commands in the runbook); export env (`JWT_SECRET`, `JWT_ISSUER`, `DATABASE_URL` as `app_user`, `REVIEWER_OTP_ENABLED=1`, `REVIEWER_EMAIL/CODE/USER_ID`); `uv run uvicorn api.main:app --port 8400`; then via HTTP (curl) exercise as the reviewer token: `/config`, `/app/` serves HTML, `/shared/kernel.js` serves, `/me`, locations list, create ingredient → purchase → recipe (2 lines) → GET recipe (capture item ids) → PUT with one qty changed and ids round-tripped → **assert live line count is still 2 and both ids unchanged** (SQL check — the 1d acceptance criterion) → CSV import 2 rows → PATCH settings → dashboard reflects threshold. Any failure → fix in the owning task's files before this task commits.
- [ ] **Step 2: runbook** — what shipped; new env vars for the future API host (`SUPABASE_URL`, `SUPABASE_ANON_KEY`); Supabase Auth dashboard config for magic links (redirect allowlist must include `<host>/app/`); the smoke script + expected outputs; note the legacy Vercel demo (`product/`) is fully superseded and retires when the new host goes live; rollback = API revert (mounts/routes are additive).
- [ ] **Step 3:** full `uv run --extra dev pytest -q` → PASS. **Step 4:** commit `docs(1d): deploy runbook and acceptance smoke`.

---

## Locked decisions (do not relitigate mid-task)

- Migrated SPA lives in `web/`; `product/` and `site/` stay frozen (evidence / marketing).
- Same-origin serving (`/app/` + `/shared/`), no CORS middleware.
- Browser JWT comes from Supabase Auth directly (magic link) or `/auth/reviewer-otp`; the API never mints magic-link tokens.
- Invoice UI removed until Phase 3; no sync UI in the SPA; CSV import auto-creates ingredients (`source='import'`, `category='Imported'`) but the quick-entry purchase path requires an explicit ingredient (create step in the UI).
- Server strings render verbatim; exact client math is kernel-based preview only; pixel math may float.
- No framework, no build step, no npm deps — ES modules + node:test.

## Self-Review (performed while writing)

1. **Spec coverage:** B3-JS → Task 6 (golden-pinned kernel preview); B5 → Task 4 `todayLocalISO`; item.id round-trip → Task 6 + Task 7's count/id acceptance assert; "stop consuming 2-decimal prices" → string-verbatim rendering (Tasks 4-6) with no client re-rounding; ordering contract → server-ordered lists rendered as-is (history DESC, reversal only for chart x-axis); settings→locations columns → Tasks 1/6; CSV import web-only → Tasks 2/6; D1 web parity bounded by phase (invoices = Phase 3; merge UI absent in legacy too).
2. **Placeholder scan:** every lib.mjs function is named with concrete test cases; DOM flows are covered by Task 7's scripted smoke, not deferred vaguely.
3. **Type consistency:** route contracts appear once (Tasks 1-3) and are consumed identically in Tasks 4-6; `centsFromString`/`ratFromString`/`previewCost` names consistent; `ApiError` and `cs:signed-out` referenced identically in Tasks 4-6.
4. **Risk flags:** (a) magic-link redirect needs Supabase dashboard config — runbook item; reviewer OTP is the locally testable path and the smoke uses it; (b) StaticFiles-vs-routes shadowing pinned by Task 3 tests; (c) `/shared/kernel.js` resolves only when served — node tests import by filesystem path (same file); (d) `python-multipart` changes the lockfile — Task 2 runs `uv lock` and the full suite.
