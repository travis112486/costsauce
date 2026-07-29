# Phase 2a Acceptance Runbook: native iOS offline loop

Audience: whoever needs to re-run Phase 2a's end-to-end proof — reviewer
login, on-device fuzzy-pick purchase entry, local-first costing, and sync to
a real API — or verify it before a later phase builds on top of it. Assumes
the reader has already applied `0001`-`0016` (phases 1a-1d) and has no
memory of how Phase 2a (`ios/`, `CostSauceKit`) was built. This is the
phase's **final** task: Tasks 1-14 shipped the backend roster route and the
whole app (kernel, GRDB store, sync engine, every tab); this task is purely
acceptance evidence — one XCUITest journey plus this document.

**Backend target:** none. Phase 2a shipped exactly one backend change (the
`GET /orgs/{id}/members` roster route, Task 1) against the same
`khohfrfqzbieaiikqlsa` project every prior runbook targets — no new
migrations. This runbook's own acceptance run is entirely local (disposable
Postgres + local `uvicorn`), the same shape as `phase-1d-deploy.md`'s smoke.

---

## 1. What shipped in this task

- **`ios/CostSauceUITests/SmokeTests.swift`**: replaces Task 9's placeholder
  (`app.launch()` only) with the real acceptance journey — reviewer login →
  bootstrap auto-picks the seeded org/location → Add tab fuzzy-pick →
  purchase save → success unit price → Dashboard → sync chip → Ingredients
  detail history row. See §4 for the exact assertions and §6 for the
  recorded run.
- **`ios/project.yml`**: added `GENERATE_INFOPLIST_FILE: YES` and
  `CODE_SIGNING_ALLOWED: "NO"` to the `CostSauceUITests` target's
  `settings`, mirroring what the `CostSauce` app target already had. Without
  this the target has no Info.plist to code-sign and `xcodebuild test` fails
  during signing for **any** test in that target, before a single test
  method runs (a gap Task 9 hit and left as a documented known-broken note
  for this task) — confirmed by reproducing the failure on this exact
  `project.yml` before the fix, then confirming the placeholder test alone
  passes immediately after.
- This document.

Nothing else changed: the Kit (`swift test`, 119/119), the app target's
production Swift files, and the backend are all untouched by this task.

---

## 2. Local stack

### 2.1 Disposable Postgres 17

Same cached-image, no-pull constraint as every prior local smoke on this
machine (`docker-credential-desktop` is missing from `PATH` here, so a
`docker pull` fails — `postgres:17` is already cached, so a plain `docker
run` is enough):

```bash
docker run -d --name cs-2a-smoke -e POSTGRES_PASSWORD=postgres -p 55441:5432 postgres:17
for i in $(seq 1 30); do
  docker exec cs-2a-smoke pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
```

Port `55441` is arbitrary (any free host port works) — not to be confused
with the API's own port below.

### 2.2 Seed script — reviewer identity, sample org/location, "Chicken Breast"

A short throwaway script, **not committed** (lives only in `scratch/` for
the duration of a run, same convention as `phase-1d-deploy.md` §4.2's
`bootstrap.py`), reusing `tests.conftest.apply_migrations` +
`tests.factories` exactly as the pytest suite does — so the seeded shape is
provably the same shape 1451 pytest cases already exercise. It seeds exactly
one org, one location, and one ingredient (`"Chicken Breast"`, `lb`-tracked)
— **no purchase**: the UITest itself creates the one purchase this
acceptance run proves end to end.

```python
# scratch/seed_2a.py -- run as: PYTHONPATH=. uv run python scratch/seed_2a.py
# (from the repo root; DB_URL env var required — see below). One correction
# to phase-1d-deploy.md's own claim: "no sys.path hacking needed" did NOT
# hold on this machine under `uv run python <script>` -- the script's own
# directory (scratch/), not the repo root, lands on sys.path[0], so `import
# tests...` fails with ModuleNotFoundError unless PYTHONPATH=. is set
# explicitly. Confirmed by reproducing the bare failure first.
import asyncio
import os

import psycopg

from tests.conftest import apply_migrations
from tests.factories import add_member, make_ingredient, make_location, make_org

