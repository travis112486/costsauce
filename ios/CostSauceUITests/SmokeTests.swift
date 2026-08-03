// Task 15's real end-to-end acceptance smoke, replacing Task 9's
// placeholder (`app.launch()` only). One journey, driven against a real
// local stack (disposable Postgres + `uv run uvicorn`, per
// docs/runbooks/phase-2a-acceptance.md): launch -> reviewer login ->
// bootstrap auto-picks the seeded single org/location -> Add tab ->
// fuzzy-pick the seeded "Chicken Breast" ingredient -> record a purchase ->
// success indicator shows the computed unit price -> Dashboard reflects a
// priced ingredient -> sync chip reaches "Synced (checkmark)" -> Ingredients
// tab -> detail shows the new history row dated today.
//
// Launch environment: `API_BASE_URL` (points at the local uvicorn from the
// runbook's `xcodebuild test` invocation), `UITEST=1` (AppModel.init wipes
// the Keychain + Application Support store first, per its own doc comment,
// so every run starts from a clean slate -- this suite's own re-runs are
// exactly the repeatability case that guards), and `REVIEWER_EMAIL`/
// `REVIEWER_CODE` -- the reviewer-OTP credentials this file types into the
// login form (the app itself only reads `API_BASE_URL`/`UITEST`; the
// reviewer credentials are consumed here, by the test, not by AppModel).
//
// Fuzzy-match query: the brief's own example query "chkn brst" is this
// codebase's canonical example of a name that does NOT match "Chicken
// Breast" under `Kernel.matchIngredient`/`nearMatches` (bidirectional
// *substring* containment, kernel.js:56-66 / api/kernel.py's port) --
// `tests/test_merge.py` uses that exact pair (a "Chicken Breast" ingredient
// and a separately-created "chkn brst" one) specifically BECAUSE the two
// don't auto-match and therefore need the (web-only, 2a-out-of-scope) merge
// tool. Typing "chkn brst" here would not surface a match at all, exercising
// the "create new" path instead of the fuzzy-pick path this smoke exists to
// prove. This suite instead types "chicken br" -- a genuine substring of
// "chicken breast" once both sides are normalized (lowercased, punctuation
// stripped) -- which surfaces "Chicken Breast" as a `.fuzzy` (not `.exact`,
// since the normalized strings differ) match, auto-selected into the
// `SelectedIngredientChip` exactly as `PurchaseEntryView.effectiveIngredient`
// (matchResult, whether `.exact` or `.fuzzy`, both auto-select -- there is
// no separate "tap to confirm a fuzzy match" affordance in the frozen Task
// 12 UI) already does for any matched candidate.
import XCTest

final class SmokeTests: XCTestCase {
    // Matches docs/runbooks/phase-2a-acceptance.md's local stack exactly:
    // port 8401 (8400 is occupied by an unrelated long-running process on
    // this machine -- see that runbook's own note), and the reviewer
    // identity/credentials the runbook's `uv run uvicorn` invocation sets
    // via REVIEWER_EMAIL/REVIEWER_CODE. Task 11 (2a deferred minor): reads
    // `API_BASE_URL` from the environment, falling back to the same
    // hardcoded default -- so a caller can point this suite at a different
    // stack (e.g. a different port) without editing source, while every
    // existing invocation (nothing sets this env var) behaves identically
    // to before.
    private let apiBaseURL = ProcessInfo.processInfo.environment["API_BASE_URL"] ?? "http://127.0.0.1:8401"
    private let reviewerEmail = "reviewer@example.com"
    private let reviewerCode = "123456"

