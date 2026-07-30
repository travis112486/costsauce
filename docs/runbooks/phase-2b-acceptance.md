# Phase 2b Acceptance Runbook: native iOS recipe editing

Audience: whoever needs to re-run Phase 2b's end-to-end proof — building a
recipe on the phone, offline-first, through create/edit/delete, syncing
through the Phase 1c protocol — or verify it before a later phase builds
on top of it. Assumes the reader has already applied `0001`-`0016` and has
read `docs/runbooks/phase-2a-acceptance.md` (this document only restates
what's different). This is the phase's **final** task: Tasks 1-10 shipped
the Kit rules (`LocalEdits`, `RecipeDraft`, `Costing.previewPlate`) and the
whole editor UI (create + edit + delete, reachable from the Dashboard's
Menu section); this task is purely acceptance evidence — one new XCUITest
journey plus this document.

**Backend target:** none. Phase 2b shipped zero backend changes — it is
entirely a Kit + app-target phase against the same schema every prior
runbook targets. This runbook's own acceptance run is local (disposable
Postgres + local `uvicorn`), the same shape as `phase-2a-acceptance.md`'s.

---

## 1. What shipped in this task

- **`ios/CostSauceUITests/SmokeTests.swift`** (modified):
  - `API_BASE_URL` is now read from the environment
    (`ProcessInfo.processInfo.environment["API_BASE_URL"]`), falling back to
    the same hardcoded `http://127.0.0.1:8401` default — a Phase 2a deferred
    minor, closed here.
  - The reviewer-login + bootstrap-wait block (Phase 2a's own
    `testReviewerLoginToSyncedPurchase`, previously inlined once) is
    factored into a shared `loginAndAwaitBootstrap(_:)`, reused by both
    tests in the file now.
  - A new test, **`testRecipeCreateEditDeleteReconciles`**: builds a
    two-line recipe through the real UI, asserts the editor's live preview
    plate cost, saves, asserts the Dashboard Menu section shows the same
    recipe with the same plate cost, waits for sync, edits one line's
    quantity, waits for sync again, deletes the recipe, waits for sync a
    third time — the delete **fan-out** proof (§4/§5 below). Two
    `Thread.sleep` checkpoints (documented in the file itself) give this
    runbook's own SQL a safe window to assert *live* server state
    mid-journey, since XCUITest (compiled against the iOS SDK, even for a
    Simulator-hosted UI test runner) cannot shell out to `psql` itself —
    `Foundation.Process` is unavailable there.
  - A private helper, `addStagedIngredient(_:_:app:)`, types a candidate's
    full name into the picker's name field, waits for the resulting
    `"Add \(name)"` button to appear, then taps it — see §6.1 for the
    finding this replaced.
- This document.

Nothing else changed: the Kit (`swift test`), the app target's production
Swift files, and the backend are all untouched by this task.

**Update (final-review fix wave, same phase):** the finding in §6.1 below
was fixed in `RecipeEditorView.swift` after this task's own acceptance run
recorded it — the create-path picker now stages a pick instead of
committing it live, exactly as §6.1 now describes. This runbook's file list
above and the helper name reflect the file as it stands post-fix; the
narrative in §6.1 is kept as the historical record of what this task found
and reproduced, with the fix and its own re-verification appended at the
end of that section.

---

## 2. Local stack

### 2.1 Disposable Postgres 17

Same cached-image, no-pull constraint as every prior local smoke on this
machine:

```bash
docker run -d --name cs-2b-smoke -e POSTGRES_PASSWORD=postgres -p 55442:5432 postgres:17
for i in $(seq 1 30); do
  docker exec cs-2b-smoke pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
```

Port `55442` is arbitrary (any free host port works, distinct from 2a's own
`55441` purely so both can coexist on this machine if ever run side by
side).

### 2.2 Seed script — reviewer identity, org/location, three ingredients