REVIEWER_USER_ID = "00000000-0000-7000-8000-0000000d1501"
REVIEWER_EMAIL = "reviewer@example.com"


async def main():
    conn = await psycopg.AsyncConnection.connect(os.environ["DB_URL"], autocommit=False)
    await conn.execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public")
    await conn.execute("DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth")
    await conn.execute(
        "CREATE TABLE auth.users (id uuid PRIMARY KEY, email text, "
        "raw_user_meta_data jsonb DEFAULT '{}')")
    await conn.commit()
    await apply_migrations(conn)  # applies 0001-0016, sets app_user/app_pw
    await conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, %s)",
        (REVIEWER_USER_ID, REVIEWER_EMAIL))
    await conn.execute(
        "INSERT INTO profiles (user_id, contact_email, contact_email_verified_at) "
        "VALUES (%s, %s, now())", (REVIEWER_USER_ID, REVIEWER_EMAIL))
    org_id = await make_org(conn, "Smoke Test Diner")
    await add_member(conn, REVIEWER_USER_ID, org_id, "owner")
    location_id = await make_location(conn, org_id, "Smoke Test Main")
    ingredient_id = await make_ingredient(
        conn, location_id, "Chicken Breast", base_unit="lb",
        vendor="Acme Foods", category="Meat")
    await conn.commit()
    print(f"ORG_ID={org_id}\nLOCATION_ID={location_id}\nINGREDIENT_ID={ingredient_id}")


asyncio.run(main())
```

```bash
DB_URL="postgresql://postgres:postgres@127.0.0.1:55441/postgres" \
  PYTHONPATH=. uv run python scratch/seed_2a.py
```

### 2.3 Start the API

**Port 8400 is occupied on this machine** by an unrelated long-running
process (confirmed via `lsof -nP -iTCP:8400 -sTCP:LISTEN` before starting
anything below) — this run uses **8401** instead, same substitution Task 9's
acceptance made. If port 8400 is free on whatever machine runs this next,
either port works — just keep the UITest's `apiBaseURL` constant (§4) and
this command in sync.

```bash
export JWT_SECRET="smoke-test-secret-2a"
export JWT_ISSUER="costsauce-tests"
export DATABASE_URL="postgres://app_user:app_pw@127.0.0.1:55441/postgres"
export REVIEWER_OTP_ENABLED=1
export REVIEWER_EMAIL="reviewer@example.com"
export REVIEWER_CODE="123456"
export REVIEWER_USER_ID="00000000-0000-7000-8000-0000000d1501"
unset SUPABASE_URL SUPABASE_ANON_KEY   # /config returns nulls -- LoginView
                                        # collapses to the reviewer-only
                                        # form, exactly like phase-1d's SPA.