    /// `Kernel.todayLocalISO(now:)`'s own algorithm (Timestamps.swift),
    /// duplicated here rather than imported: this target doesn't (and
    /// shouldn't) link CostSauceKit -- it drives the compiled app as a
    /// black box over the accessibility tree, the same arm's-length
    /// relationship every other XCUITest target has to its app target.
    private var todayLocalISO: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Reviewer login + bootstrap wait, shared by every test method in this
    /// file (Task 11 factors this out of what was previously inlined once,
    /// so the recipe journey below doesn't duplicate it a second time).
    /// Returns once the tab bar is showing (bootstrap auto-picked the
    /// seeded org/location, Task 7) and the initial pull has landed
    /// (`"Synced ✓"`) -- the same precondition every journey in this file
    /// needs before touching its own tab.
    private func loginAndAwaitBootstrap(_ app: XCUIApplication) {
        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15), "reviewer email field never appeared")
        emailField.tap()
        emailField.typeText(reviewerEmail)

        let codeField = app.textFields["Code"]
        XCTAssertTrue(codeField.exists)
        codeField.tap()
        codeField.typeText(reviewerCode)

        let signInButton = app.buttons["Sign In"]
        XCTAssertTrue(signInButton.isEnabled)
        signInButton.tap()

        let addTab = app.tabBars.buttons["Add"]
        XCTAssertTrue(addTab.waitForExistence(timeout: 20), "tab bar never appeared -- bootstrap did not complete")

        let dashboardSyncedChip = app.buttons["Synced \u{2713}"]
        XCTAssertTrue(dashboardSyncedChip.waitForExistence(timeout: 20), "initial pull never reached Synced state")
    }

    /// The create-path picker's staged-selection "Add" tap, keyed by the
    /// exact button label `RecipeEditorView.addIngredientDestination` renders
    /// (`"Add \(pickedIngredient.name)"`, RecipeEditorView.swift) once a
    /// live fuzzy match stages `pickedIngredient`. This suite used to need a
    /// bespoke `typeIntoPickerUntilItPops` character-at-a-time workaround
    /// here: before the final-review fix, `onPick` fed `addLine` directly,
    /// so a single substring-matching character (`Kernel.matchIngredient`
    /// has no minimum-length floor, Kernel.swift:88) appended the line and
    /// popped the screen mid-keystroke, spraying whatever characters were
    /// sent afterward onto the parent screen's next first responder --
    /// reproduced live twice while writing this suite ("Ground Beef" left a
    /// stray "round Beef" on the Menu price field; "Onion" left a stray "n"
    /// on a Qty field). The fix stages the pick into `pickedIngredient`
    /// instead (mirroring the edit path's own `newLineIngredient`) and
    /// requires this explicit "Add" tap before the line is appended and the
    /// screen pops, so a full `typeText` call is now safe -- no more racing
    /// a mid-keystroke pop -- and this helper replaces the old one.
    private func addStagedIngredient(_ field: XCUIElement, _ name: String, app: XCUIApplication) {
        field.typeText(name)
        let addButton = app.buttons["Add \(name)"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "picker never staged a match for \(name)")
        addButton.tap()
    }

    /// `IngredientDetailView`'s `List` (Header / Price Drift / History
    /// sections + the sparkline chart) is taller than one screen -- iOS
    /// lazily instantiates List/CollectionView cells, so an element below
    /// the fold genuinely does not exist in the accessibility tree yet
    /// (not just "not hittable"). Drags in small (~28% of screen height)
    /// steps on `app` itself, re-checking after each -- a full-screen
    /// `swipeUp()` can jump clean over a single section-header cell (a real
    /// failure seen while iterating this suite against a re-used, already
    /// multi-purchase seed instead of a fresh one) with no way to recover
    /// short of scrolling back down; small steps make overshoot exceedingly
    /// unlikely for a screen this size. Not scoped to a specific
    /// `collectionViews` element either: `NavigationStack` keeps the root
    /// Ingredients list's own `List`/`CollectionView` alive off-screen
    /// underneath the pushed detail view, so `.collectionViews.firstMatch`
    /// can resolve to the wrong, already-fully-visible one; a drag anchored
    /// on `app`'s own coordinates always lands on whatever is front-most.
    @discardableResult
    private func scrollToReveal(_ element: XCUIElement, in app: XCUIApplication, maxSteps: Int = 14) -> Bool {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
        for _ in 0..<maxSteps {
            if element.waitForExistence(timeout: 1) { return true }
            start.press(forDuration: 0.02, thenDragTo: end)
        }
        if !element.waitForExistence(timeout: 2) {
            print("DEBUG DUMP:\n\(app.debugDescription)")
            return false
        }
        return true
    }

    func testReviewerLoginToSyncedPurchase() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "API_BASE_URL": apiBaseURL,
            "UITEST": "1",
            "REVIEWER_EMAIL": reviewerEmail,
            "REVIEWER_CODE": reviewerCode,
        ]
        app.launch()

        // MARK: - Reviewer login + bootstrap
        // /config's supabase_url is null in this stack (no SUPABASE_URL/
        // SUPABASE_ANON_KEY exported -- runbook Sec. 2), so LoginView renders
        // only the reviewer-access "Sign In" section (LoginView.swift:48-54)
        // -- exactly one "Email" field and one "Code" field, no ambiguity
        // with the GoTrue email/OTP section that's absent here. The seed
        // script creates exactly one membership and one location, so
        // `pickDefaultMembership`/`pickDefaultLocation` (Task 7) resolve
        // straight through to `.main` with no picker screens -- the tab bar
        // appearing IS the assertion that both picks happened.
        loginAndAwaitBootstrap(app)

        // MARK: - Add tab: fuzzy-pick the seeded ingredient
        // Let the initial pull land the seeded "Chicken Breast" ingredient
        // before navigating to Add -- PurchaseEntryView's candidate list is
        // read from the local store, refreshed only when `syncState`/
        // `pendingCount` change (its own `RefreshKey`), so waiting for the
        // sync chip's caught-up state (already done inside
        // `loginAndAwaitBootstrap`, rather than racing it) is what
        // guarantees the fuzzy match below has something to find.
        let addTab = app.tabBars.buttons["Add"]
        addTab.tap()

        let nameField = app.textFields["Ingredient name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("chicken br")

        // `SelectedIngredientChip` renders `Text(ingredient.name)` --
        // "Chicken Breast" appearing here is the fuzzy-match auto-pick.
        let selectedChip = app.staticTexts["Chicken Breast"]
        XCTAssertTrue(selectedChip.waitForExistence(timeout: 10), "fuzzy match on \"chicken br\" never surfaced Chicken Breast")

        // unit defaults to "lb" (`unitChoices(for:).first`, since the seed
        // script's ingredient is lb-tracked) -- no Picker interaction needed.
        let qtyField = app.textFields["Quantity"]
        XCTAssertTrue(qtyField.waitForExistence(timeout: 5))
        qtyField.tap()
        qtyField.typeText("2")

        let totalField = app.textFields["Total price"]
        XCTAssertTrue(totalField.exists)
        totalField.tap()
        totalField.typeText("9.00")

        let saveButton = app.buttons["Save Purchase"]
        XCTAssertTrue(saveButton.isEnabled, "Save Purchase stayed disabled -- canSave's guard didn't clear")
        saveButton.tap()

        // MARK: - Success indicator: unit price 4.500000 (9.00 / 2 lb)
        let successPredicate = NSPredicate(format: "label CONTAINS[c] %@", "4.500000")
        let successText = app.staticTexts.containing(successPredicate).firstMatch
        XCTAssertTrue(successText.waitForExistence(timeout: 10), "save succeeded but no \"4.500000\" unit price shown")

        // MARK: - Dashboard reflects a priced ingredient
        // DashboardView's own empty state ("No Ingredients Yet") is gated on
        // `hasLiveIngredients`, computed straight from the local store --
        // the same local write `save()` just made flips it true immediately,
        // no sync required. Its absence, plus the always-rendered "Summary"
        // section heading, is this smoke's assertion that the dashboard
        // picked up the newly priced ingredient.
        let dashboardTab = app.tabBars.buttons["Dashboard"]
        dashboardTab.tap()
        let summaryHeading = app.staticTexts["Summary"]
        XCTAssertTrue(summaryHeading.waitForExistence(timeout: 10), "dashboard never left its empty state")
        XCTAssertFalse(app.staticTexts["No Ingredients Yet"].exists)

        // MARK: - Sync chip reaches "Synced (checkmark)" again
        // The purchase save enqueued one pending op (`syncSoon()`'s debounced
        // `syncNow()`); this waits for that push to land and the chip to
        // report caught-up again.
        let syncedChip = app.buttons["Synced \u{2713}"]
        XCTAssertTrue(syncedChip.waitForExistence(timeout: 20), "sync chip never returned to Synced after the purchase push")

        // MARK: - Ingredients -> detail shows the new history row dated today
        let ingredientsTab = app.tabBars.buttons["Ingredients"]
        ingredientsTab.tap()
        let ingredientRow = app.staticTexts["Chicken Breast"]
        XCTAssertTrue(ingredientRow.waitForExistence(timeout: 10))
        ingredientRow.tap()

        let historyHeading = app.staticTexts["History"]
        XCTAssertTrue(
            scrollToReveal(historyHeading, in: app),
            "History section never scrolled into view")
        let todayRow = app.staticTexts[todayLocalISO]
        XCTAssertTrue(
            scrollToReveal(todayRow, in: app),
            "no history row dated \(todayLocalISO)")
        let unitPriceRow = app.staticTexts.containing(successPredicate).firstMatch
        XCTAssertTrue(unitPriceRow.exists, "history row missing the $4.500000/lb unit price")
    }

    // MARK: - Task 11: recipe build -> edit -> delete, the sync fan-out proof

    /// Phase 2b's own acceptance journey: build a two-line recipe entirely
    /// through the real UI, edit one line's quantity, then delete the
    /// recipe -- proving the sync protocol's delete FAN-OUT end to end. A
    /// recipe tombstone does NOT cascade to its lines server-side the way
    /// the REST route does (`LocalEdits.tombstoneRecipe`'s own doc comment,
    /// LocalEdits.swift:289-299) -- skipping the fan-out would strand live
    /// `recipe_items` rows pointing at a dead recipe, which is exactly what
    /// this journey's final SQL assertion (recorded in
    /// docs/runbooks/phase-2b-acceptance.md) rules out.
    ///
    /// Seeded ingredients (`scratch/seed_2b.py`) are ALREADY priced via a
    /// direct `make_purchase` factory call, not through the Add tab --
    /// "Ground Beef" ($5.00/lb) and "Onion" ($1.00/lb), distinct from
    /// `testReviewerLoginToSyncedPurchase`'s own "Chicken Breast" (left
    /// unpriced there on purpose, since THAT test creates its own
    /// purchase). The two tests never touch the same ingredient or recipe,
    /// so they run correctly regardless of which order `xcodebuild test`
    /// picks between them in the same invocation.
    ///
    /// Deliberate `Thread.sleep` pauses after the create-sync and
    /// edit-sync checkpoints below: `Process`/`NSTask` is unavailable on
    /// the iOS SDK (even for a Simulator-hosted UI test runner), so this
    /// file cannot shell out to `psql` itself. The runbook's own SQL
    /// assertions -- which must observe "2 LIVE recipe_items rows" and
    /// "the row's qty CHANGED, no duplicate" as real, still-live states,
    /// not reconstructed after the recipe is later tombstoned -- run from
    /// OUTSIDE this process, against the exact same server this test just
    /// synced to, during these windows. Each pause is announced with a
    /// `print()` (visible in `xcodebuild test`'s own streamed output) so
    /// the acceptance run knows exactly when to fire its query.
    func testRecipeCreateEditDeleteReconciles() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "API_BASE_URL": apiBaseURL,
            "UITEST": "1",
            "REVIEWER_EMAIL": reviewerEmail,
            "REVIEWER_CODE": reviewerCode,
        ]
        app.launch()
        loginAndAwaitBootstrap(app)

        // MARK: - Create: "Acceptance Bowl" -- Ground Beef x1 lb + Onion x2 lb
        // `MenuSection`'s "+" (DashboardView.swift:273-280) is hidden for a
        // bookkeeper; the reviewer seed is an owner, so it's present.
        let addRecipeButton = app.buttons["Add Recipe"]
        XCTAssertTrue(addRecipeButton.waitForExistence(timeout: 10), "Menu section's + never appeared")
        addRecipeButton.tap()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("Acceptance Bowl")

        let menuPriceField = app.textFields["Menu price"]
        XCTAssertTrue(menuPriceField.exists)
        menuPriceField.tap()
        menuPriceField.typeText("20.00")
        // Target food cost % keeps `RecipeDraft`'s own "30.00" default --
        // never touched, exactly like `PurchaseEntryView`'s unit Picker
        // needing no interaction when there's only one sensible default.

        let addIngredientButton = app.buttons["Add ingredient"]
        XCTAssertTrue(addIngredientButton.exists)
        addIngredientButton.tap()

        var ingredientNameField = app.textFields["Ingredient name"]
        XCTAssertTrue(ingredientNameField.waitForExistence(timeout: 10))
        ingredientNameField.tap()
        addStagedIngredient(ingredientNameField, "Ground Beef", app: app)
        // The pushed Form is a `List` under the hood -- once the keyboard
        // comes up for the newly-added line's own Qty field, the list can
        // auto-scroll enough that "Name" (several rows above) is no longer
        // instantiated in the accessibility tree at all (the exact same
        // lazy-List gap `scrollToReveal`'s own doc comment describes for
        // `IngredientDetailView`), so checking for IT is unreliable here.
        // The line's own ingredient name text is what's actually visible
        // right after a pick, and is the more meaningful assertion anyway
        // -- it proves the RIGHT ingredient landed, not just "some screen
        // popped".
        XCTAssertTrue(app.staticTexts["Ground Beef"].waitForExistence(timeout: 10), "picking Ground Beef never returned to the recipe form")

        let firstQtyField = app.textFields["Qty"]
        XCTAssertTrue(firstQtyField.waitForExistence(timeout: 5), "Ground Beef line never appeared")
        firstQtyField.tap()
        firstQtyField.typeText("1")

        addIngredientButton.tap()
        ingredientNameField = app.textFields["Ingredient name"]
        XCTAssertTrue(ingredientNameField.waitForExistence(timeout: 10))
        ingredientNameField.tap()
        addStagedIngredient(ingredientNameField, "Onion", app: app)
        XCTAssertTrue(app.staticTexts["Onion"].waitForExistence(timeout: 10), "picking Onion never returned to the recipe form")

        // Two lines now share the "Qty" label -- `boundBy: 1` is the
        // SECOND row, appended after Ground Beef's, matching
        // `draft.lines`' own insertion order (LineRow's `ForEach` iterates
        // `draft.lines` directly, RecipeEditorView.swift:216).
        let secondQtyField = app.textFields.matching(identifier: "Qty").element(boundBy: 1)
        XCTAssertTrue(secondQtyField.waitForExistence(timeout: 5), "Onion line never appeared")
        secondQtyField.tap()
        secondQtyField.typeText("2")

        // MARK: - Preview: Ground Beef 1 lb * $5.00 + Onion 2 lb * $1.00 = $7.00
        let plateCostPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Plate $7.00")
        let editorPlateCost = app.staticTexts.containing(plateCostPredicate).firstMatch
        XCTAssertTrue(editorPlateCost.waitForExistence(timeout: 5), "editor preview never showed Plate $7.00")

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.isEnabled, "Save stayed disabled -- canEditRecipes gate or validation didn't clear")
        saveButton.tap()

        // MARK: - Dashboard: the new recipe shows the SAME plate cost
        // `save()` calls `dismiss()` synchronously (RecipeEditorView.swift:456)
        // after the local write, popping straight back to the Dashboard
        // tab's root -- no extra tab tap needed.
        XCTAssertTrue(app.staticTexts["Acceptance Bowl"].waitForExistence(timeout: 10), "Dashboard menu never listed the new recipe")
        let dashboardPlateCost = app.staticTexts.containing(plateCostPredicate).firstMatch
        XCTAssertTrue(dashboardPlateCost.waitForExistence(timeout: 5), "Dashboard menu row never showed Plate $7.00")

        // MARK: - Sync: 3 ops pushed (1 recipe insert + 2 recipe_items inserts)
        let syncedAfterCreate = app.buttons["Synced \u{2713}"]
        XCTAssertTrue(syncedAfterCreate.waitForExistence(timeout: 20), "sync chip never returned to Synced after the recipe create")

        print("CHECKPOINT 1 (create+sync complete): pausing 10s -- docs/runbooks/phase-2b-acceptance.md's SQL asserts 1 recipes row + 2 LIVE recipe_items rows here, before the edit below changes anything")
        Thread.sleep(forTimeInterval: 10)

        // MARK: - Edit: Onion's quantity "2.0000" -> "2.0005" (backspace one digit, retype)
        // Task 9's own report: three separate clear-then-retype techniques
        // on this exact right-aligned Qty field proved unreliable in this
        // simulator/iOS build, so this edit avoids a full clear too -- but
        // TWO append-only attempts while writing this test both failed to
        // produce a SERVER-observable change, for two different reasons,
        // both confirmed live (not theorized) via the SQL in
        // docs/runbooks/phase-2b-acceptance.md:
        //   1. Appending ".5" onto the pre-filled "2.0000" (the field
        //      loads the SERVER-canonical value, the pull half of
        //      checkpoint 1's sync already echoed it back -- not the "2"
        //      this suite originally typed) produces the invalid
        //      two-decimal-point string "2.0000.5", which
        //      `Rational.parseDec` correctly rejects, leaving the stored
        //      value silently unchanged.
        //   2. Appending a single valid trailing digit ("2.0000" + "1" =
        //      "2.00001") parses fine and DOES commit and push -- but lands
        //      in the column's 5th decimal place, and `recipe_items
        //      .qty_base_units` is `numeric(14,4)` (0012_business_tables
        //      .sql:77): the server rounds it straight back down to
        //      "2.0000" on write, indistinguishable from a no-op. This is
        //      the EXACT pitfall Task 9's own report already flagged for
        //      its own "111"-appended qty edit ("an artifact of this
        //      walk's own arbitrarily-chosen test value, not a bug") --
        //      that task only needed the CLIENT op count, not a
        //      server-observable value, so it could shrug the rounding off;
        //      this task's brief explicitly needs the server row itself to
        //      read as changed, so the same shortcut does not work here.
        // The fix: delete the trailing digit (one backspace, landing on the
        // 4th decimal place, not a 5th) before typing its replacement --
        // still never a full clear, and the result stays within the
        // column's own precision.
        app.staticTexts["Acceptance Bowl"].tap()
        // Which "Qty" field is Onion's is NOT `boundBy: 1` reliably here.
        // `editLinesSection`'s `ForEach(lines, ...)` is fed by
        // `LocalStore.liveRecipeItems(recipeId:)`, which USED to be a plain
        // `ORDER BY id`; since `UUIDv7.generate` mixes in CSPRNG-random
        // bits for same-millisecond ties (UUIDv7.swift:19-23, no monotonic
        // counter) and `saveNewRecipe` mints both lines' row ids from the
        // SAME `now`, which of Ground Beef's/Onion's ids sorted first was
        // effectively a coin flip per run (reproduced live: an earlier
        // full-suite run silently edited the wrong row this way, and the
        // SQL after it showed Onion's qty unchanged). That read now orders
        // by INGREDIENT NAME, mirroring the server (`ORDER BY i.name,
        // ri.id`), so "Ground Beef" then "Onion" is in fact deterministic
        // today -- but locating by the row's own visible ingredient name
        // rather than by position stays correct under either ordering, and
        // asserts the thing this walk actually cares about, so it stands.
        let onionLabel = app.staticTexts["Onion"]
        XCTAssertTrue(scrollToReveal(onionLabel, in: app), "Onion's line never scrolled into view on the edit screen")
        let onionRowY = onionLabel.frame.midY
        let onionQtyField = app.textFields.matching(identifier: "Qty").allElementsBoundByIndex
            .min { abs($0.frame.midY - onionRowY) < abs($1.frame.midY - onionRowY) }
        guard let onionQtyField else {
            XCTFail("no Qty field found on Onion's row")
            return
        }
        onionQtyField.tap()
        onionQtyField.typeText("\u{8}5")

        // `commitQty`'s own 500ms debounce (RecipeEditorView.swift:747-754)
        // runs independently of this view's lifecycle -- wait it out HERE,
        // still on the edit screen, before navigating away, so the local
        // write and `syncSoon()` call are unambiguously already in flight.
        Thread.sleep(forTimeInterval: 1.2)

        // The sync chip only lives in each tab's own root toolbar, not on a
        // screen pushed on top of it (Task 9's own finding) -- pop back to
        // it via the navigation bar's own back button (its accessibility
        // label mirrors the PREVIOUS screen's title, "Dashboard", since
        // this editor was pushed directly off the Dashboard tab's root).
        // The decimal-pad keyboard is still up from the qty edit and
        // covers the tab bar at the bottom of the screen entirely
        // (reproduced live: tapping `app.tabBars.buttons["Dashboard"]`
        // while the keyboard was showing computed an off-screen {-1, -1}
        // hit point and silently failed to navigate) -- the nav bar back
        // button sits at the TOP, never covered by the keyboard.
        app.navigationBars.buttons["Dashboard"].tap()
        XCTAssertTrue(app.staticTexts["Acceptance Bowl"].waitForExistence(timeout: 10), "never returned to the Dashboard menu after the qty edit")

        let syncedAfterEdit = app.buttons["Synced \u{2713}"]
        XCTAssertTrue(syncedAfterEdit.waitForExistence(timeout: 20), "sync chip never returned to Synced after the quantity edit")

        print("CHECKPOINT 2 (edit+sync complete): pausing 10s -- docs/runbooks/phase-2b-acceptance.md's SQL asserts Onion's changed qty_base_units and no duplicate line here, before the delete below tombstones both lines")
        Thread.sleep(forTimeInterval: 10)

        // MARK: - Delete: tombstones the recipe AND both lines (the fan-out proof)
        app.staticTexts["Acceptance Bowl"].tap()
        let deleteRecipeButton = app.buttons["Delete Recipe"]
        // Below the fold on this two-line recipe's Form (the same lazy-List
        // gap as the "Name" field earlier) -- `scrollToReveal` (this file's
        // own helper) drags in small steps rather than a single swipe that
        // could jump clean over it.
        XCTAssertTrue(scrollToReveal(deleteRecipeButton, in: app), "Delete Recipe button never scrolled into view")
        deleteRecipeButton.tap()

        let confirmDeleteButton = app.buttons["Delete"]
        XCTAssertTrue(confirmDeleteButton.waitForExistence(timeout: 5), "delete confirmation dialog never appeared")
        confirmDeleteButton.tap()

        // `deleteRecipe()` calls `dismiss()` synchronously right after
        // `tombstoneRecipe` (RecipeEditorView.swift:849-861) -- straight
        // back to the Dashboard root, same as Save above.
        XCTAssertTrue(
            app.staticTexts["No recipes yet. Tap + to build your first one."].waitForExistence(timeout: 10),
            "Acceptance Bowl still listed (or menu section didn't fall back to its empty state) after delete")

        let syncedAfterDelete = app.buttons["Synced \u{2713}"]
        XCTAssertTrue(syncedAfterDelete.waitForExistence(timeout: 20), "sync chip never returned to Synced after the recipe delete")

        print("CHECKPOINT 3 (delete+sync complete): docs/runbooks/phase-2b-acceptance.md's final SQL asserts the recipe AND both lines are tombstoned server-side -- no fixed pause needed, this state is stable for the rest of the run")
    }

    // MARK: - Phase 3a: capture -> upload -> photo-assisted purchase

    /// Capture -> upload -> photo-assisted purchase -> synced, against a
    /// real local stack (plus the runbook's storage stub for the signed
    /// PUT). Runs headless because Task 6's `ScannedPageSource` seam feeds
    /// a fixture page where the scanner's output would land -- the
    /// simulator has no camera, so without that seam this test could not
    /// exist at all. The real `VNDocumentCameraViewController` path is
    /// therefore NEVER exercised by automation; the runbook's coverage-gap
    /// section owns that manual pass.
    func testInvoiceCaptureUploadAndPhotoAssistedPurchase() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "API_BASE_URL": apiBaseURL,
            "UITEST": "1",
            "REVIEWER_EMAIL": reviewerEmail,
            "REVIEWER_CODE": reviewerCode,
        ]
        app.launch()
        loginAndAwaitBootstrap(app)

        // MARK: - Invoices tab -> capture a fixture page
        let invoicesTab = app.tabBars.buttons["Invoices"]
        XCTAssertTrue(invoicesTab.waitForExistence(timeout: 10), "Invoices tab never appeared")
        invoicesTab.tap()

        let captureButton = app.buttons["Capture Invoice"]
        XCTAssertTrue(captureButton.waitForExistence(timeout: 10), "capture entry point never appeared")
        captureButton.tap()

        let scanButton = app.buttons["Scan Invoice"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 10), "capture screen never appeared")
        scanButton.tap()

        // The fixture page passes both quality gates, so it is accepted
        // without a retake prompt and the invoice is minted.
        XCTAssertTrue(
            app.staticTexts["1 page"].waitForExistence(timeout: 10),
            "the captured page never landed on an invoice")

        // Done pops to the list root -- the sync chip only lives in each
        // tab's own root toolbar (2b's finding).
        app.buttons["Done"].tap()

        let syncedChip = app.buttons["Synced \u{2713}"]
        XCTAssertTrue(
            syncedChip.waitForExistence(timeout: 30),
            "sync chip never reached Synced -- the invoice/page ops did not push")

        // The chip's "Synced ✓" is `syncState` alone -- it says nothing
        // about the upload outbox (the first acceptance run passed the chip
        // wait while the PUT was failing). The row's own indicator is the
        // §9-visible signal that flips only when the bytes landed AND the
        // confirm endpoint recorded them, so THIS is the upload assertion.
        XCTAssertTrue(
            app.images["Uploaded"].waitForExistence(timeout: 30),
            "the page never reached the uploaded state -- the PUT or the confirm did not complete")

        // MARK: - photo-assisted purchase against the visible page
        let invoiceRow = app.staticTexts["1 page"]
        XCTAssertTrue(invoiceRow.waitForExistence(timeout: 10), "the invoice list never showed the captured invoice")
        invoiceRow.tap()

        let addFromPage = app.buttons["Add purchase from this page"]
        XCTAssertTrue(addFromPage.waitForExistence(timeout: 10), "the page view never offered photo-assisted entry")
        addFromPage.tap()

        let nameField = app.textFields["Ingredient name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("chicken br")

        // Same fuzzy-pick as the Add tab: the chip appearing IS the pick.
        let selectedChip = app.staticTexts["Chicken Breast"]
        XCTAssertTrue(selectedChip.waitForExistence(timeout: 10), "fuzzy match never surfaced Chicken Breast")

        let qtyField = app.textFields["Quantity"]
        XCTAssertTrue(qtyField.waitForExistence(timeout: 5))
        qtyField.tap()
        qtyField.typeText("10")

        let totalField = app.textFields["Total price"]
        XCTAssertTrue(totalField.exists)
        totalField.tap()
        totalField.typeText("32.00")

        let saveButton = app.buttons["Save Purchase"]
        XCTAssertTrue(saveButton.isEnabled, "Save Purchase stayed disabled")
        saveButton.tap()

        // Success banner: 32.00 / 10 lb = $3.200000/lb.
        let successPredicate = NSPredicate(format: "label CONTAINS[c] %@", "3.200000")
        XCTAssertTrue(
            app.staticTexts.containing(successPredicate).firstMatch.waitForExistence(timeout: 10),
            "save succeeded but no 3.200000 unit price shown")

        // Pop back to the Invoices root for the chip -- nav-bar back
        // buttons mirror the PREVIOUS screen's title and sit at the top,
        // never covered by the decimal keyboard (2b's finding).
        app.navigationBars.buttons["Invoice"].tap()
        app.navigationBars.buttons["Invoices"].tap()
        XCTAssertTrue(
            syncedChip.waitForExistence(timeout: 30),
            "sync chip never returned to Synced after the photo-assisted purchase")

        print("CHECKPOINT 1 (capture+purchase synced): the runbook's SQL asserts one invoices row, one invoice_pages row with a non-null sha256, and a purchase whose invoice_page_id matches that page")
    }

    /// The negative case for the create path's staged pick -- the coverage
    /// gap the final review named, and a direct regression test for the bug
    /// `addStagedIngredient`'s doc comment describes.
    ///
    /// `Kernel.matchIngredient` has NO minimum-length floor (Kernel.swift:88
    /// -- it returns the first candidate whose normalized name contains the
    /// normalized query, or vice versa), so a single character is a real
    /// live match. Before the fix, `IngredientPickerView`'s `onPick` fed
    /// `addLine` directly, so that one character appended a line and popped
    /// this screen mid-keystroke. Now `onPick` only STAGES into
    /// `pickedIngredient`; nothing commits until the explicit "Add" tap.
    ///
    /// Three assertions, and all three matter:
    ///  1. the staged "Add ..." button DOES appear -- the positive control.
    ///     Without it this test would still pass if matching were broken
    ///     outright and the one character simply matched nothing, which is
    ///     not the property under test.
    ///  2. the screen did NOT pop (its own navigation bar is still up).
    ///  3. nothing was committed -- no line row, hence no "Qty" field,
    ///     which only exists back on the recipe form.
    ///
    /// "n" is the character: it is a substring of every ingredient the
    /// reviewer seed carries that this suite already relies on ("Chicken
    /// Breast", "Ground Beef", "Onion"), so SOMETHING always stages. Which
    /// one stages is candidate-order-dependent and deliberately not
    /// asserted -- the property under test is "did not commit or pop", not
    /// "picked a particular row".
    func testSingleCharacterPickDoesNotCommitOrPopThePicker() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "API_BASE_URL": apiBaseURL,
            "UITEST": "1",
            "REVIEWER_EMAIL": reviewerEmail,
            "REVIEWER_CODE": reviewerCode,
        ]
        app.launch()
        loginAndAwaitBootstrap(app)

        let addRecipeButton = app.buttons["Add Recipe"]
        XCTAssertTrue(addRecipeButton.waitForExistence(timeout: 10), "Menu section's + never appeared")
        addRecipeButton.tap()

        let addIngredientButton = app.buttons["Add ingredient"]
        XCTAssertTrue(addIngredientButton.waitForExistence(timeout: 10), "recipe form never appeared")
        addIngredientButton.tap()

        let ingredientNameField = app.textFields["Ingredient name"]
        XCTAssertTrue(ingredientNameField.waitForExistence(timeout: 10), "picker never appeared")
        ingredientNameField.tap()
        ingredientNameField.typeText("n")

        // Settle first, asserting nothing: the match is staged
        // asynchronously, and under the REGRESSION the pop is animated
        // rather than instant -- checking either property the microsecond
        // after `typeText` could read a state that has not happened yet and
        // pass for the wrong reason. Whichever way this run goes, the app is
        // quiescent once the staged button exists (fixed) or the wait times
        // out (regressed, having popped instead). The result is deliberately
        // discarded here; assertion 3 below is what judges it.
        let stagedAddButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Add ", "Add ingredient")
        ).firstMatch
        _ = stagedAddButton.waitForExistence(timeout: 10)

        // 1. Nothing committed: a "Qty" field exists only on a line row
        //    back on the recipe form, which is only reachable by popping.
        XCTAssertFalse(
            app.textFields["Qty"].exists,
            "one character appended a line -- onPick is committing again instead of staging")

        // 2. Still on the picker: staging must not navigate.
        XCTAssertTrue(
            app.navigationBars["Add Ingredient"].exists,
            "one character popped the picker -- onPick is committing again instead of staging")

        // 3. Positive control, asserted LAST so that a genuine regression
        //    reports itself as one above rather than as this. One character
        //    really did produce a live match, so 1 and 2 are not vacuously
        //    true. Matches the `"Add \(pickedIngredient.name)"` label
        //    `RecipeEditorView.addIngredientDestination` renders, without
        //    pinning WHICH candidate won.
        XCTAssertTrue(
            stagedAddButton.exists,
            "one character staged no match at all -- the two assertions above would be vacuous")
    }
}