`scratch/seed_2b.py`, not committed (same convention as `phase-2a
-acceptance.md`'s `seed_2a.py`). It seeds one org, one location, and
**three** ingredients:

- `"Chicken Breast"` (lb-tracked, **unpriced**) — `testReviewerLoginToSyncedPurchase`
  creates its own purchase for this one, unchanged from 2a.
- `"Ground Beef"` (lb-tracked, **pre-priced** via a direct `make_purchase`
  factory call: 2 lb / $10.00 → $5.00/lb) and `"Onion"` (lb-tracked,
  **pre-priced**: 1 lb / $1.00 → $1.00/lb) — `testRecipeCreateEditDeleteReconciles`
  builds a recipe directly over these two; it never drives purchase entry
  itself, so both need to already be priced before the app's first pull.

```python
# scratch/seed_2b.py -- run as: DB_URL=... PYTHONPATH=. uv run python scratch/seed_2b.py
import asyncio
import os

import psycopg

from tests.conftest import apply_migrations
from tests.factories import add_member, make_ingredient, make_location, make_org, make_purchase

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
    await apply_migrations(conn)
    await conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, %s)",
        (REVIEWER_USER_ID, REVIEWER_EMAIL))
    await conn.execute(
        "INSERT INTO profiles (user_id, contact_email, contact_email_verified_at) "
        "VALUES (%s, %s, now())", (REVIEWER_USER_ID, REVIEWER_EMAIL))
    org_id = await make_org(conn, "Smoke Test Diner")
    await add_member(conn, REVIEWER_USER_ID, org_id, "owner")
    location_id = await make_location(conn, org_id, "Smoke Test Main")

    chicken_id = await make_ingredient(
        conn, location_id, "Chicken Breast", base_unit="lb",
        vendor="Acme Foods", category="Meat")

    beef_id = await make_ingredient(
        conn, location_id, "Ground Beef", base_unit="lb",
        vendor="Acme Foods", category="Meat")
    await make_purchase(conn, location_id, beef_id, "2026-01-01", "2.0000", "10.00")  # $5.00/lb

    onion_id = await make_ingredient(
        conn, location_id, "Onion", base_unit="lb",
        vendor="Acme Foods", category="Produce")
    await make_purchase(conn, location_id, onion_id, "2026-01-01", "1.0000", "1.00")  # $1.00/lb

    await conn.commit()
    print(
        f"ORG_ID={org_id}\nLOCATION_ID={location_id}\n"
        f"CHICKEN_ID={chicken_id}\nBEEF_ID={beef_id}\nONION_ID={onion_id}")


asyncio.run(main())
```

```bash
DB_URL="postgresql://postgres:postgres@127.0.0.1:55442/postgres" \
  PYTHONPATH=. uv run python scratch/seed_2b.py
```

**Gotcha found this task, not in 2a's runbook**: reseeding (the script's
own `DROP SCHEMA ... CASCADE` + recreate) while `uvicorn` is still running
against the same container leaves its pooled `psycopg` connections holding
STALE prepared-statement plans from the old schema — every request then
500s with `psycopg.errors.FeatureNotSupported: cached plan must not change
result type`. **Always reseed before starting `uvicorn`, never while it's
already running** — if it's already up, kill it, reseed, then start it
fresh (§2.3).

### 2.3 Start the API