uv run uvicorn api.main:app --port 8401 &
```

```bash
curl -sS http://127.0.0.1:8401/config
# -> {"supabase_url":null,"supabase_anon_key":null}
```

---

## 3. Simulator selection

Xcode 26.6, iOS 26.2 simulator runtime installed (the environment's own
`xcrun simctl runtime match set iphoneos26.5 23C54` was already applied
before this task started — the fix that makes destinations show eligible at
all for this project's `iOS: "26.0"` deployment target).

**Deviation from a literal reading of "first device from `xcrun simctl list
devices available`":** that full, unfiltered listing's first entry is
`iPhone 16 Pro` under the **iOS 18.2** runtime section (runtimes list
oldest-first) — `xcodebuild -showdestinations` confirms it is **not** an
eligible destination for this scheme (only iOS 26.2 devices are offered;
`iPhone 16 Pro` doesn't even exist as a 26.2 device name on this machine —
that's `iPhone 17 Pro`). The intent ("pick some concrete, available iPhone
simulator, don't hardcode a UDID") is what this run follows, resolved
against the scheme's actual eligible destinations instead of the bare
device list:

```bash
xcodebuild -project CostSauce.xcodeproj -scheme CostSauce -showdestinations
# -> eligible iOS Simulator destinations are all OS:26.2; this run used
#    "iPhone 17 Pro" (also reachable via `xcrun simctl list devices
#    available` filtered to the "-- iOS 26.2 --" section).
```

---

## 4. Run

```bash
cd ios
xcodegen generate
xcodebuild -project CostSauce.xcodeproj -scheme CostSauce \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" test
```

`SmokeTests.testReviewerLoginToSyncedPurchase` drives:

1. **Launch** with `launchEnvironment = ["API_BASE_URL": "http://127.0.0.1:8401", "UITEST": "1", "REVIEWER_EMAIL": "reviewer@example.com", "REVIEWER_CODE": "123456"]`.
   `UITEST=1` makes `AppModel.init` wipe the Keychain and delete the
   Application Support store directory before anything else runs (its own
   doc comment) — every run starts from a genuinely clean device, which is
   what makes this suite safely re-runnable against the same simulator.
2. **Reviewer login**: `/config`'s `supabase_url` is null in this stack, so
   `LoginView` renders only the reviewer-access "Sign In" section — exactly
   one `"Email"` field and one `"Code"` field on screen, no ambiguity with
   the GoTrue email/OTP section (absent here). Types the launch-environment
   credentials, taps "Sign In".
3. **Bootstrap auto-picks the seeded org/location**: the seed script creates
   exactly one membership and one location, so `pickDefaultMembership`/
   `pickDefaultLocation` (Task 7) resolve straight to `.main` with no picker
   screens — the tab bar (`"Add"` button) appearing **is** the assertion
   that both picks happened. Waits for the sync chip to reach `"Synced ✓"`
   before navigating to Add, so the initial pull has landed the seeded
   ingredient into the local store first.
4. **Add tab, fuzzy-pick**: types `"chicken br"` into "Ingredient name".
   **Deviation from the brief's literal example query `"chkn brst"`:** that
   exact string is this codebase's own canonical example of a name that does
   **not** match `"Chicken Breast"` under `Kernel.matchIngredient`/
   `nearMatches` (bidirectional substring containment, frozen and
   golden-vector-pinned since Task 3/4) — `tests/test_merge.py` uses that
   exact pair specifically *because* they don't auto-match and therefore
   need the (web-only, out-of-scope-for-2a) merge tool. Typing it here would
   exercise the "create new ingredient" path instead of the fuzzy-pick path
   this smoke exists to prove. `"chicken br"` is a genuine normalized
   substring of `"chicken breast"`, so it surfaces `"Chicken Breast"` as a
   `.fuzzy` match, auto-selected into `SelectedIngredientChip` — the frozen
   Task 12 UI has no separate "tap to confirm a fuzzy match" gesture; any
   match (`.exact` or `.fuzzy`) auto-selects the same way.
5. **Purchase fields**: unit defaults to `"lb"` (`unitChoices(for:).first`
   for an lb-tracked ingredient — no Picker interaction needed); quantity
   `"2"`, total price `"9.00"`; taps "Save Purchase".
6. **Success indicator**: asserts a static text containing `"4.500000"`
   (`round(9.00 / 2.0000, 6)`) is shown — `Kernel.unitPrice` read back from
   the row `createPurchase` just wrote, never re-derived.
7. **Dashboard**: asserts the "Summary" section heading is present and "No
   Ingredients Yet" is absent — `hasLiveIngredients` flips true off the same
   local write, no sync required.
8. **Sync chip reaches `"Synced ✓"` again**: the purchase save enqueued one
   pending op (`syncSoon()`'s debounced `syncNow()`); waits for that push to
   land.
9. **Ingredients → detail → history row dated today**: taps the "Chicken
   Breast" row, scrolls the (taller-than-one-screen) detail list in small
   steps until the "History" section header and a row labeled with today's
   local ISO date (`Kernel.todayLocalISO`'s own algorithm, duplicated in the
   test file since this target doesn't link `CostSauceKit`) are visible,
   plus the `"$4.500000/lb"` unit price on that row.

**A real bug found and fixed while iterating this suite, worth recording:**
`IngredientDetailView`'s `List` is taller than the simulator's viewport —
iOS lazily instantiates `List`/`CollectionView` cells, so a section header
below the fold genuinely does not exist in the accessibility tree yet (not
merely "not hittable"). A full-screen `swipeUp()` can jump clean over a
single header cell with no way to recover short of scrolling back down —
this bit while iterating against an intentionally re-used (not fresh)
seeded database with several accumulated purchase rows, which pushed the
"History" header far enough down that one big swipe skipped past it
entirely. Fixed by dragging in small (~28%-of-screen) steps instead,
re-checking after each. The final, officially recorded run below (§6) is
against a **fresh** stack with exactly one purchase, where this would not
have mattered — the small-step scroll is kept anyway since a developer
re-running this suite locally against an already-seeded stack (exactly what
iterating on it here looked like) is a realistic scenario, not a hypothetical
one.

---

## 5. Post-run SQL asserts

Against the same disposable container, after the run in §6, using the
`ORG_ID`/`LOCATION_ID`/`INGREDIENT_ID` the seed script printed
(`019fae91-1c50-748b-9ae9-f2fe2eaa8fca` / `019fae91-1c52-7404-b13b-9e08c9824ce4`
/ `019fae91-1c52-7dd7-b23f-dc62e28d5ac9` for this run):

**1. The purchase row — `qty_base_units`, `unit_price` (generated column),
`server_seq`:**

```bash
docker exec cs-2a-smoke psql -U postgres -d postgres -c \
  "SELECT id, qty_base_units, unit_price, server_seq, purchased_on FROM purchases WHERE ingredient_id = '019fae91-1c52-7dd7-b23f-dc62e28d5ac9';"
