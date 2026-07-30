// The CostSauce Ingredients list — replaces Task 9's placeholder in the
// Ingredients tab. Every row is a pure rendering of already-local data:
// `LocalStore.liveIngredients()` for the rows themselves,
// `Costing.driftByIngredient` (Task 6, same function `DashboardView` uses)
// for each ingredient's latest price, and one batched
// `LocalStore.allLivePurchases()` read grouped by `ingredient_id` locally
// for the purchase count -- equivalent to calling
// `livePurchases(ingredientId:).count` per row (both are simply "live,
// non-deleted purchases for this ingredient"), but one query instead of N
// (Global Constraints: money/pct values stay STRINGS, rendered verbatim,
// "—" for nil -- never routed through Double/Float/Decimal).
//
// Swipe-to-delete goes through `LocalEdits.tombstoneIngredient`, which
// itself already runs the local in-use guard before minting any op (see
// that method's doc comment) -- `EditError.inUse` here is just surfacing
// that guard's result as the brief's alert, never a network round trip.

import SwiftUI
import CostSauceKit

struct IngredientsListView: View {
    let appModel: AppModel

    @State private var ingredients: [LocalIngredient]?
    @State private var drift: [String: DriftResult] = [:]
    @State private var purchaseCounts: [String: Int] = [:]
    @State private var loadError: String?
    @State private var pendingDelete: LocalIngredient?
    @State private var inUseMessage: String?

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
                "Couldn't Load Ingredients", systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if let ingredients {
            if ingredients.isEmpty {
                ContentUnavailableView(
                    "No Ingredients Yet", systemImage: "carrot",
                    description: Text("Add your first ingredient from the Add tab to start tracking prices."))
            } else {
                ingredientsList(ingredients)
            }
        } else {
            ProgressView()
        }
    }

    private func ingredientsList(_ ingredients: [LocalIngredient]) -> some View {
        List {
            ForEach(ingredients, id: \.id) { ingredient in
                NavigationLink {
                    IngredientDetailView(appModel: appModel, ingredientId: ingredient.id)
                } label: {
                    IngredientRow(
                        name: ingredient.name, baseUnit: ingredient.base_unit,
                        latestPrice: drift[ingredient.id]?.latestPrice,
                        purchaseCount: purchaseCounts[ingredient.id] ?? 0)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = ingredient
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")?",
            isPresented: confirmDeleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ingredient = pendingDelete { delete(ingredient) }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        }
        .alert("Can't Delete Ingredient", isPresented: inUseAlertBinding) {
            Button("OK") {}
        } message: {
            Text(inUseMessage ?? "")
        }
    }

    private var confirmDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var inUseAlertBinding: Binding<Bool> {
        Binding(get: { inUseMessage != nil }, set: { if !$0 { inUseMessage = nil } })
    }

    /// Rebuilds from `LocalStore` reads, same synchronous-blocking-GRDB-call
    /// idiom as `DashboardView.load()` -- there's no async DB layer here.
    private func load() {
        guard let store = appModel.store else {
            ingredients = nil
            drift = [:]
            purchaseCounts = [:]
            loadError = nil
            return
        }
        do {
            let liveIngredients = try store.liveIngredients()
            let purchases = try store.allLivePurchases()
            drift = Costing.driftByIngredient(purchases: purchases)
            var counts: [String: Int] = [:]
            for purchase in purchases {
                counts[purchase.ingredient_id, default: 0] += 1
            }
            purchaseCounts = counts
            ingredients = liveIngredients
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Local tombstone-then-sync, per the brief: `tombstoneIngredient`
    /// already refuses in-use ingredients locally (no op minted, no queue
    /// entry left behind on a bounce) -- `EditError.inUse` surfaces that as
    /// the alert; any other error falls back to the same load-error surface
    /// the initial read uses.
    private func delete(_ ingredient: LocalIngredient) {
        pendingDelete = nil
        guard let edits = appModel.edits else { return }
        do {
            try edits.tombstoneIngredient(id: ingredient.id)
            appModel.syncSoon()
        } catch let error as LocalEdits.EditError {
            if case .inUse(let count) = error {
                inUseMessage = "Used by \(count) recipe line(s). Remove it from those recipes first."
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// What `.task(id:)` reruns `load()` on -- `pendingCount` bumps
/// synchronously on every local write (same `AppModel.syncSoon` /
/// `LocalStore.enqueue` contract `DashboardView.RefreshKey` relies on), so
/// an offline tombstone or a newly-created ingredient shows up immediately.
/// `syncState` catches the other way the underlying data changes: a pull
/// applying server rows.
private struct RefreshKey: Equatable {
    let syncState: SyncState
    let pendingCount: Int

    @MainActor
    init(appModel: AppModel) {
        syncState = appModel.syncState
        pendingCount = appModel.pendingCount
    }
}

private struct IngredientRow: View {
    let name: String
    let baseUnit: String
    let latestPrice: String?
    let purchaseCount: Int

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    UnitTag(unit: baseUnit)
                    Text(purchaseCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(latestPriceText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(latestPrice == nil ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

    private var latestPriceText: String {
        guard let latestPrice else { return "—" }
        return "$\(latestPrice)"
    }

    private var purchaseCountText: String {
        purchaseCount == 1 ? "1 purchase" : "\(purchaseCount) purchases"
    }
}

private struct UnitTag: View {
    let unit: String

    var body: some View {
        Text(unit)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.gray.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
