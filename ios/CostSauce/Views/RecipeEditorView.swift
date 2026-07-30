// The CostSauce recipe editor — Task 8 builds the create path: composing a
// new dish entirely offline as an in-memory `RecipeDraft` (spec D4) with a
// live plate-cost preview, writing NOTHING to the local store until Save.
// Task 9 fills in `.edit(recipeId:)`, which works directly on stored rows
// instead of a draft (D4's other half, immediate-write) — this file's
// `.edit` branch is a placeholder only, out of this task's scope.
//
// Global Constraints: every money/qty/percentage value is a STRING end to
// end — `RecipeDraft.name`/`menuPrice`/`targetFcPct` and each line's `qty`
// are plain `TextField` string bindings (decimal-pad keyboards for the
// numeric ones), never routed through Double/Float/Decimal.
// `RecipeDraft.validate()` (Task 3) is the ONLY place validation rules
// live — this file only maps its `DraftError` cases to their exact
// user-facing strings (Task 3's own doc comment: "The messages above are
// the exact user-facing strings; they live in the VIEW (Task 8), not
// here") and renders them next to the offending field; it never
// re-implements a rule `validate()` already owns.
//
// `appModel.canEditRecipes` (Task 6) gates the Save button here — Task 8 is
// its first consumer anywhere in the app. This screen is normally
// unreachable for a bookkeeper at all (Task 10 hides the "+" entry point
// entirely), so the disabled Save button is a second line of defence, not
// the primary gate.

import SwiftUI
import CostSauceKit

struct RecipeEditorView: View {
    enum Mode {
        case create
        case edit(recipeId: String)
    }

    let appModel: AppModel
    let mode: Mode

    @Environment(\.dismiss) private var dismiss

    // MARK: - Create-path state (Task 8)

    @State private var draft = RecipeDraft()
    /// Populated by `save()` from `draft.validate()`'s full result — Task
    /// 3's contract returns ALL failures at once, in declaration order, so
    /// every offending field gets marked in a single pass rather than one
    /// error at a time.
    @State private var fieldErrors: [RecipeDraft.DraftError] = []
    /// A thrown `KernelError.message` (or another error's
    /// `localizedDescription`) from `saveNewRecipe` itself — distinct from
    /// `fieldErrors`, which come from the pre-flight `validate()` pass that
    /// runs before `saveNewRecipe` is ever called.
    @State private var saveErrorMessage: String?
    @State private var isSaving = false
    @State private var addIngredientPresented = false

    // MARK: - Store reads backing the preview (ingredient names/units, drift)

    @State private var ingredients: [LocalIngredient] = []
    @State private var drift: [String: DriftResult] = [:]
    @State private var loadError: String?