```
```
                  id                  | qty_base_units | unit_price | server_seq | purchased_on 
--------------------------------------+----------------+------------+------------+--------------
 019fae91-eca6-744b-8cf0-c8490383c522 |         2.0000 |   4.500000 |          2 | 2026-07-29
(1 row)
```
`qty_base_units = '2.0000'`, `unit_price = '4.500000'`, `server_seq = 2 >
0` — matches the acceptance criterion exactly.

**2. `sync_ops` holds exactly the pushed op_ids:**

```bash
docker exec cs-2a-smoke psql -U postgres -d postgres -c \
  "SELECT op_id, org_id, batch_id, result_json->>'status' AS status FROM sync_ops WHERE org_id = '019fae91-1c50-748b-9ae9-f2fe2eaa8fca';"
docker exec cs-2a-smoke psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM sync_ops WHERE org_id = '019fae91-1c50-748b-9ae9-f2fe2eaa8fca';"
```
```
                op_id                 |                org_id                |               batch_id               | status  
--------------------------------------+--------------------------------------+--------------------------------------+---------
 019fae91-eca6-7cff-8d37-eb012efd5fbf | 019fae91-1c50-748b-9ae9-f2fe2eaa8fca | 019fae91-ef47-76b8-bded-a5c089894f72 | applied

1
```
Exactly one row — the single purchase-create op this run pushed — status
`applied`. Cross-checked its `result_json`:

```bash
docker exec cs-2a-smoke psql -U postgres -d postgres -c \
  "SELECT op_id, result_json FROM sync_ops WHERE org_id = '019fae91-1c50-748b-9ae9-f2fe2eaa8fca';"
```
```
                op_id                 |                                                       result_json                                                        
--------------------------------------+--------------------------------------------------------------------------------------------------------------------------
 019fae91-eca6-7cff-8d37-eb012efd5fbf | {"op_id": "019fae91-eca6-7cff-8d37-eb012efd5fbf", "row_id": "019fae91-eca6-744b-8cf0-c8490383c522", "status": "applied"}
