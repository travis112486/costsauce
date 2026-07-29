// The CostSauce local dashboard model.
//
// Exact mirror of api/routes/dashboard.py:32-64's movers/alerts/summary
// assembly. `Costing.costRecipes`/`Costing.driftByIngredient` do the
// per-recipe/per-ingredient math; this file only sorts, filters, and
// aggregates their already-computed results -- same division of labor as
// the Python route over `costing.location_drift`/`costing.cost_recipes`.

import Foundation

public struct Mover: Equatable, Sendable {
    public let ingredientId: String
    public let name: String
    public let vendor: String?
    public let category: String?
    public let latestPrice: String
    public let trailingAvg: String
    public let driftPct: String
    public let baselineN: Int
    public let direction: String

    public init(
        ingredientId: String, name: String, vendor: String?, category: String?,
        latestPrice: String, trailingAvg: String, driftPct: String, baselineN: Int,
        direction: String
    ) {
        self.ingredientId = ingredientId
        self.name = name
        self.vendor = vendor
        self.category = category
        self.latestPrice = latestPrice
        self.trailingAvg = trailingAvg
        self.driftPct = driftPct
        self.baselineN = baselineN
        self.direction = direction
    }
}

public struct DashboardSummary: Equatable, Sendable {
    public let totalAlerts: Int
    public let avgFcPct: String?
    public let dangerCount: Int
    public let watchCount: Int
    public let okCount: Int
    public let incompleteCount: Int
    public let driftThresholdPct: String

    public init(
        totalAlerts: Int, avgFcPct: String?, dangerCount: Int, watchCount: Int,
        okCount: Int, incompleteCount: Int, driftThresholdPct: String
    ) {
        self.totalAlerts = totalAlerts
        self.avgFcPct = avgFcPct
        self.dangerCount = dangerCount
        self.watchCount = watchCount
        self.okCount = okCount
        self.incompleteCount = incompleteCount
        self.driftThresholdPct = driftThresholdPct
    }
}

public struct DashboardModel {
    public let alerts: [Mover]
    public let topMovers: [Mover]
    public let menuItems: [CostedRecipe]
    public let summary: DashboardSummary

    public init(alerts: [Mover], topMovers: [Mover], menuItems: [CostedRecipe], summary: DashboardSummary) {
        self.alerts = alerts
        self.topMovers = topMovers
        self.menuItems = menuItems
        self.summary = summary
    }