    var body: some View {
        Group {
            switch mode {
            case .create:
                createForm
            case .edit:
                // Task 9's real edit path. Never reachable in this task's
                // build — Task 10, the only wired entry point into this
                // screen, does not exist yet either.
                ProgressView()
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: RefreshKey(appModel: appModel)) {
            loadStoreData()
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .create: return "New Recipe"
        case .edit: return "Recipe"
        }
    }

    // MARK: - Create form

    private var createForm: some View {
        Form {
            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                }
            }
            recipeFieldsSection
            linesSection
            Section("Preview") {
                PlatePreview(result: previewResult, suppressSuggestions: appModel.suppressSuggestions)
            }
            if let saveErrorMessage {
                Section {
                    Text(saveErrorMessage).foregroundStyle(.red)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { save() }
                        .disabled(!appModel.canEditRecipes)
                }
            }
        }
        .navigationDestination(isPresented: $addIngredientPresented) {
            addIngredientDestination
        }
    }

    @ViewBuilder
    private var recipeFieldsSection: some View {
        Section("Recipe") {
            TextField("Name", text: $draft.name)
            if let message = fieldMessage(.nameEmpty) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            TextField("Menu price", text: $draft.menuPrice)
                .keyboardType(.decimalPad)
            if let message = fieldMessage(.menuPriceInvalid) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            TextField("Target food cost %", text: $draft.targetFcPct)
                .keyboardType(.decimalPad)
            if let message = fieldMessage(.targetFcPctInvalid) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var linesSection: some View {
        Section("Ingredients") {
            if let message = fieldMessage(.noLines) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            ForEach(draft.lines) { line in
                LineRow(
                    name: ingredientsById[line.ingredientId]?.name ?? "—",
                    baseUnit: ingredientsById[line.ingredientId]?.base_unit,
                    qty: qtyBinding(for: line),
                    errorMessage: lineErrorMessage(for: line))
            }
            .onDelete(perform: removeLines)
            Button {
                addIngredientPresented = true
            } label: {
                Label("Add ingredient", systemImage: "plus")
            }
        }
    }

    /// The picker lives on its own PUSHED screen (not a `.sheet`), presented
    /// solely to pick-then-add a line — unlike `PurchaseEntryView`, nothing
    /// on this screen is gated on the picker's LIVE selection state, so
    /// `onClear`/`onQueryEdited` (both meaningful only to a caller that
    /// renders dependent content alongside the picker itself) are no-ops
    /// here; see this task's report for why.
    ///
    /// Deliberately a PUSH (`.navigationDestination(isPresented:)`), not a
    /// `.sheet`: `IngredientPickerView` already presents its own
    /// `CreateIngredientSheet` internally via `.sheet(isPresented:)`
    /// (Task 7, frozen) — wrapping the WHOLE picker in a second, outer
    /// `.sheet` here makes `CreateIngredientSheet` a sheet-presented-from-
    /// within-a-sheet, which reproduced live, every time: tapping "Create
    /// new ingredient" silently dismissed the OUTER sheet instead of
    /// presenting the inner one (confirmed with a brand-new, non-colliding
    /// name, ruling out any match/exclusion timing). Pushing onto the same
    /// `NavigationStack` this screen is itself pushed on (Task 10 wires
    /// entry via `NavigationLink`, so one is always present) keeps
    /// `CreateIngredientSheet` at the SAME single-nesting-depth
    /// `PurchaseEntryView` already proves works.
    private var addIngredientDestination: some View {
        Form {
            IngredientPickerView(
                appModel: appModel,
                excludedIngredientIds: Set(draft.lines.map(\.ingredientId)),
                onPick: addLine,
                onClear: {},
                onQueryEdited: {})
        }
        .navigationTitle("Add Ingredient")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Field error mapping (Task 3's frozen, exact strings)

    private func fieldMessage(_ target: RecipeDraft.DraftError) -> String? {
        fieldErrors.contains(target) ? message(for: target) : nil
    }

    private func lineErrorMessage(for line: RecipeDraft.Line) -> String? {
        if fieldErrors.contains(where: {
            if case .lineQtyInvalid(let id) = $0 { return id == line.id }
            return false
        }) {
            return message(for: .lineQtyInvalid(lineId: line.id))
        }
        if fieldErrors.contains(where: {
            if case .duplicateIngredient(let id) = $0 { return id == line.ingredientId }
            return false
        }) {
            return message(for: .duplicateIngredient(ingredientId: line.ingredientId))
        }
        return nil
    }

    /// The exact user-facing strings Task 3's `RecipeDraft.DraftError`
    /// frozen list specifies. `validate()` itself is pure and renders
    /// nothing (it lives in the Kit, which has no view layer) — this
    /// switch is the one place those strings turn into UI text.
    private func message(for error: RecipeDraft.DraftError) -> String {
        switch error {
        case .nameEmpty: return "Enter a name."
        case .menuPriceInvalid: return "Menu price must be greater than zero."
        case .targetFcPctInvalid: return "Target food cost % must be greater than zero."
        case .noLines: return "Add at least one ingredient."
        case .lineQtyInvalid: return "Quantity must be greater than zero."
        case .duplicateIngredient: return "That ingredient is already on this recipe."
        }
    }

    // MARK: - Draft mutation

    /// `IngredientPickerView`'s `onPick` — `excludedIngredientIds` above
    /// already keeps an already-added ingredient out of the picker's own
    /// match/near-match/create-new results (including the create-new
    /// duplicate-adoption refusal — see `IngredientPickerView`'s doc
    /// comment), so this is never called with an ingredient already on
    /// `draft.lines`.
    private func addLine(_ ingredient: LocalIngredient) {
        draft.lines.append(RecipeDraft.Line(ingredientId: ingredient.id, qty: ""))
        addIngredientPresented = false
    }

    /// Swipe-to-delete on a draft line — nothing exists yet, so this is a
    /// plain in-memory removal, no op, no confirmation (spec: "no op —
    /// nothing exists yet").
    private func removeLines(at offsets: IndexSet) {
        draft.lines.remove(atOffsets: offsets)
    }

    private func qtyBinding(for line: RecipeDraft.Line) -> Binding<String> {
        Binding(
            get: { draft.lines.first(where: { $0.id == line.id })?.qty ?? "" },
            set: { newValue in
                guard let index = draft.lines.firstIndex(where: { $0.id == line.id }) else { return }
                draft.lines[index].qty = newValue
            })
    }

    private var ingredientsById: [String: LocalIngredient] {
        Dictionary(uniqueKeysWithValues: ingredients.map { ($0.id, $0) })
    }

    // MARK: - Preview

    /// `Costing.previewPlate` recomputed fresh on every render — a
    /// computed property, not cached `@State`, so any draft edit (name,
    /// price, a line's qty, adding/removing a line) is reflected the
    /// instant SwiftUI re-renders this view, with no separate `onChange`
    /// wiring needed. `try?` folds a genuinely malformed line quantity
    /// (mid-typing — e.g. a field the user has just cleared) into "no
    /// preview yet" rather than crashing: `previewPlate` only throws past a
    /// line whose ingredient IS live and priced but whose `qty` fails to
    /// parse (its own doc comment — an unresolvable line short-circuits
    /// before ever touching `qty`), a state `validate()` would flag as
    /// `.lineQtyInvalid` on Save regardless.
    ///
    /// `menuPrice`/`targetFcPct` are passed through `positiveDecimalOrNil`
    /// rather than straight from `draft` -- `RecipeDraft`'s defaults leave
    /// `menuPrice` `""` until the user types one, and `previewPlate`'s
    /// `menuPrice: String?`/`targetFcPct: String?` parameters mean "not
    /// supplied" only for a genuine `nil`. Passing `""` auto-wraps to
    /// `.some("")`, which satisfies `previewPlate`'s `if complete, let
    /// menuPrice, let targetFcPct` guard and then fails to parse inside it
    /// -- a throw this `try?` cannot distinguish from a real failure,
    /// collapsing the WHOLE `PreviewResult` (plate cost included) to nil
    /// instead of just leaving `fcPct`/`status`/`suggestedPrice` nil. Fixed
    /// at this call site, per plan: `Costing.previewPlate` itself is
    /// correct and already pinned by the Kit's own tests (which pass
    /// `nil`, not `""`, for "not supplied").
    private var previewResult: Costing.PreviewResult? {
        try? Costing.previewPlate(
            lines: draft.lines.map { (ingredientId: $0.ingredientId, qty: $0.qty) },
            menuPrice: positiveDecimalOrNil(draft.menuPrice),
            targetFcPct: positiveDecimalOrNil(draft.targetFcPct),
            ingredients: ingredients, drift: drift)
    }

    /// `nil` unless `s` parses as a positive `Rational` -- the same
    /// positivity test `RecipeDraft.validate()` applies to these two
    /// fields (its own `isPositiveDecimal`, private to that type), used
    /// here purely to decide what counts as "supplied" for
    /// `previewPlate`'s optional parameters. This does not relax or
    /// duplicate a VALIDATION rule: an empty/invalid value here still
    /// blocks Save exactly as before, unchanged, via `draft.validate()`.
    private func positiveDecimalOrNil(_ s: String) -> String? {
        guard let value = try? Rational.parseDec(s), value.isPositive else { return nil }
        return s
    }

    // MARK: - Store reads

    /// Rebuilds from `LocalStore` reads, same synchronous-blocking-GRDB-call
    /// idiom as `DashboardView`/`IngredientsListView`/`IngredientPickerView`.
    private func loadStoreData() {
        guard let store = appModel.store else {
            ingredients = []
            drift = [:]
            loadError = nil
            return
        }
        do {
            ingredients = try store.liveIngredients()
            drift = Costing.driftByIngredient(purchases: try store.allLivePurchases())
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Save

    /// `draft.validate()` first (Task 3 — pure, all-errors-at-once): a
    /// non-empty result marks every offending field and writes NOTHING.
    /// Only once validation is clean does this call `saveNewRecipe`, which
    /// re-validates as a backstop (its own doc comment) and is not expected
    /// to actually throw a `DraftError` from this call site — handled
    /// anyway rather than falling through to a generic, unhelpful message.
    private func save() {
        guard appModel.canEditRecipes, let edits = appModel.edits, !isSaving else { return }
        let errors = draft.validate()
        guard errors.isEmpty else {
            fieldErrors = errors
            saveErrorMessage = nil
            return
        }
        fieldErrors = []
        saveErrorMessage = nil
        isSaving = true
        do {
            _ = try edits.saveNewRecipe(draft)
            appModel.syncSoon()
            dismiss()
        } catch let error as KernelError {
            saveErrorMessage = error.message
            isSaving = false
        } catch let error as RecipeDraft.DraftError {
            saveErrorMessage = message(for: error)
            isSaving = false
        } catch {
            saveErrorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

/// What `.task(id:)` reruns `loadStoreData()` on — same `pendingCount`/
/// `syncState` contract as every other tab's own `RefreshKey`, so an
/// ingredient priced or created elsewhere (or pulled from the server) feeds
/// the preview immediately.
private struct RefreshKey: Equatable {
    let syncState: SyncState
    let pendingCount: Int

    @MainActor
    init(appModel: AppModel) {
        syncState = appModel.syncState
        pendingCount = appModel.pendingCount
    }
}

// MARK: - Line row

private struct LineRow: View {
    let name: String
    let baseUnit: String?
    let qty: Binding<String>
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                TextField("Qty", text: qty)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                if let baseUnit {
                    Text(baseUnit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Plate preview

/// Same rendering contract as `DashboardView.MenuRow` (§10.1/§5.5): plate
/// cost is always shown (rounds up to "—" only in the rare case
/// `previewResult` itself is nil, see that computed property's own doc
/// comment); FC%/status/suggested price only render when `complete` —
/// never a misleading percentage over a partial set of lines — and
/// suggested price additionally obeys `suppressSuggestions` while sync is
/// behind, exactly as `MenuRow` already does.
private struct PlatePreview: View {
    let result: Costing.PreviewResult?
    let suppressSuggestions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Plate \(plateCostText)")
                    .font(.subheadline.weight(.semibold))
                if let result, result.complete, let status = result.status {
                    Spacer()
                    StatusChip(status: status)
                }
            }
            if let result, result.complete {
                HStack(spacing: 12) {
                    Text("FC \(fcPctText(result))")
                    Text(suggestedPriceText(result))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Add prices to see food cost")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var plateCostText: String {
        guard let result else { return "—" }
        return "$\(result.plateCost)"
    }

    private func fcPctText(_ result: Costing.PreviewResult) -> String {
        guard let fcPct = result.fcPct else { return "—" }
        return "\(fcPct)%"
    }

    /// Mirrors `DashboardView.MenuRow.suggestedPriceText` exactly (§5.5) —
    /// only ever called once `result.complete` already holds: sync not
    /// caught up -> "syncing…"; else the real suggested price.
    private func suggestedPriceText(_ result: Costing.PreviewResult) -> String {
        guard !suppressSuggestions else { return "Sugg. syncing…" }
        return "Sugg. $\(result.suggestedPrice ?? "—")"
    }
}

/// Duplicated from `DashboardView`'s own file-private `StatusChip` rather
/// than shared — same call `IngredientDetailView.swift`'s doc comment
/// already makes for `signedPercent`: that one is file-private to
/// `DashboardView.swift`.
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
