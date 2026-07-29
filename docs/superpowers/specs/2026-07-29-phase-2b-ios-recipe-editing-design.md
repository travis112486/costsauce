# Phase 2b — iOS recipe editing (design)

**Date:** 2026-07-29
**Status:** approved by Travis (brainstorm, 2026-07-29); implementation plan not yet written
**Parent spec:** `docs/superpowers/specs/2026-07-25-native-ios-app-design.md` §16 ("Phase 2b — iOS recipe
editing. Gated on 1c's item-diff sync being proven."). That gate is now met: Phase 2a shipped and proved
the item-diff sync path, including `recipe_items` conflict arbitration (`origin/main` at `30c9255`).

---

## 1. What ships

The phone becomes able to build and maintain the menu without a laptop: create a recipe, edit its name,
menu price and target food-cost percentage, add lines, change line quantities, remove lines, and delete
the recipe. Everything works offline and reconciles through the Phase 1c sync protocol.

Recipes are currently pull-only on iOS — they appear as a read-only Menu section on the Dashboard whose
empty state reads "Recipes are created on the web app; they cost themselves here automatically"
(`ios/CostSauce/Views/DashboardView.swift:250`). Phase 2b removes that limitation and the messages that
point users at the web app for recipe work.

## 2. Decisions

All made by Travis on 2026-07-29 during the design brainstorm.

| # | Decision | Rationale |
|---|---|---|
| D1 | **Full parity with web**, including delete | The phone should be self-sufficient; the delete fan-out is contained and testable |
| D2 | **Persist the caller's role locally and gate the UI** | A bookkeeper must never be offered an affordance the database will refuse; no work is done and then lost |
| D3 | **Do not enforce the 25-recipe plan limit** | It is unenforced everywhere today; enforcing on the phone alone would make iOS users worse off than web users for the same account. Tracked separately (§13) |
| D4 | **Hybrid edit model**: draft a new recipe until Save; apply edits to an existing recipe immediately | A new dish is a composition to finish before it becomes real; an existing dish is live data where losing an unsaved quantity fix is the worse failure |
| D5 | **No fifth tab.** Dashboard Menu rows tap through to the editor; the section header carries the new-recipe affordance | Keeps the Dashboard as the hub, avoids a redundant second entry point |

Inherited and still binding from Phase 2a: **silent LWW** — no "changed on another device" UI anywhere;
**minimum iOS 26.0**; money, quantities and percentages are **strings** end to end with arithmetic only
through the Kit's `Int128` rationals.

## 3. Scope

**In:** recipe create / field edit / add line / change line quantity / remove line / delete recipe, all
offline-capable; role-gated UI; live plate-cost and food-cost preview while composing; the delete
fan-out; the failure surfaces in §7.

**Out:** sub-recipes and nesting (the schema has no self-reference — `recipe_items` can only point at
`ingredients`); yields and portions (no such concept exists anywhere in the product); any unit conversion
on a line (a line's quantity is entered directly in the ingredient's `base_unit`; conversion exists only
at purchase entry); duplicate-recipe-name detection (the server has none either); plan-limit enforcement
(D3); manual line ordering (there is no order column — the server orders by ingredient name); changing an
existing line's ingredient in place (§5, immutable over sync); conflict-resolution UI (silent LWW);
invoice OCR, push notifications and SIWA (Phases 3, 4, 5).

## 4. Architecture

### 4.1 CostSauceKit additions

**`Store/LocalStore.swift`** — two reads it lacks:
- a single-recipe lookup (there is `ingredient(id:)` at :318-322 but no recipe equivalent)
- `recipe_items` filtered by recipe. Today's `liveRecipeItems()` (:353-358) is unfiltered, which is
  correct for the Dashboard and useless for an editor.

No write plumbing is needed: `knownTables` (:22-24), `applyPullPage`'s upsert switch (:139-142), and
`enqueue`/`insertStub` (:184-234) already carry working `recipes` and `recipe_items` branches that no
caller has ever exercised.

**`Store/LocalEdits.swift`** — the recipe write paths, which do not exist today (the file has only
`createIngredient`, `createPurchase`, `unitChoices`, `tombstonePurchase`, `tombstoneIngredient`):
`saveNewRecipe`, `updateRecipeFields`, `addRecipeLine`, `updateRecipeLineQty`, `tombstoneRecipeLine`,
`tombstoneRecipe`. Each mints ops through the same helper the existing paths use, and each takes the
local write and its op(s) in one transaction.

**`Costing/`** — one new pure function: a plate-cost preview over **draft** lines that are not yet in the
database. `Costing.costRecipes` (`Costing.swift:115-196`) reads stored rows only, so the new-recipe screen
has nothing to cost until Save. Web already has this function (`previewCost`, `web/js/lib.mjs:278-292`);
the Swift version is a port pinned by the same golden vectors.

**`RecipeDraft`** — a Kit value type plus a pure function that validates a draft and produces its ops.
The draft lives in the Kit rather than the view because it carries real logic (validation, and turning a
composition into the right ops) and the app target has no unit-test harness. This also closes a follow-up
the 2a final review left open, about app-target orchestration having no executable coverage.

### 4.2 App target additions

Per D5 there is **no separate recipes list** — the Dashboard's existing Menu section *is* the list. Its
rows become navigable and its section header gains the new-recipe affordance
(`ios/CostSauce/Views/DashboardView.swift:243-262`). The one new screen is the editor, which holds a
`RecipeDraft` when creating and operates directly on stored rows when editing.

The fuzzy ingredient picker built in Phase 2a is reused, including its create-new-ingredient sheet, so a
missing ingredient is never a dead end. That picker currently lives inside
`ios/CostSauce/Views/PurchaseEntryView.swift`; extracting it into its own component is part of this phase
(§12).

## 5. The op model

| Action | Local write | Ops minted |
|---|---|---|
| Create recipe (Save) | recipe row + all line rows, one transaction | 1 `recipes` insert + one `recipe_items` insert per line |
| Edit name / menu price / target FC% | update recipe row | 1 `recipes` update, carrying only changed fields |
| Add a line | insert line row | 1 `recipe_items` insert |
| Change a line's quantity | update line row | 1 `recipe_items` update, debounced so typing does not mint a dozen |
| Remove a line | set the line's `deleted_at` | 1 `recipe_items` tombstone |
| Delete the recipe | set `deleted_at` on the recipe **and every live line** | 1 `recipes` tombstone + one `recipe_items` tombstone per live line |

**The last row is the sharpest edge in the phase.** `api/routes/sync.py:15-22` warning (b): a recipe
tombstone op does **not** cascade to its lines, unlike `DELETE /locations/{id}/recipes/{id}`, which
cascades server-side. Sync ops are applied one row at a time with no implicit fan-out, so the device must
enqueue an explicit tombstone for every live line. A client that skips this leaves live lines against a
dead recipe, which the costing completeness contract surfaces loudly rather than dropping quietly.

The fan-out is minted in the same local transaction as the tombstones, so recipe and lines are queued
atomically. Ops are idempotent through the server's op-id ledger, so retrying after a dropped connection
is safe.

**Protocol facts this design relies on** (all verified against the code, Phase 2a-proven):

- **Client-minted ids work.** The sync insert path uses the op's `row_id` as the primary key
  (`api/services/sync.py:227-279`), so the phone mints UUIDv7 ids exactly as `createIngredient` and
  `createPurchase` already do.
- **Table ordering makes create-with-lines safe in one push.** `TABLE_ORDER = ("ingredients", "recipes",
  "recipe_items", "purchases")` (`api/services/sync.py:23`) — the server sorts a batch by table before
  applying, so a recipe always applies before its lines. Results are returned in the caller's original
  order.
- **Field allowlists permit exactly what we need, and no more.**
  `INSERT_FIELDS["recipes"] = {name, menu_price, target_fc_pct, deleted_at}`;
  `INSERT_FIELDS["recipe_items"] = {recipe_id, ingredient_id, qty_base_units, deleted_at}`;
  `UPDATE_FIELDS["recipe_items"] = {qty_base_units, deleted_at}` **only**
  (`api/services/sync.py:23-38`). A line's `recipe_id` and `ingredient_id` are immutable over sync —
  "repointing is merge's job, never sync's". So **changing a line's ingredient is remove-and-add**, the
  same rule the web editor enforces (`web/js/app.js:802-810`).
- **Batch limits are already handled.** `MAX_BATCH_OPS = 200`; the 2a engine chunks pushes, so a recipe
  with many lines needs no special handling.

## 6. The draft model

A `RecipeDraft` carries the name, menu price, target food-cost percentage, and its draft lines, each an
ingredient id plus a quantity string. Validation and op production are pure functions over that value —
no database, no view state — so every rule in §9 is unit-testable in the Kit.

The draft's line sequence is **presentation only**, so a line just added appears where the user put it
while composing. It is never persisted: there is no order column, and every stored read orders by
ingredient name (§3). A saved recipe therefore reopens alphabetically, which is also how web and the
Dashboard already display it.

For an existing recipe there is no draft: each edit writes its row and enqueues its op as it happens
(D4). The editor therefore has two paths through one screen, but both mint ops through the same
`LocalEdits` helpers, so the second path is thin.

## 7. Conflicts and failure states

**Recipe field edits** are last-write-wins by `client_mutated_at`. Nothing new.

**Two devices adding the same ingredient to the same recipe** collide on
`recipe_items_live_uq (recipe_id, ingredient_id) WHERE deleted_at IS NULL`
(`supabase/migrations/0012_business_tables.sql:84-85`). The server arbitrates by clock via an
`ON CONFLICT … DO UPDATE … WHERE client_mutated_at <= EXCLUDED.client_mutated_at` upsert
(`api/services/sync.py:245-271`); the loser receives `{"status": "stale", "reason": "older", "row_id":
<canonical>}` and the client adopts the canonical row through `adoptCanonicalRow`, already implemented and
tested in 2a (`SyncEngine.swift:313-323`, `LocalStore.swift:263-275`). Effect: one person's quantity wins,
the other device silently agrees. **No UI** — consistent with silent LWW.

**Editing a line's quantity that another device deleted** cannot land: the `sync_row_stamp` trigger
refuses to re-mutate a tombstoned row (`CS423`,
`supabase/migrations/0014_sync_protocol.sql:153-187`). This is the **one deliberate exception to silence**:
the op parks as needs-attention in the pending queue — which already renders `recipes` and `recipe_items`
op names (`ios/CostSauce/Views/PendingQueueView.swift:201-202`) — and the trailing pull removes the line
locally. The user sees that the edit did not apply and can discard it. §13 of the parent spec governs: a
server-side refusal never costs the user work without telling them.

**A line insert whose parent is not live** returns needs-attention ("referenced recipe is not live"),
because `_PARENT_CHECKS` requires both `recipe_id` and `ingredient_id` to be live at the op's location
(`api/services/sync.py:44-50`). Reachable if a recipe's own insert op parked; the editor is not reachable
for a recipe that does not exist locally, so this is a queue-level surface, not a UI flow.

**Org deletion scheduled** (`CS410`) and **future client clock** (`CS425`) behave exactly as in 2a — the
existing blocked-state flows and the pending queue's clock hint cover them unchanged.

## 8. Role gating

Recipe writes are owner/manager-only at the database level: RLS policies `recipe_write` and
`recipe_item_write` restrict `FOR ALL` to `role IN ('owner','manager')`, and `DELETE` is revoked outright
(`supabase/migrations/0012_business_tables.sql:104-118, 158-188`). Bookkeepers can read both tables.

The caller's role is persisted locally using the snapshot mechanism introduced at the end of Phase 2a for
location (`AppModel`, commit `30c9255`): written on every successful `/me`, keyed by user and org, cleared
on the erase paths, preserved through a plain sign-out — the same rules, for the same §13 reasons.

A bookkeeper gets a **read-only recipe detail**: lines and costing are visible, since reading is
permitted, but there is no new-recipe affordance, no editable field, and no swipe-to-delete. If the role
is unknown — only possible if the snapshot was cleared — recipes are read-only until a `/me` succeeds.
First launch cannot hit that case, because bootstrap fetches `/me` before the app reaches its main screen.

## 9. Validation rules

These mirror the web editor's guards, which exist for reasons worth preserving.

| Rule | Message / behavior | Why |
|---|---|---|
| A blank or unparseable quantity | never silently accepted. On a **stored** line: the field shows the error and **no op is minted**, so the last good quantity stands until a valid one is entered. On a **draft** line: Save is blocked | A dropped line is indistinguishable from an intentional removal and would tombstone real data (`web/js/lib.mjs:200-219`) |
| Saving a new recipe with no lines | blocked | Matches web's "Add at least one ingredient" (`web/js/app.js:941-944`) |
| Removing the **last** line of an existing recipe | blocked, pointing at deleting the recipe instead | A lineless recipe costs out at zero and would report a healthy food-cost percentage — worse than an error |
| An ingredient already on the recipe | filtered out of the picker | Prevents the `recipe_items_live_uq` rejection before it happens rather than after |
| Tombstoned ingredients | never offered | The picker already shows live ingredients only |
| Menu price, target FC% | must be > 0 | Matches the database CHECK constraints (`numeric(10,2)`, `numeric(5,2)`) |
| Quantity | must be > 0 | Matches `qty_base_units numeric(14,4) CHECK (> 0)` |

Every one of these values is a decimal string, validated as a string and stored as a string.

## 10. Costing and preview parity

An item's cost contribution is `qty_base_units × latest unit price`; per-item costs are rounded to two
decimals **first**, then summed as integer cents (`api/services/costing.py:76-79` and its Swift mirror) —
summing unrounded and rounding once can disagree by a cent, so the order is load-bearing.

Any unresolvable line (tombstoned ingredient, or no price history yet) nulls the whole recipe's food-cost
percentage, status and suggested price: **never reprice a partial**. The draft preview follows the same
contract, showing plate cost with an explicit incomplete marker rather than a misleading percentage.

Suggested price stays suppressed while sync state is not caught up, per the parent spec §5.5 — unchanged
from 2a, and it applies to the editor's preview too.

## 11. Testing and gates

**Kit unit tests:** each write path mints exactly the expected ops with the expected fields; quantity
coalescing; every §9 rejection; and — the critical one — **deleting a recipe enqueues one tombstone per
live line**.

**Parity tests:** the draft preview is pinned against `shared/golden-vectors.json`, so the phone's plate
cost agrees with both the web preview and the server's costing, the same discipline that kept the 2a
kernel honest.

**Sync tests** against 2a's `FakeSyncServer`: create-with-lines applies in table order in one batch; the
same-ingredient collision produces stale-and-adopt; a quantity edit against a server-tombstoned line
parks. **Two known gaps in that double must close first** (both logged during 2a): it omits
parent-liveness checks, and its equal-timestamp tie-break uses `<=` where the server uses `<`, inverting
the winner. This is the phase that needs them accurate.

The existing two-store convergence test extends to recipes: one device builds a dish, the other pulls it,
both edit, they converge.

**Backend is untouched** — no new routes, no migrations, plan limit deferred — so the 1,451 backend tests
serve as a pure regression gate.

**Acceptance** extends the Phase 2a XCUITest smoke: build a recipe with two lines offline, confirm it
shows costed on the Dashboard, sync, and assert the resulting server rows.

**Gates after every task:** `cd ios/CostSauceKit && swift test` green; `uv run --extra dev pytest -q`
green; `cd ios && xcodegen generate && xcodebuild -project CostSauce.xcodeproj -scheme CostSauce
-destination 'generic/platform=iOS Simulator' build -quiet` exit 0.

## 12. Targeted improvements included

Small, in-neighborhood cleanups, because this phase touches these files anyway:

- Extract the fuzzy ingredient picker out of `PurchaseEntryView.swift` into a shared component.
- Fix the `FakeSyncServer` equal-timestamp tie-break and add parent-liveness to the double (§11).
- Add a store-write wrapper so views never write the database directly — a 2a review follow-up made
  timely by the new pending-queue interactions (`PendingQueueView.swift:148` currently calls
  `store.deleteOp` directly).

Not included: unrelated refactoring. The other 2a follow-ups (deterministic multi-org store-file
selection, duplicated helper extraction) stay on their own list unless a task lands in that code.

## 13. Deferred, with triggers

| Deferred | Trigger that makes it urgent |
|---|---|
| Plan-limit enforcement (`max_recipes = 25`, advertised via `/me` but enforced nowhere — `api/models.py:10`) | A paying customer disputes the limit, or billing needs it real. Belongs server-side on both the REST and sync insert paths, and must answer what happens to orgs already over the limit |
| Duplicate-recipe-name detection | Users report confusion from two identically named dishes |
| Sub-recipes / nesting | A customer builds a prep item used across dishes and asks for it once |
| Manual line ordering | Users ask for a build order rather than alphabetical |
| Repointing an existing line's ingredient in place | Never via sync by design; if demanded, it is a merge-tool feature |

## 14. Human tasks

None new. The two open go-live items from Phase 2a still stand and are unrelated to this phase: the
Supabase OTP email template needs `{{ .Token }}`, and the iOS project has no code-signing configuration
for device or TestFlight builds. Both are on the Notion Human Action Board.

## 15. References

- Parent spec: `docs/superpowers/specs/2026-07-25-native-ios-app-design.md` (§5.4 upsert diff, §5.5
  suggestion suppression, §10.1 completeness, §13 data safety, §16 phases)
- Sync client contract: `api/routes/sync.py:1-30` (warnings a, b, c)
- Sync apply logic and allowlists: `api/services/sync.py:21-50, 227-279`
- Recipe REST routes (the diff semantics this phase reproduces offline): `api/routes/recipes.py:39-131`
- Schema and RLS: `supabase/migrations/0012_business_tables.sql:61-99, 104-188, 243-248`;
  `0014_sync_protocol.sql:21-28, 109-125, 153-202`
- Web reference implementation: `web/js/app.js:679-970`, `web/js/lib.mjs:139-328`
- Costing: `api/services/costing.py:46-104`, `api/kernel.py:112-145`,
  `ios/CostSauceKit/Sources/CostSauceKit/Costing/Costing.swift:79-196`
- iOS surface today: `ios/CostSauceKit/Sources/CostSauceKit/Store/{Records,LocalStore,LocalEdits}.swift`,
  `ios/CostSauce/Views/{DashboardView,PendingQueueView,PurchaseEntryView}.swift`
- Phase 2a plan (execution pattern this phase follows):
  `docs/superpowers/plans/2026-07-29-phase-2a-ios-offline-loop.md`
