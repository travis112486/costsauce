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
    // via REVIEWER_EMAIL/REVIEWER_CODE.
    private let apiBaseURL = "http://127.0.0.1:8401"
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

        // MARK: - Reviewer login
        // /config's supabase_url is null in this stack (no SUPABASE_URL/
        // SUPABASE_ANON_KEY exported -- runbook Sec. 2), so LoginView renders
        // only the reviewer-access "Sign In" section (LoginView.swift:48-54)
        // -- exactly one "Email" field and one "Code" field, no ambiguity
        // with the GoTrue email/OTP section that's absent here.
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

        // MARK: - Bootstrap auto-picks the seeded org/location
        // The seed script creates exactly one membership and one location,
        // so `pickDefaultMembership`/`pickDefaultLocation` (Task 7) resolve
        // straight through to `.main` with no picker screens -- the tab bar
        // appearing IS the assertion that both picks happened.
        let addTab = app.tabBars.buttons["Add"]
        XCTAssertTrue(addTab.waitForExistence(timeout: 20), "tab bar never appeared -- bootstrap did not complete")

        // Let the initial pull land the seeded "Chicken Breast" ingredient
        // before navigating to Add -- PurchaseEntryView's candidate list is
        // read from the local store, refreshed only when `syncState`/
        // `pendingCount` change (its own `RefreshKey`), so waiting for the
        // sync chip's caught-up state here (rather than racing it) is what
        // guarantees the fuzzy match below has something to find.
        let dashboardSyncedChip = app.buttons["Synced \u{2713}"]
        XCTAssertTrue(dashboardSyncedChip.waitForExistence(timeout: 20), "initial pull never reached Synced state")

        // MARK: - Add tab: fuzzy-pick the seeded ingredient
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
}
