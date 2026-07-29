// The CostSauce Ingredient detail screen — header, the drift block (Task 6's
// `Costing.driftByIngredient`/`Kernel.drift`, same math `DashboardView`'s
// movers already render), and purchase history with a sparkline.
//
// Global Constraints: money/pct/qty values are STRINGS, rendered verbatim
// ("—" for nil) -- never routed through Double/Float/Decimal. The one
// carve-out, same as `DashboardView`'s top-movers bar, is the sparkline's
// plot-coordinate `Double(_:)` conversion below: it only ever feeds a
// `Chart` mark's pixel position, never a rendered label.

import SwiftUI
import Charts
import CostSauceKit

struct IngredientDetailView: View {
    let appModel: AppModel
    let ingredientId: String

    @State private var ingredient: LocalIngredient?
    @State private var purchases: [LocalPurchase] = []
    @State private var drift: DriftResult?
    @State private var loadError: String?

    var body: some View {
        content
            .navigationTitle(ingredient?.name ?? "Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: RefreshKey(appModel: appModel, ingredientId: ingredientId)) {
                load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Couldn't Load Ingredient", systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if let ingredient {
            detailList(ingredient)
        } else {
            ProgressView()
        }
    }

    private func detailList(_ ingredient: LocalIngredient) -> some View {
        List {
            Section {
                HeaderSection(ingredient: ingredient)
            }
            if let drift {
                Section("Price Drift") {
                    DriftSection(drift: drift)
                }
            }
            Section("History") {
                if purchases.isEmpty {
                    Text("No purchases recorded yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // `purchases` is `livePurchases`' own order -- newest
                    // first (purchased_on DESC, recorded_at DESC, id DESC).
                    // The sparkline wants the opposite, oldest-to-newest,
                    // left-to-right reading order.
                    PriceSparkline(purchases: purchases.reversed())
                        .listRowSeparator(.hidden)
                    ForEach(purchases, id: \.id) { purchase in
                        PurchaseRow(purchase: purchase, baseUnit: ingredient.base_unit)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deletePurchase(purchase)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
    }

    /// Rebuilds from `LocalStore` reads, same synchronous-blocking-GRDB-call
    /// idiom as `DashboardView`/`IngredientsListView`. `driftByIngredient` is
    /// called on just this ingredient's own live purchases (not the whole
    /// location's) -- it groups by `ingredient_id` internally, so scoping
    /// the input to one ingredient's rows still yields, at most, that one
    /// ingredient's `DriftResult`, without reading purchases that don't
    /// belong to this screen at all.
    private func load() {
        guard let store = appModel.store else {
            ingredient = nil
            purchases = []
            drift = nil
            loadError = nil
            return
        }
        do {
            ingredient = try store.ingredient(id: ingredientId)
            let history = try store.livePurchases(ingredientId: ingredientId)
            purchases = history
            drift = Costing.driftByIngredient(purchases: history)[ingredientId]
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// `tombstonePurchase` is B1's recovery path (spec: `DELETE
    /// /purchases/{id}` exists so bad OCR/manual-entry data is fixable
    /// in-product) -- unlike ingredient deletion there's no in-use guard to
    /// surface, so this is a direct swipe-delete with no extra confirmation
    /// step, matching the brief.
    private func deletePurchase(_ purchase: LocalPurchase) {
        guard let edits = appModel.edits else { return }
        do {
            try edits.tombstonePurchase(id: purchase.id)
            appModel.syncSoon()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// What `.task(id:)` reruns `load()` on -- same `pendingCount`/`syncState`
/// contract as `IngredientsListView.RefreshKey`/`DashboardView.RefreshKey`.
/// `ingredientId` is included even though it never actually changes within
/// one pushed instance's lifetime, for the same reason `DashboardView`
/// bundles every read-affecting input into one key rather than special-
/// casing which ones are "really" variable.
private struct RefreshKey: Equatable {
    let ingredientId: String
    let syncState: SyncState
    let pendingCount: Int

    @MainActor
    init(appModel: AppModel, ingredientId: String) {
        self.ingredientId = ingredientId
        syncState = appModel.syncState
        pendingCount = appModel.pendingCount
    }
}

// MARK: - Header

private struct HeaderSection: View {
    let ingredient: LocalIngredient

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ingredient.name)
                .font(.title3.weight(.semibold))
            LabeledContent("Vendor", value: ingredient.vendor ?? "—")
            LabeledContent("Category", value: ingredient.category ?? "—")
            LabeledContent("Unit", value: ingredient.base_unit)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Drift

private struct DriftSection: View {
    let drift: DriftResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Latest", value: "$\(drift.latestPrice)")
            LabeledContent("Trailing avg", value: trailingAvgText)
            if let driftPct = drift.driftPct {
                HStack {
                    Text("Drift")
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: direction(driftPct) == "up" ? "arrow.up" : "arrow.down")
                        Text(signedPercent(driftPct))
                    }
                    .foregroundStyle(direction(driftPct) == "up" ? .red : .green)
                }
            }
            Text(honestyLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var trailingAvgText: String {
        guard let trailingAvg = drift.trailingAvg else { return "—" }
        return "$\(trailingAvg)"
    }

    private var honestyLine: String {
        guard drift.driftPct != nil else {
            return "Not enough purchase history yet (\(drift.baselineN) of 3)"
        }
        return "vs \(drift.baselineN) purchases in the last 90 days"
    }

    /// Exact port of `Mover.direction`'s own derivation
    /// (`DashboardModel.build`): parse the already-kernel-produced
    /// `driftPct` string and compare against zero as a `Rational`, never a
    /// `Double`. `driftPct`'s sign is embedded in the string itself
    /// (`Kernel.roundHalfAway` only ever emits a leading "-" for a
    /// genuinely negative, non-zero result), so this can never actually
    /// fail for a value that reached this view -- `try?` only guards
    /// against `Rational.parseDec`'s throwing signature, defaulting to
    /// "down" the same way a zero/negative comparison would.
    private func direction(_ driftPct: String) -> String {
        guard let pct = try? Rational.parseDec(driftPct) else { return "down" }
        return pct.cmp(Rational(n: 0, d: 1)) > 0 ? "up" : "down"
    }
}

/// `driftPct + "%"`, with a leading "+" prepended for a positive value.
/// String-only, no `Double`/`Decimal` parse of the VALUE -- same idiom as
/// `DashboardView.signedPercent` (duplicated rather than shared since
/// that one is file-private to `DashboardView.swift`).
private func signedPercent(_ driftPct: String) -> String {
    let isNegative = driftPct.hasPrefix("-")
    let isZero = driftPct.allSatisfy { $0 == "0" || $0 == "." }
    let sign = (!isNegative && !isZero) ? "+" : ""
    return "\(sign)\(driftPct)%"
}

// MARK: - History

private struct PurchaseRow: View {
    let purchase: LocalPurchase
    let baseUnit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(purchase.purchased_on)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("$\(purchase.total_price)")
                    .font(.subheadline.weight(.semibold))
            }
            HStack {
                Text("\(purchase.qty_base_units) \(baseUnit)")
                Spacer()
                Text(unitPriceText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// `Kernel.unitPrice`, never the stored `unit_price` column (nil until
    /// a locally-created purchase's first pull echo -- same reasoning as
    /// `Costing.driftByIngredient`'s own doc comment). `total_price`/
    /// `qty_base_units` are already-validated positive decimals by the time
    /// a row exists (`Kernel.normalizePurchase` at creation, or echoed back
    /// from the server's own generated column), so this can't actually
    /// fail; `try?` only guards the throwing signature.
    private var unitPriceText: String {
        guard let unitPrice = try? Kernel.unitPrice(
            totalPrice: purchase.total_price, qtyBaseUnits: purchase.qty_base_units)
        else {
            return "—"
        }
        return "$\(unitPrice)/\(baseUnit)"
    }
}

/// A minimal, axis-less line chart over this ingredient's purchase history,
/// oldest-to-newest. `index` (not a real timestamp) is the x-plottable value
/// -- purchases aren't evenly spaced in time and a sparkline only needs
/// left-to-right ordering, not a true time scale. The y-plottable `Double`
/// conversion is pixels-only (the brief's explicit carve-out, same as
/// `DashboardView`'s top-movers bar); every point's accessibility label
/// carries the original decimal STRING, never a re-formatted `Double`.
private struct PriceSparkline: View {
    let purchases: [LocalPurchase]

    private struct Point: Identifiable {
        let id: String
        let index: Int
        let unitPrice: String
    }

    private var points: [Point] {
        purchases.enumerated().compactMap { index, purchase in
            guard let unitPrice = try? Kernel.unitPrice(
                totalPrice: purchase.total_price, qtyBaseUnits: purchase.qty_base_units)
            else {
                return nil
            }
            return Point(id: purchase.id, index: index, unitPrice: unitPrice)
        }
    }

    var body: some View {
        if !points.isEmpty {
            Chart(points) { point in
                LineMark(
                    x: .value("Purchase", point.index),
                    y: .value("Unit price", Double(point.unitPrice) ?? 0)
                )
                .interpolationMethod(.catmullRom)
                PointMark(
                    x: .value("Purchase", point.index),
                    y: .value("Unit price", Double(point.unitPrice) ?? 0)
                )
                .accessibilityLabel("$\(point.unitPrice)")
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 60)
        }
    }
}
