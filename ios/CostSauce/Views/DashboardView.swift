// The CostSauce dashboard — local drift alerts, top movers, the costed
// menu, and a summary strip. All four sections are pure renderings of
// `DashboardModel.build`'s output (Task 6's already-tested math); this
// file's only job is turning those already-computed strings into SwiftUI
// (Global Constraints: money/pct values are rendered VERBATIM, never
// routed through Double/Float/Decimal — the one exception, called out
// where it happens below, is the top-movers bar's pixel WIDTH, which the
// brief explicitly allows Double for since it never touches a rendered
// value).
//
// `DashboardModel.build` wants the UNFILTERED ingredient set
// (`LocalStore.allIngredients()`, tombstones included) — it does its own
// live-filtering internally for movers/alerts while still needing the
// tombstoned rows for a recipe line's name/base_unit (see that file's doc
// comment). Do not pre-filter here.

import SwiftUI
import CostSauceKit

struct DashboardView: View {
    let appModel: AppModel

    @State private var dashboard: DashboardModel?
    @State private var hasLiveIngredients = false
    @State private var loadError: String?

    var body: some View {
        content
            .task(id: RefreshKey(appModel: appModel)) {
                load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Couldn't Load Dashboard", systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if appModel.currentLocation == nil {
            // Locations don't sync through the pull loop (§5.5) — the
            // drift threshold this whole build depends on only ever comes
            // from an explicit `/locations` fetch (`AppModel.currentLocation`,
            // populated at bind time and refreshed on every
            // `refreshOnlineData()` call). A fresh launch that took the
            // already-bound-device fast path (`AppModel.tryFastPathToMain`)
            // seeds `currentLocation` from a persisted snapshot of the last
            // successful fetch instead of waiting on a new one, so this
            // branch is only reachable offline on a device that has never
            // once landed that fetch (e.g. it bound before that snapshot
            // existed). Once a fetch does land, `currentLocation` flips
            // non-nil (and saves a fresh snapshot) and `RefreshKey` below
            // reruns `load()`. Any time after that first landing, this
            // branch is never hit again even offline: `currentLocation`
            // keeps whatever it last successfully fetched, restored from
            // that snapshot across a relaunch.
            ProgressView("Loading your location…")
        } else if dashboard == nil {
            ProgressView()
        } else if !hasLiveIngredients {
            ContentUnavailableView(
                "No Ingredients Yet", systemImage: "carrot",
                description: Text("Add your first ingredient from the Add tab to start tracking prices."))
        } else if let dashboard {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AlertsSection(alerts: dashboard.alerts)
                    TopMoversSection(movers: dashboard.topMovers)
                    MenuSection(items: dashboard.menuItems, suppressSuggestions: appModel.suppressSuggestions)
                    SummarySection(summary: dashboard.summary)
                }
                .padding()
            }
        }
    }

    /// Rebuilds from `LocalStore` reads via `DashboardModel.build`.
    /// Synchronous on purpose: `LocalStore`'s reads are plain blocking GRDB
    /// calls, same as every other store call site in the app target
    /// (`AppModel.refreshPendingCount`, etc.) — there's no async DB layer
    /// to await here.
    private func load() {
        guard let store = appModel.store, let currentLocation = appModel.currentLocation else {
            dashboard = nil
            hasLiveIngredients = false
            loadError = nil
            return
        }
        do {
            let ingredients = try store.allIngredients()
            let purchases = try store.allLivePurchases()
            let recipes = try store.liveRecipes()
            let items = try store.liveRecipeItems()
            hasLiveIngredients = ingredients.contains { $0.deleted_at == nil }
            dashboard = try DashboardModel.build(
                ingredients: ingredients, purchases: purchases,
                recipes: recipes, items: items,
                // Locations don't sync — this is the cached value from the
                // last successful `locations()` fetch, not a locally-edited
                // or pulled row (see the `currentLocation == nil` branch
                // above for what happens before that fetch has ever
                // landed).
                driftThresholdPct: currentLocation.driftThresholdPct)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// What `.task(id:)` reruns `load()` on. `pendingCount` bumps synchronously
/// on every local write (`LocalStore.enqueue`'s "a read right after always
/// sees the edit" contract, surfaced through `AppModel.syncSoon`'s
/// `refreshPendingCount` call) — the same signal the sync chip/Settings
/// badge already key off of — so an offline-created ingredient/purchase/
/// recipe shows up here immediately, no new `AppModel` plumbing needed.
/// `syncState` and `currentLocation` catch the other two ways the
/// underlying data can change: a pull applying server rows, and a fresh
/// `/locations` fetch changing the drift threshold.
private struct RefreshKey: Equatable {
    let syncState: SyncState
    let pendingCount: Int
    let locationId: String?
    let driftThresholdPct: String?

    @MainActor
    init(appModel: AppModel) {
        syncState = appModel.syncState
        pendingCount = appModel.pendingCount
        locationId = appModel.currentLocation?.id
        driftThresholdPct = appModel.currentLocation?.driftThresholdPct
    }
}

// MARK: - Alerts

private struct AlertsSection: View {
    let alerts: [Mover]

    var body: some View {
        SectionCard(title: "Alerts") {
            if alerts.isEmpty {
                Text("No price alerts right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(alerts, id: \.ingredientId) { mover in
                        AlertRow(mover: mover)
                    }
                }
            }
        }
    }
}

private struct AlertRow: View {
    let mover: Mover

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(mover.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(signedPercent(mover.driftPct))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(mover.direction == "up" ? .red : .green)
            }
            Text("Latest $\(mover.latestPrice) vs trailing $\(mover.trailingAvg)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Top movers

private struct TopMoversSection: View {
    let movers: [Mover]

    var body: some View {
        SectionCard(title: "Top Movers") {
            if movers.isEmpty {
                Text("Not enough purchase history yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(movers, id: \.ingredientId) { mover in
                        MoverBarRow(mover: mover, maxMagnitude: maxMagnitude)
                    }
                }
            }
        }
    }

    /// Bar-width scaling only — pixels, never a rendered value. `driftPct`
    /// itself is never parsed for anything ELSE in this file; this one
    /// `Double` conversion only feeds a `GeometryReader` width fraction
    /// below, exactly the carve-out the brief calls out ("bar width math
    /// may use Double — pixels only, never values").
    private var maxMagnitude: Double {
        movers.map { abs(Double($0.driftPct) ?? 0) }.max() ?? 0
    }
}

private struct MoverBarRow: View {
    let mover: Mover
    let maxMagnitude: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(mover.name)
                    .font(.subheadline)
                Spacer()
                Text(signedPercent(mover.driftPct))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mover.direction == "up" ? .red : .green)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule()
                        .fill(mover.direction == "up" ? Color.red.opacity(0.55) : Color.green.opacity(0.55))
                        .frame(width: geometry.size.width * barFraction)
                }
            }
            .frame(height: 6)
        }
    }

    private var barFraction: Double {
        guard maxMagnitude > 0 else { return 0 }
        let magnitude = abs(Double(mover.driftPct) ?? 0)
        return min(magnitude / maxMagnitude, 1)
    }
}