    /// Exact mirror of api/routes/dashboard.py's `dashboard` handler (the
    /// in-memory assembly half -- SQL fetching is the caller's job, same
    /// split as `Costing`).
    ///
    /// `ingredients` is the UNFILTERED set -- every ingredient at the
    /// location INCLUDING tombstoned ones (`LocalStore.allIngredients()`,
    /// not `liveIngredients()`). Two different consumers inside this
    /// function need two different views of that one set, so it can't be
    /// pre-filtered by the caller: `Costing.costRecipes` needs tombstoned
    /// rows present for LEFT-JOIN name/base_unit parity on a recipe line
    /// whose ingredient was later removed (costing.py:56-62), while the
    /// movers loop below filters to live ingredients ITSELF, matching
    /// dashboard.py:26-27's own `WHERE deleted_at IS NULL` ingredients
    /// query -- a tombstoned ingredient must never appear as a mover/alert
    /// even if its purchase history is still drift-worthy.
    public static func build(
        ingredients: [LocalIngredient], purchases: [LocalPurchase],
        recipes: [LocalRecipe], items: [LocalRecipeItem],
        driftThresholdPct: String
    ) throws -> DashboardModel {
        let drift = Costing.driftByIngredient(purchases: purchases)
        let menuItems = try Costing.costRecipes(
            recipes: recipes, items: items, ingredients: ingredients, drift: drift)

        // "movers from ingredients in (name, id) order, skipping drift-nil
        // or driftPct-nil entries" (dashboard.py:32-41) -- dashboard.py:
        // 26-27's own ingredients query is `WHERE deleted_at IS NULL`, so
        // filter to live ingredients here before ordering/scanning.
        let orderedIngredients = ingredients
            .filter { $0.deleted_at == nil }
            .sorted { a, b in a.name != b.name ? a.name < b.name : a.id < b.id }
        var movers: [Mover] = []
        for ingredient in orderedIngredients {
            guard let d = drift[ingredient.id], let driftPct = d.driftPct else { continue }
            let pct = try Rational.parseDec(driftPct)
            let direction = pct.cmp(Rational(n: 0, d: 1)) > 0 ? "up" : "down"
            // Invariant: `driftPct` is only ever set once the baseline has
            // reached `MIN_BASELINE_N` (3) rows (Drift.swift), which is
            // itself only reachable once the baseline is non-empty -- the
            // same non-empty-baseline condition `trailingAvg` requires. So
            // `driftPct != nil` always implies `trailingAvg != nil` too.
            movers.append(Mover(
                ingredientId: ingredient.id, name: ingredient.name,
                vendor: ingredient.vendor, category: ingredient.category,
                latestPrice: d.latestPrice, trailingAvg: d.trailingAvg!,
                driftPct: driftPct, baselineN: d.baselineN, direction: direction))
        }

        // "sort (-|driftPct|, name, ingredientId) comparing |driftPct| as
        // Rationals" -- descending magnitude, then name/id ties ASC. Every
        // `Mover.driftPct` here was itself produced by `Kernel.drift`'s own
        // `roundHalfAway` output a few lines above, so `try!` (`sort`'s
        // closure isn't throwing) can never actually fail.
        movers.sort { a, b in
            let magA = try! absRational(a.driftPct)
            let magB = try! absRational(b.driftPct)
            let cmp = magA.cmp(magB)
            if cmp != 0 { return cmp > 0 }
            if a.name != b.name { return a.name < b.name }
            return a.ingredientId < b.ingredientId
        }

        let threshold = try Rational.parseDec(driftThresholdPct)
        let alerts = try movers.filter { try absRational($0.driftPct).cmp(threshold) >= 0 }
        let topMovers = Array(movers.prefix(5))

        let completeItems = menuItems.filter { $0.complete }
        var avgFcPct: String?
        if !completeItems.isEmpty {
            var sum = Rational(n: 0, d: 1)
            for item in completeItems {
                // `complete == true` always carries a non-nil `fcPct`
                // (Costing.costRecipes never leaves fc_pct nil for a
                // complete recipe) -- same invariant the server's
                // `Fraction(m["fc_pct"])` relies on unconditionally.
                sum = reduced(sum.add(try Rational.parseDec(item.fcPct!)))
            }
            let avg = reduced(try sum.div(Rational(n: Int128(completeItems.count), d: 1)))
            avgFcPct = Kernel.roundHalfAway(avg, places: 1)
        }

        let summary = DashboardSummary(
            totalAlerts: alerts.count, avgFcPct: avgFcPct,
            dangerCount: completeItems.filter { $0.status == "danger" }.count,
            watchCount: completeItems.filter { $0.status == "watch" }.count,
            okCount: completeItems.filter { $0.status == "ok" }.count,
            incompleteCount: menuItems.filter { !$0.complete }.count,
            driftThresholdPct: driftThresholdPct)

        return DashboardModel(alerts: alerts, topMovers: topMovers, menuItems: menuItems, summary: summary)
    }

    private static func absRational(_ s: String) throws -> Rational {
        let r = try Rational.parseDec(s)
        return r.n < 0 ? Rational(n: -r.n, d: r.d) : r
    }

    // MARK: - GCD reduction (avgFcPct's summation chain)
    //
    // `Rational`'s arithmetic never reduces to lowest terms by design (it
    // mirrors kernel.js's arbitrary-precision BigInt plumbing -- see
    // Rational.swift's doc comment). Summing an unbounded number of
    // recipes' `fc_pct` the way `Drift.swift`'s baseline-average loop
    // originally did would otherwise compound denominators multiplicatively
    // every iteration and overflow `Int128` well within a normal recipe
    // count. `Drift.swift` already hit this exact failure class (Task 4)
    // and fixed it with a private `gcd`/`reduced` pair local to that file;
    // this is the SAME fix, duplicated here rather than shared because
    // Drift.swift's helpers are deliberately file-private. (Note for a
    // future task: this value-preserving reduction step arguably belongs
    // on `Rational` itself, e.g. as a `reduced()` method, so every
    // accumulation site gets it for free instead of re-deriving it --
    // flagged here rather than done, since modifying `Rational.swift` is
    // out of scope for this task.)

    private static func gcd(_ a: Int128, _ b: Int128) -> Int128 {
        var x = a < 0 ? -a : a
        var y = b < 0 ? -b : b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x
    }

    private static func reduced(_ r: Rational) -> Rational {
        let g = gcd(r.n, r.d)
        guard g > 1 else { return r }
        return Rational(n: r.n / g, d: r.d / g)
    }
}