Port 8401 (8400 occupied by an unrelated process — see 2a's own note):

```bash
export JWT_SECRET="smoke-test-secret-2b"
export JWT_ISSUER="costsauce-tests"
export DATABASE_URL="postgres://app_user:app_pw@127.0.0.1:55442/postgres"
export REVIEWER_OTP_ENABLED=1
export REVIEWER_EMAIL="reviewer@example.com"
export REVIEWER_CODE="123456"
export REVIEWER_USER_ID="00000000-0000-7000-8000-0000000d1501"
unset SUPABASE_URL SUPABASE_ANON_KEY
uv run uvicorn api.main:app --port 8401 &
```

```bash
curl -sS http://127.0.0.1:8401/config
# -> {"supabase_url":null,"supabase_anon_key":null}
```

---

## 3. Simulator selection

Same as `phase-2a-acceptance.md` §3: the unfiltered `xcrun simctl list
devices available` puts an ineligible iOS 18.2 device first; this run used
the first **eligible** destination instead.

```bash
xcodebuild -project CostSauce.xcodeproj -scheme CostSauce -showdestinations
# -> eligible iOS Simulator destinations are all OS:26.2; this run used
#    "iPhone 17 Pro".
```

---

## 4. Run

```bash
cd ios
xcodegen generate
xcodebuild -project CostSauce.xcodeproj -scheme CostSauce \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2" test
```

Both `SmokeTests` methods run in this invocation. `testReviewerLoginToSyncedPurchase`
is unchanged in behavior from 2a (see that runbook's own §4 for its blow-by-blow).
`testRecipeCreateEditDeleteReconciles` (Task 11's own journey) drives:

1. **Login + bootstrap** — identical precondition to the purchase test
   (shared `loginAndAwaitBootstrap`).
2. **Create "Acceptance Bowl"**: taps the Dashboard Menu section's "+"
   (`accessibilityLabel("Add Recipe")`, hidden for a bookkeeper, present
   here since the reviewer seed is an owner), types Name ("Acceptance
   Bowl") and Menu price ("20.00") — Target food cost % keeps
   `RecipeDraft`'s own "30.00" default, untouched. Adds two lines via the
   ingredient picker: "Ground Beef" (qty "1") then "Onion" (qty "2").
   Asserts the editor's own live preview shows **"Plate $7.00"**
   (1 lb × $5.00 + 2 lb × $1.00, each line rounded to 2dp then summed,
   `Costing.previewPlate`'s own contract). Taps "Save" — `dismiss()` pops
   straight back to the Dashboard root.
3. **Dashboard reflects the same plate cost**: asserts "Acceptance Bowl"
   and "Plate $7.00" both appear in the Menu section (`Costing.costRecipes`,
   the STORED-row twin of the same preview math, agrees with it exactly).
4. **Sync**: waits for the chip to read "Synced ✓" (3 ops pushed — 1
   `recipes` insert + 2 `recipe_items` inserts, `LocalEdits.saveNewRecipe`'s
   own one-`enqueueBatch` contract). **CHECKPOINT 1** — see §5.1 for the
   SQL run here, live, mid-test.
5. **Edit**: re-opens "Acceptance Bowl", locates Onion's quantity field by
   the row's own visible name (see §6.2 for why NOT by position), and
   edits it from "2.0000" to "2.0005" (one backspace + one digit — see
   §6.3 for why not a plain append). Waits out the 500ms debounce, pops
   back to the Dashboard root via the nav bar's own back button (see §6.4
   for why not the tab bar), waits for "Synced ✓" again. **CHECKPOINT 2**
   — §5.2.
6. **Delete**: re-opens "Acceptance Bowl", scrolls to and taps "Delete
   Recipe", confirms, asserts the Menu section falls back to its empty
   state ("No recipes yet. Tap + to build your first one."), waits for
   "Synced ✓" a third time. **CHECKPOINT 3** — the fan-out proof, §5.3.

---

## 5. SQL assertions — the officially recorded run

Run against a fresh container/seed (§2.1/§2.2), captured **live**, at the
exact moment each checkpoint's `print()` appeared in `xcodebuild test`'s
own streamed output — via a small driver script
(`scratch/run_recipe_test_with_sql.sh`, not committed) that starts
`xcodebuild test` in the background, tails its log for each
`"CHECKPOINT N"` line, and fires the matching `docker exec ... psql`
command the instant it appears. This is necessary (not merely convenient):
"2 LIVE recipe_items rows" and "the row's qty CHANGED" are real, only
briefly true states — checking them after the test finishes, once the
recipe is already tombstoned, would prove nothing.

### 5.1 CHECKPOINT 1 — after create + sync

```bash
docker exec cs-2b-smoke psql -U postgres -d postgres -c \
  "SELECT id, name, deleted_at FROM recipes WHERE name = 'Acceptance Bowl';"
```
```
                  id                  |      name       | deleted_at 
--------------------------------------+-----------------+------------
 019fb33a-5e04-76d7-ada9-29f3075d14f8 | Acceptance Bowl | 
(1 row)
```

```bash
docker exec cs-2b-smoke psql -U postgres -d postgres -c \
  "SELECT i.name, ri.qty_base_units, ri.deleted_at FROM recipe_items ri
   JOIN ingredients i ON i.id = ri.ingredient_id
   JOIN recipes r ON r.id = ri.recipe_id
   WHERE r.name = 'Acceptance Bowl' ORDER BY i.name;"
```
```
    name     | qty_base_units | deleted_at 
-------------+----------------+------------
 Ground Beef |         1.0000 | 
 Onion       |         2.0000 | 
(2 rows)
```

```bash
docker exec cs-2b-smoke psql -U postgres -d postgres -c \
  "SELECT count(*) AS total, count(*) FILTER (WHERE result_json->>'status' = 'applied') AS applied FROM sync_ops;"
```
```
 total | applied 
-------+---------
     3 |       3
(1 row)
```
Exactly matches the brief: **1 `recipes` row, 2 LIVE `recipe_items` rows**
with the expected `qty_base_units`, and **`sync_ops` holds exactly the 3
pushed ops as `applied`** (this org is freshly seeded, so the whole
table's count is scoped to this run alone).

### 5.2 CHECKPOINT 2 — after the quantity edit + sync

```bash
docker exec cs-2b-smoke psql -U postgres -d postgres -c \
  "SELECT i.name, ri.qty_base_units, ri.deleted_at FROM recipe_items ri
   JOIN ingredients i ON i.id = ri.ingredient_id
   JOIN recipes r ON r.id = ri.recipe_id
   WHERE r.name = 'Acceptance Bowl' ORDER BY i.name;"
```
```
    name     | qty_base_units | deleted_at 
-------------+----------------+------------
 Ground Beef |         1.0000 | 
 Onion       |         2.0005 | 
(2 rows)
```

```bash
docker exec cs-2b-smoke psql -U postgres -d postgres -c \
  "SELECT count(*) FROM recipe_items ri
   JOIN recipes r ON r.id = ri.recipe_id
   JOIN ingredients i ON i.id = ri.ingredient_id
   WHERE r.name = 'Acceptance Bowl' AND i.name = 'Onion';"
```
```
 count 
-------
     1
(1 row)
```
**Onion's `qty_base_units` changed from `2.0000` to `2.0005`** (Ground
Beef, untouched, still reads `1.0000`) and **no duplicate line appeared**
(exactly 1 row for Onion on this recipe, live or not).

### 5.3 CHECKPOINT 3 (post-run) — after delete + sync: the fan-out proof

```bash
docker exec cs-2b-smoke psql -U postgres -d postgres -c \
  "SELECT id, name, deleted_at IS NOT NULL AS tombstoned FROM recipes WHERE name = 'Acceptance Bowl';"
```
```
                  id                  |      name       | tombstoned 
--------------------------------------+-----------------+------------
 019fb33a-5e04-76d7-ada9-29f3075d14f8 | Acceptance Bowl | t
(1 row)
```

```bash
docker exec cs-2b-smoke psql -U postgres -d postgres -c \
  "SELECT i.name, ri.qty_base_units, ri.deleted_at IS NOT NULL AS tombstoned FROM recipe_items ri
   JOIN ingredients i ON i.id = ri.ingredient_id
   JOIN recipes r ON r.id = ri.recipe_id
   WHERE r.name = 'Acceptance Bowl' ORDER BY i.name;"
```
```
    name     | qty_base_units | tombstoned 
-------------+----------------+------------
 Ground Beef |         1.0000 | t
 Onion       |         2.0005 | t
(2 rows)
```
**The recipe AND both of its lines are tombstoned server-side** —
`LocalEdits.tombstoneRecipe`'s N+1-ops-in-one-batch fan-out (LocalEdits
.swift:289-321) proved end to end: a client that skipped the fan-out would
leave `recipe_items` rows live and pointing at a dead `recipes` row here,
and it does not.

```bash
xcodebuild test
# ** TEST SUCCEEDED **
```

---

## 6. Findings from writing and running this suite

Recorded here rather than silently smoothed over, per this task's own
evidence/honesty requirement.

### 6.1 The create-path ingredient picker pops mid-keystroke (fixed)

`RecipeEditorView`'s CREATE-path ingredient picker
(`addIngredientDestination`'s `onPick: addLine`) appends the picked line
**and pops the pushed screen immediately** — unlike `PurchaseEntryView`'s
picker (which only updates a chip in place, no navigation). `Kernel
.matchIngredient`'s fuzzy pass is a bidirectional substring test with no
minimum-length floor, so it is very common for the very FIRST character
typed to already substring-match some live candidate (e.g. "G" alone is a
substring of "ground beef"). Sending a whole ingredient name via one
`typeText` call races this: characters typed AFTER the screen has already
popped land on whatever field the parent screen's keyboard focus happens
to move to next, silently corrupting it — reproduced live twice while
writing this suite: typing "Ground Beef" left a stray `"round Beef"`
appended onto the **Menu price** field (`"20.00round Beef"`), and typing
"Onion" left a stray `"n"` appended onto the just-added Ground Beef line's
own **Qty** field (`"1n"`). Neither is a data-loss bug in the sense of
corrupting anything already saved — both were caught by this suite's own
assertions before ever tapping Save — but it means a **real user typing
normally into this exact picker could, depending on what's already on
their live ingredient list, end up with a stray character in an unrelated
field** the instant their query happens to substring-match something.

This was a **product-level UX gap worth a human look**, not something fixed
by Task 11 itself (its own discipline rule: report, don't silently patch).
That task's own accommodation — `typeIntoPickerUntilItPops`, which typed
one character at a time and stopped the instant the picker screen was
gone — was a test-side workaround, not a claim that the underlying
behavior was fine.

**Fixed (final-review pass, same phase).** `RecipeEditorView.swift`'s
create-path `addIngredientDestination` no longer wires `IngredientPickerView`'s
`onPick` straight to `addLine`. It now stages the live match into a new
`pickedIngredient` state variable — mirroring the edit path's own
`addLineDestination`/`newLineIngredient`, which never had this problem
because it was already stage-then-confirm — and renders an explicit
`Button("Add \(pickedIngredient.name)")` below the picker. Nothing is
appended and the screen does not pop until that button is tapped, so the
race described above (characters typed after the pop landing on whatever
field focus moved to next) no longer has a pop to race. `IngredientPickerView`
itself was not touched (its `onPick`/`onClear` contract is still correct
for `PurchaseEntryView`, which is a live, non-navigating consumer), and no
minimum-length floor was added to `Kernel.matchIngredient` (its behavior
stays pinned to the golden vectors shared with the web/Python
implementations) — the fuzzy match on a single character still surfaces,
it just no longer auto-commits.

The test-side workaround this necessitated is gone too:
`typeIntoPickerUntilItPops` has been removed and replaced by
`addStagedIngredient(_:_:app:)` (§1), which sends a candidate's full name
in one `typeText` call — safe now that there is no mid-keystroke pop to
race — then waits for the staged `"Add \(name)"` button and taps it as the
explicit commit. Re-run against this fix: `xcodebuild test` (both
`SmokeTests` methods, one invocation, fresh stack) —
`Executed 2 tests, with 0 failures (0 unexpected) in 118.130 seconds`,
`** TEST SUCCEEDED **`. The single-character non-commit behavior itself
(typing "G" alone leaves the picker on-screen with nothing added) was
confirmed live in the simulator during the fix but is not asserted by a
permanently committed test — driving that specific negative case reliably
in this XCUITest/simulator environment is the same class of limitation
§6.5 below documents for swipe gestures, so it's recorded here as a known
gap rather than built into a fragile assertion.

### 6.2 `editLinesSection`'s row order is not deterministic across runs

`RecipeEditorView.editLinesSection`'s `ForEach(lines, ...)` is fed by
`LocalStore.liveRecipeItems(recipeId:)`'s `ORDER BY id`
(LocalStore.swift:385-391). `UUIDv7.generate` mixes in CSPRNG-random bits
for same-millisecond ties (UUIDv7.swift:19-23 — no monotonic counter), and
`LocalEdits.saveNewRecipe` mints every line's row id from the SAME `now`
in one batch — so which of two lines added in the same create call sorts
first on a later reload is effectively a coin flip per run. A first draft
of this suite located "Onion's" quantity field by position
(`element(boundBy: 1)`, the second-added line) and silently edited the
WRONG row on at least one run (confirmed by the SQL: Onion read back
unchanged while Ground Beef also read back unchanged — neither line the
test intended to touch had actually changed). Fixed by locating the field
by the row's own visible ingredient-name label instead (§5's committed
`SmokeTests.swift`, `onionRowY`/geometric nearest-match).

Not a product bug: nothing about the STORED data is wrong or
non-deterministic (the rows themselves are correct; only their *on-screen
order* varies), and the create form itself (in-memory `draft.lines`, a
plain Swift array) has no such issue. Worth knowing for anyone else
writing a UI test against this screen with more than one line, though.

### 6.3 `recipe_items.qty_base_units` is `numeric(14,4)` — a 5th decimal silently rounds away

Two failed attempts before landing on the committed edit technique, both
confirmed live via the SQL above (not theorized):

1. Appending `".5"` onto the field's pre-filled `"2.0000"` (the field
   loads the SERVER-canonical value — the pull half of CHECKPOINT 1's own
   sync already echoed it back, not the `"2"` this suite originally typed
   at create time) produces the invalid two-decimal-point string
   `"2.0000.5"`, which `Rational.parseDec` correctly rejects — the value
   stayed silently unchanged.
2. Appending a single valid trailing digit (`"2.0000"` + `"1"` =
   `"2.00001"`) parses fine, commits, and pushes — but lands in the
   column's 5th decimal place, and `recipe_items.qty_base_units` is
   `numeric(14,4)` (`0012_business_tables.sql:77`): the server rounds it
   straight back down to `"2.0000"` on write, indistinguishable from a
   no-op. This is the **exact** pitfall Phase 2b Task 9's own report
   already flagged for its own `"111"`-appended qty edit ("an artifact of
   this walk's own arbitrarily-chosen test value, not a bug") — that
   task only needed the CLIENT-side op count, so it could shrug the
   rounding off; this task's brief explicitly needs the SERVER row itself
   to read as changed, so the same shortcut doesn't work here. Fixed by
   deleting the trailing digit (one backspace) before typing its
   replacement, landing the edit within the column's own precision
   (`"2.0000"` → `"2.0005"`) — still never a full clear-and-retype
   (Task 9's own finding: unreliable in this simulator/iOS build), just a
   single trailing backspace.

### 6.4 The on-screen keyboard covers the tab bar

Popping back from the edit screen to the Dashboard root to see the sync
chip again (the chip only lives in each tab's own root toolbar — Task 9's
own finding, confirmed again here) by tapping `app.tabBars.buttons
["Dashboard"]` **silently failed** while the decimal-pad keyboard was
still up from the just-finished quantity edit: the keyboard visually
covers the tab bar at the bottom of the screen, and XCUITest's own
hit-point computation for the tab button came back `{-1, -1}` (off-screen)
— the tap registered as a no-op, not an error. Fixed by using the
navigation bar's own back button instead
(`app.navigationBars.buttons["Dashboard"]`, its accessibility label
mirroring the pushed-from screen's title) — it sits at the top of the
screen, never covered by the keyboard.

### 6.5 Swipe-to-remove still cannot be driven via XCUITest

Phase 2b Task 9's own report disclosed that six distinct gesture-synthesis
techniques against a line's `.swipeActions` trailing "Remove" button all
failed to register as any recognized gesture in this simulator/Xcode
combination, and asked this task to try again. **This task tried again,
with four more techniques — `swipeLeft()` on the row's own label,
a row-frame-confined press-and-drag, `swipeLeft(velocity: .slow)`, and an
app-anchored wide press-and-drag — against a freshly built two-line
recipe. All four failed identically**: no `"Remove"` button ever appeared,
the row's own position was unchanged after each attempt, and the section's
scroll bar stayed pinned at `0%` throughout — the same signature Task 9's
own report described (the synthesized touch isn't reaching the gesture
recognizer at all, not merely failing to trigger the swipe specifically).
This confirms it as a genuine, reproducible XCUITest/simulator automation
limitation on this machine's Xcode/iOS combination, not a flake and not
something a ninth or tenth technique is likely to fix.

**This suite does not claim swipe-to-remove coverage.** The underlying
guard (`LocalEdits.tombstoneRecipeLine`'s `EditError.lastLine`, refusing
to remove a recipe's last live line) is independently proven by the Kit's
own passing test suite
(`tombstoneRecipeLineOnLastLineThrowsLastLineAndEnqueuesNothing`, part of
the 167/167 in §7.1 below), and the view-layer wiring
(`.swipeActions` → `removeLine()` → catch `.lastLine` → the frozen alert)
mirrors `IngredientsListView`'s own already-working `.swipeActions`
pattern line for line — but neither of those is the same as a live,
end-to-end simulator pass of the actual gesture, and this document does
not pretend otherwise. A reviewer or a later task with working
swipe-gesture UITest infrastructure (a different Xcode/iOS combination, or
a lower-level XCTest API this investigation didn't reach for) should give
this one specific interaction a real live pass when practical.

---

## 7. Full gates — as run

### 7.1 `cd ios/CostSauceKit && swift test`

```
✔ Test run with 167 tests in 17 suites passed after 0.208 seconds.
```
(Kit untouched by this task — regression check, matches the Phase 2b
baseline every prior task in this phase already established.)

### 7.2 `uv run --extra dev pytest -q` (repo root)

```
1451 passed, 411 warnings in 62.05s (0:01:02)
```
(The warnings are all `InsecureKeyLengthWarning` from short test-only JWT
signing keys — pre-existing, not from this task.)

### 7.3 App build

```bash
cd ios && xcodegen generate && xcodebuild -project CostSauce.xcodeproj \
  -scheme CostSauce -destination 'generic/platform=iOS Simulator' \
  build -quiet
```
Exit 0, no output (quiet mode — silent on a clean build with zero
warnings/errors).

### 7.4 `xcodebuild test` — the acceptance smoke, run 3 times

All 3 runs below are against the FINAL committed `SmokeTests.swift` (every
fix in §6 already applied — no run counted here predates them). Runs 1 and
2 are each against a **fresh** disposable Postgres container + fresh seed
+ fresh `uvicorn` process (§2); run 3 reuses run 1's already-torn-down-and
-recreated-clean stack to additionally prove the full two-test suite
(recipe journey + Phase 2a's own purchase journey) passes together in one
`xcodebuild test` invocation, the shape a real CI run would use.

**Run 1 (officially recorded, `testRecipeCreateEditDeleteReconciles` alone,
fresh stack, live SQL captured mid-flight via `scratch/run_recipe_test_with_sql.sh`):**
```
Test Case '-[CostSauceUITests.SmokeTests testRecipeCreateEditDeleteReconciles]' passed (79.013 seconds).
xcodebuild exit status: 0
** TEST SUCCEEDED **
```
Full SQL evidence in §5 above.

**Run 2 (repeat, `testRecipeCreateEditDeleteReconciles` alone, fresh stack):**
```
Test Case '-[CostSauceUITests.SmokeTests testRecipeCreateEditDeleteReconciles]' passed (78.541 seconds).
** TEST SUCCEEDED **
```

**Run 3 (repeat, BOTH tests together, one invocation):**
```
Test Case '-[CostSauceUITests.SmokeTests testRecipeCreateEditDeleteReconciles]' passed (79.032 seconds).
Test Case '-[CostSauceUITests.SmokeTests testReviewerLoginToSyncedPurchase]' passed (34.101 seconds).
	 Executed 2 tests, with 0 failures (0 unexpected) in 113.133 (113.135) seconds
** TEST SUCCEEDED **
```

**All 3 runs passed. No flakes observed** in any of them. (Two earlier
passes not counted here, before the §6.2/§6.3 fixes landed, DID pass from
the UI's own perspective but were later found via SQL to have silently
edited the wrong row / a value that rounded away — recorded as findings,
not claimed as clean evidence; every run counted in this section postdates
both fixes.)

---

## 8. Go-live notes

Carried forward from `phase-2a-acceptance.md` §7 — nothing in this phase
changes their status, so they're not repeated in full here, just linked:
the `apiBaseURL` Release placeholder, the Supabase OTP email template
`{{ .Token }}` requirement, and SIWA prerequisites. No new go-live items
were discovered by this task (Phase 2b shipped zero backend changes and no
new external-service dependency).

---

## 9. Tear down

```bash
pkill -f "uvicorn api.main:app"     # this task's uvicorn on 8401
docker rm -f cs-2b-smoke            # this task's disposable Postgres
rm -rf scratch/                     # seed_2b.py + run_recipe_test_with_sql.sh, neither committed
```
Confirmed after teardown: `docker ps -a` shows no `cs-2b-smoke` (the
pre-existing `costsauce-manual-sanity` container, not this task's, is left
running exactly as found); port 8401 no longer listening; `git status`
shows no `scratch/` directory; `ios/CostSauce.xcodeproj`
(xcodegen-generated, gitignored) left in place, same as every prior task
in this phase.
