# Phase 2b — iOS Recipe Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make recipes fully editable on the phone — create, edit name/menu price/target FC%, add lines, change line quantities, remove lines, delete the recipe — all offline, reconciling through the Phase 1c sync protocol, per `docs/superpowers/specs/2026-07-29-phase-2b-ios-recipe-editing-design.md` (approved, commit `f8c72eb`).

**Architecture:** Every rule lives in `ios/CostSauceKit` and is unit-tested headless via `swift test`; the app target stays thin SwiftUI. A new recipe is composed as a `RecipeDraft` — a Kit value type whose validation and op-production are pure functions — and becomes rows plus ops only on Save (spec D4). An existing recipe has no draft: each edit writes its row and enqueues its op immediately, through the same `LocalEdits` helpers. Deleting a recipe fans out an explicit tombstone op per live line, because the sync path has no implicit cascade (`api/routes/sync.py:15-22` warning b).

**Tech Stack:** Swift 6 (swift-tools-version 6.2, min iOS 26.0), SwiftUI + Observation, Swift Testing (`import Testing`, `@Test`/`#expect`/`#require`) for Kit tests, XCUITest for the smoke, GRDB (Kit-only), XcodeGen (project file not committed).

## Global Constraints

- **Backend, `supabase/`, `web/`, `shared/`, `product/` are untouched this phase.** No routes, no migrations, no new golden-vector classes (see Task 4's transitive parity). `uv run --extra dev pytest -q` is a pure regression gate: 1451 passed.
- **Decisions (Travis, 2026-07-29 — spec §2):** D1 full parity with web including delete; D2 persist the caller's role locally and gate the UI; D3 do **not** enforce the 25-recipe plan limit; D4 hybrid edit model (draft new, immediate edits); D5 no fifth tab — the Dashboard's Menu section becomes the navigable recipe list.
- **Silent LWW stands (from 2a):** no "changed on another device" UI anywhere. The single deliberate exception is a quantity edit against a line another device tombstoned — that op parks as `needs_attention` and is visible in the pending queue (spec §7).
- **Money/qty/pct are STRINGS** end-to-end: GRDB columns, op fields, view rendering (verbatim, `?? "—"` for nil). Arithmetic only through the Kit's `Int128` rationals. `Double`/`Float`/`Decimal` never touch a value. The only sanctioned `Double` is pixel geometry.
- **Ids are client-minted UUIDv7**, lowercase strings. `client_mutated_at`/`deleted_at` are `Kernel.canonicalTimestamp` (`yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'`, UTC).
- **Op `fields` keys must be subsets of the server allowlists** (`api/services/sync.py:23-38`) or the op parks: `INSERT_FIELDS.recipes = {name, menu_price, target_fc_pct, deleted_at}`; `INSERT_FIELDS.recipe_items = {recipe_id, ingredient_id, qty_base_units, deleted_at}`; `UPDATE_FIELDS.recipes` = the same four; **`UPDATE_FIELDS.recipe_items = {qty_base_units, deleted_at}` only** — `recipe_id`/`ingredient_id` are immutable over sync, so changing a line's ingredient is **remove-and-add**, never an in-place update.
- **`TABLE_ORDER = ("ingredients", "recipes", "recipe_items", "purchases")`** (`api/services/sync.py:23`) — the server sorts a push batch by table before applying, so a recipe always applies before its lines. `MAX_BATCH_OPS = 200`; the 2a engine already chunks.
- **Suppress `suggested_price` while sync state ≠ caught-up** (spec §5.5) — applies to the editor's preview too.
- **§13 data safety:** a server-side refusal never costs the user work silently. Recipe writes are owner/manager-only in RLS (`supabase/migrations/0012_business_tables.sql:158-188`); a bookkeeper must never see a write affordance.
- **`KernelError` is a struct with a `message: String`**, not an enum — never `switch` over it.
- **Test gates after every task:** `cd ios/CostSauceKit && swift test` green; `uv run --extra dev pytest -q` green (unchanged); `cd ios && xcodegen generate && xcodebuild -project CostSauce.xcodeproj -scheme CostSauce -destination 'generic/platform=iOS Simulator' build -quiet` exit 0, zero warnings.
- **Commits:** one per task — `feat(2b): …` / `fix(2b): …` / `test(2b): …` / `docs(2b): …`.
- **Out of scope (do not build):** sub-recipes/nesting; yields/portions; any unit conversion on a line; duplicate-recipe-name detection; plan-limit enforcement (D3); manual line ordering; in-place ingredient repointing; conflict-resolution UI; invoice OCR, push notifications, SIWA.

## File Structure

```
ios/CostSauceKit/Sources/CostSauceKit/
  Store/LocalStore.swift          # Task 1: + recipe(id:), liveRecipeItems(recipeId:)
  Store/LocalEdits.swift          # Task 1: + updateRecipeFields, addRecipeLine, updateRecipeLineQty,
                                  #           tombstoneRecipeLine
                                  # Task 2: + tombstoneRecipe (the fan-out)
                                  # Task 3: + saveNewRecipe(draft:)
  Store/RecipeDraft.swift         # Task 3: value type + pure validate() -> [DraftError]
  Costing/Costing.swift           # Task 4: + PreviewResult, previewPlate(lines:menuPrice:targetFcPct:
                                  #           ingredients:drift:)
ios/CostSauceKit/Tests/CostSauceKitTests/
  LocalEditsTests.swift           # Tasks 1-3: appended
  RecipeDraftTests.swift          # Task 3
  CostingTests.swift              # Task 4: appended (transitive parity)
  FakeSyncServer.swift            # Task 5: tie-break fix + parent-liveness
  SyncEngineTests.swift           # Task 5: appended (recipe sync scenarios)
ios/CostSauce/
  AppModel.swift                  # Task 6: role snapshot, callerRole, canEditRecipes, discardOp
  Views/PendingQueueView.swift    # Task 6: use appModel.discardOp; + salientValue recipe cases
  Views/IngredientPickerView.swift # Task 7: extracted from PurchaseEntryView (new file)
  Views/PurchaseEntryView.swift   # Task 7: consumes the extracted picker
  Views/RecipeEditorView.swift    # Task 8 (create/draft path), Task 9 (edit path + delete)
  Views/DashboardView.swift       # Task 10: MenuSection navigable + new-recipe affordance + copy
  Views/IngredientsListView.swift # Task 10: in-use message no longer points at the web app
ios/CostSauceUITests/SmokeTests.swift   # Task 11
docs/runbooks/phase-2b-acceptance.md    # Task 11
```

---

### Task 1: Store reads + the three in-place recipe mutations

**Files:** Modify `Store/LocalStore.swift`, `Store/LocalEdits.swift`; Test `Tests/CostSauceKitTests/LocalEditsTests.swift` (append).

**Interfaces (frozen):**
```swift
extension LocalStore {
  public func recipe(id: String) throws -> LocalRecipe?          // mirror ingredient(id:) — no deleted_at filter,
                                                                 // callers decide
  public func liveRecipeItems(recipeId: String) throws -> [LocalRecipeItem]
  //   WHERE recipe_id = ? AND deleted_at IS NULL ORDER BY id — the existing liveRecipeItems() stays
  //   (DashboardModel consumes it unfiltered); this is an overload, not a replacement
}

extension LocalEdits {                                           // all three: mint op_id UUIDv7,
  public func updateRecipeFields(id: String, name: String?, menuPrice: String?,   // client_mutated_at =
                                 targetFcPct: String?, now: Date = Date()) throws // canonicalTimestamp(now),
  //   nil parameter = "unchanged, omit from fields". Empty fields dict → no-op, enqueue NOTHING (a no-change
  //   Save must not mint an op). name trimmed; guards: trimmed name non-empty, menuPrice/targetFcPct parse as
  //   Rational and are > 0 else KernelError (schema CHECKs: numeric(10,2) > 0, numeric(5,2) > 0).
  //   fields ⊆ UPDATE_FIELDS.recipes.
  public func addRecipeLine(recipeId: String, ingredientId: String, qty: String,
                            now: Date = Date()) throws -> String
  //   returns the minted line id. Guards, in this order: recipe(id:) exists and deleted_at == nil else
  //   KernelError("recipe is not live"); ingredient(id:) exists and live else KernelError("ingredient is not
  //   live"); qty parses > 0 else KernelError("quantity must be greater than zero"); no live line already
  //   holds that ingredient else EditError.duplicate(existingId: <that line id>, name: <ingredient name>)
  //   — pre-empting recipe_items_live_uq. fields = {recipe_id, ingredient_id, qty_base_units} (insert).
  public func updateRecipeLineQty(itemId: String, qty: String, now: Date = Date()) throws
  //   guards: line exists and live else KernelError("recipe line is not live"); qty parses > 0.
  //   fields = {qty_base_units} ONLY — never ingredient_id/recipe_id (immutable over sync).
  public func tombstoneRecipeLine(itemId: String, now: Date = Date()) throws
  //   fields = {deleted_at: canonicalTimestamp(now)}. Guard: it must not be the recipe's LAST live line —
  //   else EditError.lastLine. (New case, see below.)
  //   Rationale (spec §9): a lineless recipe costs out at zero and reports a healthy FC% — worse than an error.
}

// LocalEdits.EditError gains one case; the existing two are unchanged:
public enum EditError: Error, Equatable {
  case duplicate(existingId: String, name: String)
  case inUse(count: Int)
  case lastLine                                                  // NEW — Task 1
}
```

- [ ] **Step 1: failing tests** — append to `LocalEditsTests.swift`, using the file's existing setup idiom (`LocalStore.inMemory()` → `store.bind(...)` → seed via `store.applyPullPage(...)`; `LocalEdits(store:locationId:)`). Seed one live recipe with two live lines over two live ingredients. Assert: `updateRecipeFields(id:name:"  Carbonara  ", menuPrice: nil, targetFcPct: nil)` enqueues exactly one op whose `fields` keys are exactly `["name"]` and whose `name` is `"Carbonara"` (trimmed) — and that passing all three as `nil` enqueues **zero** ops (`store.pendingCount()` unchanged); `menuPrice: "0"` throws `KernelError`; `addRecipeLine` on a third ingredient returns a 36-char lowercase id, writes a live row readable through `liveRecipeItems(recipeId:)` (now 3 rows), and enqueues one op with fields keys exactly `["recipe_id", "ingredient_id", "qty_base_units"]`; `addRecipeLine` re-using an ingredient already on the recipe throws `EditError.duplicate` carrying that line's id; `addRecipeLine` against a tombstoned ingredient throws `KernelError`; `updateRecipeLineQty` enqueues fields keys exactly `["qty_base_units"]`; `tombstoneRecipeLine` on one of two lines enqueues fields keys exactly `["deleted_at"]` with a canonical timestamp and leaves 1 live line; `tombstoneRecipeLine` on that last remaining line throws `EditError.lastLine` and enqueues nothing; `recipe(id:)` returns nil for an unknown id; `liveRecipeItems(recipeId:)` excludes a tombstoned line and excludes another recipe's lines.
- [ ] **Step 2:** `cd ios/CostSauceKit && swift test` → FAIL. **Step 3:** implement (follow `createIngredient`/`tombstoneIngredient` verbatim for the minting + single-transaction shape). **Step 4:** `swift test` → PASS. **Step 5:** commit `feat(2b): store reads and in-place recipe mutations with op minting`.

---

### Task 2: Delete a recipe — the tombstone fan-out

**Files:** Modify `Store/LocalEdits.swift`; Test `LocalEditsTests.swift` (append).

**Interfaces (frozen):**
```swift
extension LocalEdits {
  public func tombstoneRecipe(id: String, now: Date = Date()) throws
  //   ONE transaction, ONE timestamp (`let ts = Kernel.canonicalTimestamp(now)`) shared by every op:
  //     1. guard recipe(id:) exists && deleted_at == nil else KernelError("recipe is not live")
  //     2. for EVERY row of liveRecipeItems(recipeId: id): tombstone the row + enqueue an update op with
  //        fields = {deleted_at: ts}
  //     3. tombstone the recipe row + enqueue an update op with fields = {deleted_at: ts}
  //   This is warning (b) of api/routes/sync.py:15-22: a recipe tombstone op does NOT cascade to its lines
  //   server-side (unlike DELETE /locations/{id}/recipes/{id}, which does). Skipping the fan-out strands live
  //   lines against a dead recipe, which cost_recipes surfaces as a loud data-integrity complaint.
  //   Op ORDER within the batch does not matter (the server sorts by TABLE_ORDER), but all ops MUST be
  //   enqueued atomically with the local writes so a crash cannot leave a half-deleted recipe.
  //   Bypasses EditError.lastLine deliberately: deleting the recipe is exactly the sanctioned way to remove
  //   its final line.
}
```

- [ ] **Step 1: failing tests** — append to `LocalEditsTests.swift`. Seed a live recipe with **three** live lines plus a second recipe with one line and a fourth already-tombstoned line on the first recipe. Assert: `tombstoneRecipe` enqueues exactly **4** ops (3 lines + 1 recipe) — count via `store.exportPendingOps()`; every one of the 4 carries `fields` keys exactly `["deleted_at"]`; **all four share the identical timestamp string**; the op set's `(table, row_id)` pairs are exactly the 3 line ids on `recipe_items` plus the recipe id on `recipes`; the already-tombstoned line gets **no** op (no double-tombstone); the second recipe and its line are untouched (still live, no ops); after the call `liveRecipeItems(recipeId:)` is empty and `recipe(id:)?.deleted_at` is non-nil; `liveRecipes()` no longer contains it; calling `tombstoneRecipe` again throws `KernelError` and enqueues nothing. Add a fan-out completeness test that is robust to future seeding changes: for a recipe seeded with N live lines (N = 5), assert op count == N + 1.
- [ ] **Step 2:** `swift test` → FAIL. **Step 3:** implement. **Step 4:** `swift test` → PASS. **Step 5:** commit `feat(2b): recipe delete fans out an explicit tombstone op per live line`.

---

### Task 3: `RecipeDraft` — pure validation and the create path

**Files:** Create `Store/RecipeDraft.swift`, `Tests/CostSauceKitTests/RecipeDraftTests.swift`; Modify `Store/LocalEdits.swift`; Test `LocalEditsTests.swift` (append).

**Interfaces (frozen):**
```swift
public struct RecipeDraft: Equatable, Sendable {                  // RecipeDraft.swift
  public struct Line: Equatable, Sendable, Identifiable {
    public let id: UUID                                           // view identity ONLY, never persisted
    public var ingredientId: String
    public var qty: String
    public init(ingredientId: String, qty: String)                // id = UUID() internally
  }
  public var name: String
  public var menuPrice: String
  public var targetFcPct: String
  public var lines: [Line]                                        // sequence is PRESENTATION ONLY (spec §6):
                                                                  // never persisted, no order column exists
  public init(name: String = "", menuPrice: String = "",
              targetFcPct: String = "30.00", lines: [Line] = [])   // 30.00 mirrors the schema DEFAULT

  public enum DraftError: Error, Equatable {
    case nameEmpty                                                // "Enter a name."
    case menuPriceInvalid                                         // "Menu price must be greater than zero."
    case targetFcPctInvalid                                       // "Target food cost % must be greater than zero."
    case noLines                                                  // "Add at least one ingredient."
    case lineQtyInvalid(lineId: UUID)                             // "Quantity must be greater than zero."
    case duplicateIngredient(ingredientId: String)                // "That ingredient is already on this recipe."
  }
  public func validate() -> [DraftError]
  //   PURE — no store, no view state. Returns ALL failures, in the enum's declaration order, so the editor can
  //   mark every bad field at once. name: Kernel.normalizeName non-empty. menuPrice/targetFcPct: parse as
  //   Rational and > 0. lines non-empty. each line qty parses > 0. no ingredientId appears twice.
  //   The messages above are the exact user-facing strings; they live in the VIEW (Task 8), not here.
}

extension LocalEdits {
  public func saveNewRecipe(_ draft: RecipeDraft, now: Date = Date()) throws -> String
  //   returns the minted recipe id. Order: validate() first — non-empty result throws the FIRST error
  //   (the view pre-validates, so this is a backstop, not the UI path). Then ONE transaction, ONE timestamp:
  //     1. mint recipe id; write the recipe row; enqueue insert op, fields = {name (trimmed), menu_price,
  //        target_fc_pct}  ⊆ INSERT_FIELDS.recipes
  //     2. for each draft line: verify the ingredient is live else KernelError("ingredient is not live");
  //        mint a line id; write the row; enqueue insert op, fields = {recipe_id, ingredient_id, qty_base_units}
  //   Safe in one push despite the FK: TABLE_ORDER applies all `recipes` ops before any `recipe_items` ops.
}
```

- [ ] **Step 1: failing tests** — `RecipeDraftTests.swift` (pure, no store): a fully valid draft returns `[]`; an empty name returns `[.nameEmpty]`; a whitespace-only name (`"   "`) also returns `[.nameEmpty]` (normalizeName, not `isEmpty`); `menuPrice: "0"`, `"-1"`, `"abc"`, `""` each return `[.menuPriceInvalid]`; same four for `targetFcPct`; `lines: []` returns `[.noLines]`; a line with qty `"0"` returns `[.lineQtyInvalid(lineId:)]` carrying that line's id; two lines on the same ingredient return `[.duplicateIngredient(ingredientId:)]`; a draft that is wrong in three ways returns all three errors in enum-declaration order (assert the exact array); `menuPrice: "18.005"` (more decimals than the column) is **accepted** by validate — the string is stored verbatim and the server's numeric(10,2) is authoritative, matching how purchase totals already behave. Then append to `LocalEditsTests.swift`: `saveNewRecipe` with two lines enqueues exactly **3** ops — 1 on `recipes` with fields keys exactly `["name","menu_price","target_fc_pct"]`, and 2 on `recipe_items` with fields keys exactly `["recipe_id","ingredient_id","qty_base_units"]` whose `recipe_id` equals the returned recipe id; all 3 share one timestamp; the recipe and both lines are immediately readable (`liveRecipes()` contains it, `liveRecipeItems(recipeId:)` has 2); a draft naming a tombstoned ingredient throws `KernelError` and enqueues **nothing** (assert `pendingCount()` unchanged — the transaction must roll back); an invalid draft throws its first `DraftError` and enqueues nothing.
- [ ] **Step 2:** `swift test` → FAIL. **Step 3:** implement. **Step 4:** `swift test` → PASS. **Step 5:** commit `feat(2b): RecipeDraft with pure validation and the offline create path`.

---

### Task 4: Draft plate-cost preview, pinned transitively to `costRecipes`

**Files:** Modify `Costing/Costing.swift`; Test `Tests/CostSauceKitTests/CostingTests.swift` (append).

**Interfaces (frozen):**
```swift
extension Costing {
  public struct PreviewResult: Equatable, Sendable {
    public let plateCost: String                                  // always present, "0.00" for zero lines
    public let complete: Bool                                     // false if ANY line is unresolvable
    public let fcPct: String?                                     // nil unless complete
    public let status: String?                                    // nil unless complete
    public let suggestedPrice: String?                            // nil unless complete
  }
  public static func previewPlate(lines: [(ingredientId: String, qty: String)],
                                  menuPrice: String?, targetFcPct: String?,
                                  ingredients: [LocalIngredient],
                                  drift: [String: DriftResult]) throws -> PreviewResult
  //   The draft-time twin of costRecipes, for lines that are not yet rows. IDENTICAL math and IDENTICAL
  //   order of operations (api/services/costing.py:76-79, mirrored in Costing.costRecipes):
  //     per line: resolvable = ingredient exists && live && drift[ingredientId] != nil;
  //               cost = Kernel.roundHalfAway(qty · latestPrice, 2)   ← ROUND EACH LINE
  //     plateCost = moneyFromCents(Σ of the rounded line cents)       ← THEN SUM
  //   Summing unrounded and rounding once disagrees by a cent — the order is load-bearing.
  //   complete = every line resolvable AND lines non-empty. When complete AND menuPrice/targetFcPct are
  //   non-nil: fcPct/status via Kernel.fcStatus(plateCents, menuCents, targetBp), suggestedPrice via
  //   suggestedPriceCents → moneyFromCents. Otherwise all three nil — §10.1, never reprice a partial.
  //   An unresolvable line contributes NOTHING to plateCost (it has no price), matching costRecipes.
}
```

- [ ] **Step 1: failing tests** — append to `CostingTests.swift`. **The parity test is the point of this task:** for each existing costing fixture in the file, build `lines` from the same `(ingredient_id, qty_base_units)` pairs and assert `previewPlate(...).plateCost == <that fixture's costRecipes plateCost>` and `.complete` matches — explicitly including the round-then-sum fixture (two items at `"1.005"` each → each rounds to `"1.01"` → plate `"2.02"`, **not** `"2.01"`), which is the case that fails if the implementation sums first. Then: zero lines → `plateCost "0.00"`, `complete false`, all three optionals nil; a line whose ingredient has no drift entry → `complete false`, `fcPct`/`status`/`suggestedPrice` nil, and `plateCost` equals the sum of the *resolvable* lines only; a line whose ingredient is tombstoned → same; complete lines with `menuPrice "18.00"`, `targetFcPct "30.00"` → `fcPct`/`status`/`suggestedPrice` equal to what `Kernel.fcStatus`/`suggestedPriceCents` return for the same cents (compute the expectation from the kernel, not a hardcoded literal, so the test cannot drift from the pinned primitives); `menuPrice: nil` with complete lines → `plateCost` present but `fcPct`/`status`/`suggestedPrice` nil; suggested price formats as `"4.00"` never `"4.0"`.
- [ ] **Step 2:** `swift test` → FAIL. **Step 3:** implement. **Step 4:** `swift test` → PASS. **Step 5:** commit `feat(2b): draft plate-cost preview, pinned to costRecipes' rounding order`.

---

### Task 5: Sync-double fidelity, then the recipe sync scenarios

**Files:** Modify `Tests/CostSauceKitTests/FakeSyncServer.swift`; Test `Tests/CostSauceKitTests/SyncEngineTests.swift` (append).

**Interfaces (frozen):** no production code changes in this task — it makes the test double faithful, then proves the recipe flows against it.

```
FIX 1 — equal-timestamp tie-break (FakeSyncServer.swift:353).
  Currently:  if clientMutatedAt <= existingCM { return stale/older + row_id }
  Change to:  if clientMutatedAt <  existingCM { return stale/older + row_id }
  Why: the real server's recipe_items upsert applies when `recipe_items.client_mutated_at <= EXCLUDED
  .client_mutated_at` (api/services/sync.py:257), i.e. it rejects ONLY when strictly older — an equal
  timestamp WINS. The double currently rejects ties, inverting the winner. This also aligns it with the
  double's own plain-update path, which already uses strict `<` (FakeSyncServer.swift:311).

FIX 2 — parent liveness on insert (add to applyInsert, before the recipe_items arbitration block).
  Mirror api/services/sync.py:44-50 `_PARENT_CHECKS`:
    recipe_items → recipe_id must name a live `recipes` row at this location,
                   ingredient_id must name a live `ingredients` row at this location
    purchases    → ingredient_id must name a live `ingredients` row at this location
  On failure return ["status": "needs_attention", "reason": "referenced \(label) is not live"] with label
  "recipe" or "ingredient" — the server's exact wording. "Live" = row exists, location_id matches, and
  deleted_at is absent/empty (use the same emptiness test the file already uses for deleted_at).
```

- [ ] **Step 1: failing tests** — append to `SyncEngineTests.swift`, reusing the file's fixed canonical timestamps (`t1 < t2 < t3`) and its `StubTransport` mounting helper. (a) **Tie-break:** a minted `recipe_items` insert whose `client_mutated_at` **equals** the canonical row's now returns `applied` and the local row survives — the test that fails before FIX 1. (b) Keep the inverted case honest: strictly-older still returns `stale`/`older` with the canonical `row_id` and the client adopts it (the existing `staleRecipeItemConflictAdoptsCanonicalRowAndConvergesToServerValue` must still pass untouched). (c) **Parent liveness:** an insert op for a `recipe_items` row whose `recipe_id` names no server row parks as `needs_attention` with reason `"referenced recipe is not live"`, and the op stays in the queue (not deleted) — the test that fails before FIX 2; same for a tombstoned `ingredient_id`. (d) **Create-with-lines in one batch:** enqueue `saveNewRecipe`'s 3 ops (1 recipe + 2 lines) and push once — all 3 return `applied` even though the lines' FK parent is in the same batch, proving `TABLE_ORDER` sorting; assert the server ended with 1 recipe and 2 lines. (e) **Delete fan-out round-trip:** enqueue `tombstoneRecipe`'s N+1 ops, push once, assert every op `applied` and the server has zero live lines for that recipe — the end-to-end guard for Task 2. (f) **Quantity edit against a server-tombstoned line:** the server row's `deleted_at` is set; the queued update returns `stale`/`deleted`; assert the op **parks as needs_attention rather than being deleted** (spec §7's one deliberate exception to silence) and that a trailing pull removes the line locally. (g) **Two-store convergence:** extend the existing convergence test so store A creates a recipe with two lines, store B pulls, B edits one quantity, A tombstones the other line, both push and pull, and both stores end field-identical with identical row counts.
- [ ] **Step 2:** `swift test` → FAIL on (a), (c), (f). **Step 3:** apply FIX 1 and FIX 2, and add only what (d)-(g) need inside the two test files (fixtures, seeding, assertions). **No production code changes belong in this task** — Tasks 1-3 already supply every `LocalEdits` method these scenarios exercise, and the 2a sync engine handles them unmodified. If a scenario exposes a genuine production gap, stop and report it rather than fixing it here, so it can be scoped as its own task. **Step 4:** `swift test` → PASS, and confirm the pre-existing sync tests still pass unchanged. **Step 5:** commit `test(2b): faithful recipe_items arbitration and parent liveness in the sync double`.

---

### Task 6: `AppModel` — role snapshot, edit gating, and a store-write wrapper

**Files:** Modify `ios/CostSauce/AppModel.swift`, `ios/CostSauce/Views/PendingQueueView.swift`.

**Interfaces (frozen):**
```swift
extension AppModel {                                              // mirror the location-snapshot mechanism
  // Stored (observable): public var callerRole: String?          // "owner" | "manager" | "bookkeeper" | nil
  public var canEditRecipes: Bool { callerRole == "owner" || callerRole == "manager" }
  //   Unknown role (nil) → false: read-only until a /me succeeds. Bootstrap fetches /me before .main, so a
  //   normal launch always knows the role; nil is only reachable if the snapshot was cleared (spec §8).
  //   RLS truth: recipe_write/recipe_item_write are owner/manager only
  //   (supabase/migrations/0012_business_tables.sql:158-188).

  // Snapshot, copying the location-snapshot code shape EXACTLY (key builder + save/load/clear statics):
  //   key   = "roleSnapshot-\(userId)-\(orgId)"                   // per membership, not per location
  //   save  → on EVERY successful /me that resolves a membership for boundOrgId. Find them by grepping
  //           `api.me()` across ios/CostSauce/: the bootstrap/refresh sites in AppModel.swift, plus the
  //           membership-resolving calls SettingsView.swift and MembersView.swift make (2a added those
  //           because AppModel.membership is not populated on the fast path). Every one must save.
  //   load  → in tryFastPathToMain, alongside the location-snapshot load, before phase = .main
  //   clear → on BOTH erase paths (switchAccountAndErase, eraseDeviceAndSignOut), beside
  //           removeStoreFile, using the same pre-wipe meta
  //   NOT cleared on plain signOut — same reasoning as the location snapshot and the sqlite file (§13)

  public func discardOp(_ opId: String) throws                    // wraps store.deleteOp + refreshes pendingCount
  //   Replaces PendingQueueView.swift:148's direct `try? appModel.store?.deleteOp(...)`: views never write
  //   the store (a 2a review follow-up). Surfaces the throw so the view can show a failure instead of
  //   swallowing it with `try?`.
}
```

- [ ] **Step 1:** add `callerRole` + `canEditRecipes` + the three snapshot statics, wire save/load/clear at the call sites named above (grep every `saveLocationSnapshot`/`clearLocationSnapshot` site and pair each one), and add `discardOp`. **Step 2:** change `PendingQueueView`'s discard action to `try appModel.discardOp(op.op_id)` inside a do/catch that sets the view's existing error state on failure; add the missing `salientValue` cases for `"recipes"` (show `fields["name"]`) and `"recipe_items"` (show `fields["qty_base_units"]`) so recipe ops render a value like every other row — `singularTableName` already handles both tables. **Step 3:** `swift test` → still green (no Kit change); `xcodegen generate && xcodebuild … build -quiet` → exit 0, zero warnings. **Step 4:** walk the four snapshot paths in the report — fast-path load, /me save, both erases clear, plain sign-out preserves — since there is no app unit-test target. **Step 5:** commit `feat(2b): persist caller role for offline edit gating; wrap store writes behind AppModel`.

---

### Task 7: Extract the ingredient picker into a reusable component

**Files:** Create `ios/CostSauce/Views/IngredientPickerView.swift`; Modify `ios/CostSauce/Views/PurchaseEntryView.swift`.

**Interfaces (frozen):**
```swift
struct IngredientPickerView: View {                               // pure extraction — behavior must not change
  let excludedIngredientIds: Set<String>                          // NEW capability: recipe editor passes the
                                                                  // ingredients already on the recipe so they
                                                                  // cannot be picked twice (spec §9).
                                                                  // PurchaseEntryView passes [].
  let onPick: (LocalIngredient) -> Void
  //   Everything else moves verbatim from PurchaseEntryView: the query field, the Kernel.matchIngredient /
  //   nearMatches call sites, the match rows, the candidate load (its own RefreshKey + .task(id:)), and the
  //   "create new ingredient" secondary path including CreateIngredientSheet (which keeps its existing
  //   appModel.syncSoon() call — 2a fix 1f9a4f5).
  //   Candidates are filtered by excludedIngredientIds AFTER matching, so exclusion cannot change ranking.
}
```

- [ ] **Step 1:** move the picker and `CreateIngredientSheet` into the new file unchanged except for the `excludedIngredientIds` filter and the `onPick` callback; have `PurchaseEntryView` consume `IngredientPickerView(excludedIngredientIds: [], onPick: { … })` with its existing selection behavior. **Step 2:** `swift test` → green (Kit untouched); `xcodegen generate && xcodebuild … build -quiet` → exit 0, zero warnings. **Step 3:** re-verify the purchase flow by hand in the simulator — search, pick, create-new, save — and record the result in the report; this is a refactor whose only proof is that the existing flow still works. **Step 4:** commit `refactor(2b): extract the fuzzy ingredient picker for reuse by the recipe editor`.

---

### Task 8: Recipe editor — the create path

**Files:** Create `ios/CostSauce/Views/RecipeEditorView.swift`.

**Interfaces (frozen):**
```swift
struct RecipeEditorView: View {
  enum Mode { case create, edit(recipeId: String) }               // Task 8 implements .create; Task 9 .edit
  let mode: Mode
  //   .create holds a `RecipeDraft` in @State and writes NOTHING until Save (spec D4).
  //   Fields: Name, Menu price, Target FC% (decimal-pad keyboards, string bindings — never a numeric type).
  //   Lines: each row shows the ingredient name + a qty field; swipe-to-delete removes it from the draft
  //     (no op — nothing exists yet). "+ Add ingredient" presents IngredientPickerView with
  //     excludedIngredientIds = the draft's current ingredient ids.
  //   Preview: Costing.previewPlate over the draft's lines, recomputed on every change, rendering
  //     "Plate $X.XX" plus FC% and status when complete; when incomplete show "—" for FC% and the marker
  //     "Add prices to see food cost" (no misleading percentage). suggestedPrice ALSO obeys
  //     appModel.suppressSuggestions → "syncing…" (§5.5), exactly as MenuRow does.
  //   Save: draft.validate() first; non-empty → mark the offending fields with the DraftError messages from
  //     Task 3's frozen list and do not write. Empty → try edits.saveNewRecipe(draft) then
  //     appModel.syncSoon() then dismiss. A thrown KernelError shows its `.message` (it is a struct, not an
  //     enum — do not switch). Save is disabled while a save is in flight.
  //   Gating: unreachable when appModel.canEditRecipes == false (Task 10 hides the entry point), but the
  //     Save button is ALSO disabled on !canEditRecipes as a second line of defence.
}
```

- [ ] **Step 1:** build the create path against the frozen interface, following Tasks 9-13's view idiom (`@Environment(AppModel.self)`, `RefreshKey` + `.task(id:)` for any store read, money strings rendered verbatim with `?? "—"`). **Step 2:** `swift test` → green; `xcodegen generate && xcodebuild … build -quiet` → exit 0, zero warnings. **Step 3:** in the simulator against a local stack, create a two-line recipe offline (airplane mode), confirm the preview's plate cost matches what the Dashboard shows for it after Save, and confirm the pending queue holds exactly 3 ops; record it in the report. **Step 4:** commit `feat(2b): recipe editor — offline compose with live plate-cost preview`.

---

### Task 9: Recipe editor — the edit path and delete

**Files:** Modify `ios/CostSauce/Views/RecipeEditorView.swift`.

**Interfaces (frozen):**
```
.edit(recipeId:) — no draft. Every change writes its row and enqueues its op immediately (spec D4), then
calls appModel.syncSoon(). Reads come from store.recipe(id:) + store.liveRecipeItems(recipeId:) through the
RefreshKey/.task(id:) idiom, so a pull that changes the recipe re-renders it.

  Name / Menu price / Target FC%   → on commit (field blur or return), if the value actually changed call
                                     edits.updateRecipeFields with ONLY the changed parameter(s); an unchanged
                                     field mints nothing (Task 1 guarantees an empty fields dict enqueues no op).
  Line quantity                    → edits.updateRecipeLineQty, debounced 500 ms (reuse syncSoon's debounce
                                     shape) so typing "0.25" mints one op, not four. A blank or unparseable
                                     value shows the field error and mints NOTHING — the last good quantity
                                     stands (spec §9).
  + Add ingredient                 → IngredientPickerView(excludedIngredientIds: <lines' ingredient ids>) →
                                     edits.addRecipeLine. EditError.duplicate cannot normally surface (the
                                     picker excludes), but catch it and show "That ingredient is already on
                                     this recipe." rather than crashing.
  Swipe a line → Remove            → confirmation dialog (the IngredientsListView pattern) →
                                     edits.tombstoneRecipeLine. EditError.lastLine shows
                                     "A recipe needs at least one ingredient. Delete the recipe instead."
  Delete recipe (destructive row)  → confirmation dialog naming the recipe → edits.tombstoneRecipe → dismiss.
                                     The dialog states what happens: "This removes the recipe and its N
                                     ingredient lines." (N = live line count.)
  Changing a line's ingredient     → NOT offered. The ingredient is immutable over sync; the affordance is
                                     remove-then-add, matching web (web/js/app.js:802-810). The row shows the
                                     ingredient as fixed text, never a picker.
  Bookkeeper (canEditRecipes == false) → every field is read-only text, no swipe actions, no add row, no
                                     delete row. Costing and lines remain visible (RLS permits reads).
```

- [ ] **Step 1:** implement the edit path and delete against the frozen behavior above. **Step 2:** `swift test` → green; `xcodegen generate && xcodebuild … build -quiet` → exit 0, zero warnings. **Step 3:** in the simulator: change a quantity and confirm exactly one op is queued (not one per keystroke); add a line and confirm the picker excludes ingredients already present; try to remove the only line and see the `lastLine` message; delete a recipe and confirm the pending queue holds N+1 ops; flip a fixture membership to `bookkeeper` and confirm the screen is fully read-only. Record each in the report. **Step 4:** commit `feat(2b): recipe editor — live edits, line removal, and recipe delete`.

---

### Task 10: Surface it — Dashboard Menu becomes the recipe list

**Files:** Modify `ios/CostSauce/Views/DashboardView.swift`, `ios/CostSauce/Views/IngredientsListView.swift`.

**Interfaces (frozen):**
```
DashboardView.MenuSection (DashboardView.swift:243-262) — keep the existing MenuRow rendering and its §5.5
suppression branch EXACTLY as they are; add navigation and creation only:
  - each MenuRow becomes a NavigationLink to RecipeEditorView(mode: .edit(recipeId:))
  - the section header gains a "+" button → RecipeEditorView(mode: .create), shown only when
    appModel.canEditRecipes
  - the empty-state string changes from
      "Recipes are created on the web app; they cost themselves here automatically."
    to, when canEditRecipes:  "No recipes yet. Tap + to build your first one."
       when !canEditRecipes:  "No recipes yet."
    (D5: no fifth tab — this section IS the recipe list.)

IngredientsListView.swift:143 — the in-use message must stop pointing at the web app now that removal is
possible on the phone. Change
  "Used by N recipe line(s). Remove it from those recipes on the web app, or merge it there."
to
  "Used by N recipe line(s). Remove it from those recipes first."
(Merging remains web-only, so do not promise it here.)
```

- [ ] **Step 1:** make the changes above. **Step 2:** `swift test` → green; `xcodegen generate && xcodebuild … build -quiet` → exit 0, zero warnings. **Step 3:** in the simulator confirm: tapping a menu row opens that recipe, "+" opens an empty editor, "+" is absent for a bookkeeper, and both empty-state strings render for the right role. **Step 4:** commit `feat(2b): the Dashboard menu section becomes the navigable recipe list`.

---

### Task 11: Acceptance — XCUITest recipe flow and the runbook

**Files:** Modify `ios/CostSauceUITests/SmokeTests.swift`; Create `docs/runbooks/phase-2b-acceptance.md`.

**Interfaces (frozen):** none — this task proves the phase end-to-end against a real stack.

```
Environment facts (from the 2a acceptance, do not rediscover them):
  - Docker is required for pytest; the postgres:17 image is CACHED — never `docker pull` (this machine has
    no docker-credential-desktop on PATH and pulls fail).
  - Port 8400 is occupied by an unrelated long-running process. Use 8401+.
  - Use the first ELIGIBLE simulator (iPhone 17 Pro), not the first listed — the literal first is an iOS 18.2
    device, ineligible for the iOS 26.0 deployment target.
  - SmokeTests.swift currently hardcodes http://127.0.0.1:8401; read API_BASE_URL from the environment with
    that value as the default while you are in the file (a 2a deferred minor).
  - Tear down everything you start: container, uvicorn, temp files. Leave the tree exactly as your commit says.
```

- [ ] **Step 1:** extend the smoke, in its existing idiom (`app.textFields["<label>"]`, the `scrollToReveal` small-step helper): after login and bootstrap, create a recipe with two lines through the real UI, assert the editor's preview plate cost, save, assert the recipe appears in the Dashboard's Menu section with that same plate cost, then sync and assert via SQL that the server holds 1 `recipes` row and 2 live `recipe_items` rows with the expected `qty_base_units`, and that `sync_ops` holds exactly the 3 pushed ops as `applied`. Then edit one quantity, sync, and assert the server row's `qty_base_units` changed and no duplicate line appeared. Then delete the recipe, sync, and assert the recipe **and both lines** are tombstoned server-side — the fan-out's end-to-end proof. **Step 2:** run it: `xcodebuild test` against a fresh disposable Postgres + local uvicorn on 8401 + an iPhone 17 Pro simulator. Expect TEST SUCCEEDED; run it 3 times to prove it is not flaky. **Step 3:** write `docs/runbooks/phase-2b-acceptance.md` in the house style of `docs/runbooks/phase-2a-acceptance.md`, recording the actual commands and their real outputs (including the SQL assertions), plus any go-live items discovered. **Step 4:** full gates: `swift test`, `uv run --extra dev pytest -q` (1451), `xcodebuild build -quiet`. **Step 5:** commit `docs(2b): acceptance smoke and runbook — offline recipe build to synced delete`.

---

## Notes for the executing controller

- **Task order matters twice.** Task 5's scenarios (d)-(g) consume Tasks 1-3's `LocalEdits` methods, and Task 9 consumes Task 7's extracted picker. Everything else is independent.
- **Carry these facts into briefs:** `KernelError` is a struct with `.message` (never switch it); Swift Testing is the framework (`@Test`/`#expect`/`#require`, not XCTest); the store-test idiom is `LocalStore.inMemory()` → `bind` → `applyPullPage`; `LocalStore.insertStub` already has working `recipes`/`recipe_items` branches, so no store plumbing is needed for the new inserts.
- **There is no app unit-test target** (structural, known since 2a). Tasks 6-10 are proved by the build gate plus a recorded manual walk; Task 11 is the executable end-to-end proof. This is exactly why Tasks 1-4 pushed every rule into the Kit.
- **Deferred 2a minors that this plan deliberately does NOT fix:** deterministic multi-org store-file selection, the duplicated `exportOrganizationData`/`signedPercent` helpers, the two-tap §13 export buttons. They stay on their own list unless a task lands in that code.