// MARK: - Menu

private struct MenuSection: View {
    let items: [CostedRecipe]
    let suppressSuggestions: Bool

    var body: some View {
        SectionCard(title: "Menu") {
            if items.isEmpty {
                Text("Recipes are created on the web app; they cost themselves here automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items, id: \.recipeId) { item in
                        MenuRow(item: item, suppressSuggestions: suppressSuggestions)
                    }
                }
            }
        }
    }
}

private struct MenuRow: View {
    let item: CostedRecipe
    let suppressSuggestions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                // `item.status` is nil exactly when `!item.complete`
                // (Costing.costRecipes only ever sets it inside its
                // `if complete { ... }` block) — no separate `complete`
                // check needed to land on "incomplete".
                StatusChip(status: item.status ?? "incomplete")
            }
            HStack(spacing: 12) {
                Text("Plate $\(item.plateCost)")
                Text("FC \(fcPctText)")
                Text("Sugg. \(suggestedPriceText)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var fcPctText: String {
        guard let fcPct = item.fcPct else { return "—" }
        return "\(fcPct)%"
    }

    /// §5.5 + §10.1: never a reprice from partial data, never NaN.
    /// - incomplete → "—" (no suggestion possible at all, regardless of
    ///   sync state).
    /// - complete but sync hasn't caught up yet (`suppressSuggestions`) →
    ///   "syncing…" (the number exists locally but isn't trusted yet).
    /// - complete and caught up → the real suggested price.
    private var suggestedPriceText: String {
        guard item.complete else { return "—" }
        guard !suppressSuggestions else { return "syncing…" }
        return "$\(item.suggestedPrice ?? "—")"
    }
}

private struct StatusChip: View {
    let status: String

    var body: some View {
        Text(status.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case "ok": return .green
        case "watch": return .orange
        case "danger": return .red
        default: return .gray
        }
    }
}

// MARK: - Summary

private struct SummarySection: View {
    let summary: DashboardSummary

    var body: some View {
        SectionCard(title: "Summary") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    StatTile(label: "Avg FC", value: avgFcText)
                    StatTile(label: "OK", value: "\(summary.okCount)")
                    StatTile(label: "Watch", value: "\(summary.watchCount)")
                    StatTile(label: "Danger", value: "\(summary.dangerCount)")
                    StatTile(label: "Incomplete", value: "\(summary.incompleteCount)")
                    StatTile(label: "Alerts", value: "\(summary.totalAlerts)")
                }
            }
        }
    }

    private var avgFcText: String {
        guard let avg = summary.avgFcPct else { return "—" }
        return "\(avg)%"
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
        .padding(.vertical, 6)
    }
}

// MARK: - shared

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// `driftPct + "%"`, with a leading "+" prepended for a positive value.
/// String-only — no `Double`/`Decimal` parse of the VALUE (Global
/// Constraints). `driftPct` already carries its own "-" for a negative
/// value and never carries a "+" of its own (`Kernel.roundHalfAway`, the
/// only thing that ever produces this string, doesn't emit one), so
/// "positive" here just means "not negative and not all-zero digits".
private func signedPercent(_ driftPct: String) -> String {
    let isNegative = driftPct.hasPrefix("-")
    let isZero = driftPct.allSatisfy { $0 == "0" || $0 == "." }
    let sign = (!isNegative && !isZero) ? "+" : ""
    return "\(sign)\(driftPct)%"
}