(1 row)
```
`result_json.row_id` matches the purchase `id` from assert 1 exactly.

---

## 6. Offline-loop evidence (§14 sync-scenario acceptance)

XCUITest cannot toggle simulator networking mid-test (no public API to flip
airplane mode / drop the loopback connection from inside a UI test running
against a local server), so the §14 offline-loop scenarios — two-store
convergence, kill-resume, replay, and silent LWW — are proven at the client
by `CostSauceKit`'s own `SyncEngineTests` against `FakeSyncServer`/
`StubTransport` (a real, in-process protocol implementation, not a mock of
`SyncEngine` itself), not by this XCUITest:

| Scenario | Test |
|---|---|
| Two-store convergence | `twoStoreConvergenceFieldIdenticalRowsAndCounts` |
| Kill-resume (persisted cursor survives a new engine instance) | `multiPagePullAppliesAtomicallyPerPageAndNewEngineResumesFromPersistedCursor` |
| Replay (dropped push response, same `op_id` resubmitted) | `replayOnOpIdReuseAfterDroppedPushResponseAppliesExactlyOnce` |
| Silent LWW — stale update dropped | `staleOlderUpdateSilentlyDropsOpWithoutNeedsAttention` |
| Silent LWW — stale conflict adopts canonical row | `staleRecipeItemConflictAdoptsCanonicalRowAndConvergesToServerValue`, `secondStaleConflictDiscoveredMidDrainLoopAlsoForcesReset` |

All five (119/119 total in the Kit) are green in §7's recorded gate run.

---

## 7. Go-live notes

1. **`apiBaseURL` Release placeholder.** `ios/CostSauce/AppModel.swift`'s
   `resolveBaseURL()` compiles `https://api.costsauce.com` for Release
   builds — a placeholder that must be set to the real API host once one
   exists, per the Phase 1a go-live checklist's own "no host exists yet"
   gate. Tracked on the Notion Human Action Board:
   [CostSauce Phase 2a go-live: apiBaseURL Release placeholder + Supabase
   OTP email template](https://app.notion.com/p/3acc3e875d688170b653f7f48c0b5d5e)
   (related: the existing [CostSauce Phase 1a
   go-live](https://app.notion.com/p/3aac3e875d688146a899f57071e754ef) task
   shares the same "API host exists" dependency).
2. **Supabase email template must include `{{ .Token }}`.** The iOS app's
   real (non-reviewer) sign-in path is email + emailed OTP code
   (`GoTrueClient.requestOtp`/`verifyOtp`, web parity) — no magic-link
   deep-link handling in 2a (Locked decisions). That only works if project
   `khohfrfqzbieaiikqlsa`'s active Auth email template actually includes the
   `{{ .Token }}` variable somewhere in its body; Supabase's stock template
   only includes `{{ .ConfirmationURL }}`. Tracked on the same Notion task
   linked above.
3. **SIWA prerequisites remain parked.** `api/routes/identity.py:48-73`
   documents what Sign in with Apple needs server-side; none of it shipped
   in 2a (Global Constraints: SIWA is explicitly out of scope). This gates
   Phase 5, not this task.

---

## 8. Tear down

```bash
kill %1                      # the backgrounded uvicorn (§2.3)
docker rm -f cs-2a-smoke     # the disposable Postgres (§2.1)
rm scratch/seed_2a.py        # not committed -- lives only for the run
```

---

## 9. Acceptance record — as run

Run 2026-07-29 against worktree HEAD (Task 15, before this task's own
commit). Full gates, in order:

### 9.1 `cd ios/CostSauceKit && swift test`

```
✔ Test run with 119 tests in 16 suites passed after 0.092 seconds.
```

### 9.2 `uv run --extra dev pytest -q` (repo root)

```
1451 passed, 411 warnings in 50.59s
```
(The warnings are all `InsecureKeyLengthWarning` from short test-only JWT
signing keys — pre-existing, not from this task.)

### 9.3 App build

```
cd ios && xcodegen generate && xcodebuild -project CostSauce.xcodeproj \
  -scheme CostSauce -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  build -quiet
# exit 0, no output (quiet mode -- silent on a clean build with zero
# warnings/errors)
```

### 9.4 `xcodebuild test` — the acceptance smoke, against a fresh stack

Fresh container (`cs-2a-smoke`, §2.1), freshly re-run seed script (§2.2):

```
ORG_ID=019fae91-1c50-748b-9ae9-f2fe2eaa8fca
LOCATION_ID=019fae91-1c52-7404-b13b-9e08c9824ce4
INGREDIENT_ID=019fae91-1c52-7dd7-b23f-dc62e28d5ac9
```

```
Test Suite 'All tests' started at 2026-07-29 11:50:08.437.
Test Suite 'CostSauceUITests.xctest' started at 2026-07-29 11:50:08.437.
Test Suite 'SmokeTests' started at 2026-07-29 11:50:08.437.
Test Case '-[CostSauceUITests.SmokeTests testReviewerLoginToSyncedPurchase]' started.
    t =     0.00s Start Test at 2026-07-29 11:50:08.438
    t =     3.01s Waiting 15.0s for "Email" TextField to exist
    t =     4.79s Type 'reviewer@example.c...' into "Email" TextField
    t =     6.05s Type '123456' into "Code" TextField
    t =     6.56s Tap "Sign In" Button
    t =     7.08s Waiting 20.0s for "Add" Button to exist
    t =     8.16s     Checking existence of `"Add" Button`  -- found
    t =     8.20s Waiting 20.0s for "Synced ✓" Button to exist
    t =     9.28s     Checking existence of `"Synced ✓" Button`  -- found
    t =     9.32s Tap "Add" Button
    t =    12.60s Type 'chicken br' into "Ingredient name" TextField
    t =    13.15s Waiting 10.0s for "Chicken Breast" StaticText to exist
    t =    14.22s     Checking existence of `"Chicken Breast" StaticText`  -- found (fuzzy match)
    t =    16.12s Type '2' into "Quantity" TextField
    t =    17.56s Type '9.00' into "Total price" TextField
    t =    18.08s Tap "Save Purchase" Button
    t =    18.91s Waiting 10.0s for StaticText (First Match) to exist  -- "4.500000" success text found
    t =    20.05s Tap "Dashboard" Button
    t =    21.68s Waiting 10.0s for "Summary" StaticText to exist  -- found
    t =    22.80s Checking existence of `"No Ingredients Yet" StaticText`  -- absent
    t =    22.83s Waiting 20.0s for "Synced ✓" Button to exist  -- found
    t =    23.94s Tap "Ingredients" Button
    t =    25.66s Waiting 10.0s for "Chicken Breast" StaticText to exist  -- found
    t =    26.77s Tap "Chicken Breast" StaticText
    t =    28.18s Waiting 1.0s for "History" StaticText to exist
    t =    29.28s Press+drag (small-step scroll) -- see §4's note
    t =    30.02s Waiting 1.0s for "History" StaticText to exist  -- found
    t =    31.10s Waiting 1.0s for "2026-07-29" StaticText to exist
    t =    32.22s Press+drag (small-step scroll)
    t =    33.42s Waiting 1.0s for "2026-07-29" StaticText to exist  -- found
    t =    34.51s Checking existence of `StaticText (First Match)`  -- "$4.500000/lb" unit price found
Test Case '-[CostSauceUITests.SmokeTests testReviewerLoginToSyncedPurchase]' passed (34.850 seconds).
Test Suite 'SmokeTests' passed at 2026-07-29 11:50:43.289.
Test Suite 'CostSauceUITests.xctest' passed at 2026-07-29 11:50:43.291.
Test Suite 'All tests' passed at 2026-07-29 11:50:43.292.
	 Executed 1 test, with 0 failures (0 unexpected) in 34.850 (34.852) seconds

** TEST SUCCEEDED **
```

### 9.5 SQL asserts

Recorded in full in §5 above — purchase row (`qty_base_units='2.0000'`,
`unit_price='4.500000'`, `server_seq=2`) and exactly one `sync_ops` row
(`status: applied`, `row_id` matching the purchase id).

### 9.6 Tear down performed

```
kill %1                       # uvicorn on 8401
docker rm -f cs-2a-smoke
rm scratch/seed_2a.py
```
Confirmed after teardown: `docker ps -a` shows no `cs-2a-smoke`; port 8401
no longer listening; port 8400's unrelated pre-existing process (`python3.1`,
untouched throughout) still listening exactly as before this task started;
`git status` shows no `scratch/` directory. `ios/CostSauce.xcodeproj`
(xcodegen-generated, gitignored via `ios/.gitignore`) was left in place, the
same as every other task in this phase leaves it — it was never part of
"scratch."

**Also confirmed while iterating this suite (not part of the officially
recorded run above, since it reused the same stack across multiple passes):
two consecutive clean `xcodebuild test` passes back to back against a
stack with several already-accumulated purchase rows** — the concrete
evidence that `UITEST=1`'s store/Keychain wipe genuinely makes each run
start clean on the device side regardless of what the server already holds,
which is the repeatability property `SmokeTests.swift`'s own header comment
calls out.
