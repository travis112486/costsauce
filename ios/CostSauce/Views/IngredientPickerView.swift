// The reusable fuzzy ingredient picker, extracted verbatim from
// PurchaseEntryView (Task 7) so the recipe editor (Task 8/9) can present the
// identical search -> match -> pick -> create-new-ingredient flow. One
// capability is new: a caller can pass ids to exclude (the recipe editor
// passes the ingredients already on the recipe being edited, spec §9) so
// they cannot be picked twice. Purchase entry passes an empty set and is
// unaffected.
//
// Global Constraints carried over unchanged from PurchaseEntryView: this
// view never touches the network directly (matching and ingredient
// creation are local-store operations; `appModel.syncSoon()` after a
// successful create is the only thing that schedules a push). Exclusion is
// applied to `Kernel.matchIngredient`/`nearMatches`' output AFTER they rank
// the FULL candidate list, never to the input candidate list: filtering the
// pool before ranking could change which matches surface and in what
// order; filtering the ranked result cannot.

import SwiftUI
import CostSauceKit

struct IngredientPickerView: View {
    let appModel: AppModel
    let excludedIngredientIds: Set<String>
    let onPick: (LocalIngredient) -> Void

    // Matching/candidate state -- `candidates` is `Kernel.Candidate(id:name:)`
    // over `store.liveIngredientsByCreation()`'s own (created_at, id) order
    // (the kernel contract, api/routes/ingredients.py:21-28); `ingredientsById`
    // is the same read's full rows, keyed by id, so a selected candidate's
    // `base_unit` is available without a second store round trip.
    @State private var candidates: [Kernel.Candidate] = []
    @State private var ingredientsById: [String: LocalIngredient] = [:]
    @State private var loadError: String?

    @State private var nameQuery = ""
    /// Set only by an explicit user action -- tapping a near-match row, or
    /// a completed/adopted `createIngredient` call. `nil` means "let the
    /// live `matchResult` (if any) stand as the selection" -- see
    /// `effectiveSelectionId`.
    @State private var manualSelection: (id: String, name: String)?
    @State private var createSheetPresented = false

    var body: some View {
        Group {
            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                }
            }
            ingredientSection
        }
        .task(id: RefreshKey(appModel: appModel)) {
            loadCandidates()
        }
        .onChange(of: effectiveSelectionId) { _, newId in
            guard let newId, let ingredient = ingredientsById[newId] else { return }
            onPick(ingredient)
        }
        .sheet(isPresented: $createSheetPresented) {
            CreateIngredientSheet(appModel: appModel, name: trimmedQuery) { id, name in
                loadCandidates()
                manualSelection = (id: id, name: name)
                nameQuery = name
                createSheetPresented = false
            }
        }
    }

    // MARK: - Ingredient picker

    /// Name field with live results: an exact/fuzzy `Kernel.matchIngredient`
    /// hit renders as a selected chip (auto-picked, per §11 -- "picks from
    /// the locally-synced list with local fuzzy ranking"); `Kernel.nearMatches`'
    /// remaining candidates render as plain tappable rows below it so the
    /// user can override an auto-pick that guessed wrong; "Create new
    /// ingredient" is the deliberately secondary action (§11) rendered
    /// last, below every match row.
    @ViewBuilder
    private var ingredientSection: some View {
        Section("Ingredient") {
            TextField("Ingredient name", text: nameBinding)
                .autocorrectionDisabled()
            if let effectiveIngredient {
                SelectedIngredientChip(ingredient: effectiveIngredient) {
                    manualSelection = nil
                    nameQuery = ""
                }
            }
            ForEach(nearMatchRows, id: \.id) { candidate in
                Button {
                    manualSelection = (id: candidate.id, name: candidate.name)
                    nameQuery = candidate.name
                } label: {
                    Text(candidate.name)
                }
            }
            if !trimmedQuery.isEmpty {
                Button {
                    createSheetPresented = true
                } label: {
                    Label("Create new ingredient \u{201C}\(trimmedQuery)\u{201D}", systemImage: "plus")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedQuery: String {
        nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ranked over the FULL candidate list, then the excluded id (if any)
    /// is dropped from the result -- never removed from `candidates` before
    /// `Kernel.matchIngredient` sees it, so exclusion cannot change which
    /// candidate wins the exact/fuzzy pass.
    private var matchResult: Kernel.Match? {
        guard let match = Kernel.matchIngredient(name: nameQuery, candidates: candidates),
            !excludedIngredientIds.contains(match.id)
        else { return nil }
        return match
    }

    /// `nearMatches`' own top-3 (created_at, id) order, minus whichever
    /// candidate is already shown as the auto-picked row above -- avoids
    /// showing the same ingredient twice -- and minus any excluded id,
    /// applied to the already-ranked top 3 rather than to the candidate
    /// pool `nearMatches` ranks over.
    private var nearMatchRows: [Kernel.Candidate] {
        Kernel.nearMatches(name: nameQuery, candidates: candidates)
            .filter { $0.id != matchResult?.id && !excludedIngredientIds.contains($0.id) }
    }

    private var effectiveSelectionId: String? {
        manualSelection?.id ?? matchResult?.id
    }

    private var effectiveIngredient: LocalIngredient? {
        effectiveSelectionId.flatMap { ingredientsById[$0] }
    }

    /// A custom binding rather than a plain `$nameQuery`: any USER edit
    /// (the only path that flows through this setter -- programmatic
    /// selections below assign `nameQuery` directly) invalidates a prior
    /// manual pick unless the new text still spells the same name, so
    /// resuming typing after tapping a near-match row falls back to live
    /// re-matching instead of leaving a stale manual selection behind.
    private var nameBinding: Binding<String> {
        Binding(
            get: { nameQuery },
            set: { newValue in
                nameQuery = newValue
                if manualSelection?.name != newValue {
                    manualSelection = nil
                }
            }
        )
    }

    /// Rebuilds from `LocalStore` reads, same synchronous-blocking-GRDB-call
    /// idiom as `DashboardView`/`IngredientsListView`.
    private func loadCandidates() {
        guard let store = appModel.store else {
            candidates = []
            ingredientsById = [:]
            loadError = nil
            return
        }
        do {
            let ingredients = try store.liveIngredientsByCreation()
            candidates = ingredients.map { Kernel.Candidate(id: $0.id, name: $0.name) }
            ingredientsById = Dictionary(uniqueKeysWithValues: ingredients.map { ($0.id, $0) })
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// What `.task(id:)` reruns `loadCandidates()` on -- same `pendingCount`/
/// `syncState` contract as the other tabs' own `RefreshKey`s, so an
/// ingredient created elsewhere (or pulled from the server) is searchable
/// here immediately.
private struct RefreshKey: Equatable {
    let syncState: SyncState
    let pendingCount: Int

    @MainActor
    init(appModel: AppModel) {
        syncState = appModel.syncState
        pendingCount = appModel.pendingCount
    }
}

// MARK: - Selected ingredient chip

/// The §11 "exact/fuzzy match → selected chip with the matched name" --
/// a genuine Capsule token, same idiom as `IngredientsListView.UnitTag`/
/// `DashboardView.StatusChip`, not just a plain list row. The trailing
/// "x" clears the current pick (auto or manual) and restarts the search.
private struct SelectedIngredientChip: View {
    let ingredient: LocalIngredient
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text(ingredient.name)
                .font(.subheadline.weight(.semibold))
            Text(ingredient.base_unit)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.15), in: Capsule())
        .foregroundStyle(.green)
    }
}

// MARK: - Create ingredient sheet

/// `IngredientIn.base_unit`'s server-side `Literal` vocabulary
/// (api/models.py:63), in the same order it's declared there.
private let baseUnitChoices = ["lb", "oz", "kg", "g", "each"]

/// The §11 secondary-action sheet: base_unit picker, vendor, category --
/// `name` is fixed to whatever the user had already typed into the search
/// field (shown as a header, not re-editable here) rather than a fourth
/// input. `EditError.duplicate` is adopted silently (web's 409-adoption
/// parity, per the brief): `onCreated` fires with the EXISTING id/name and
/// no error is ever shown for that case.
private struct CreateIngredientSheet: View {
    let appModel: AppModel
    let name: String
    var onCreated: (_ id: String, _ name: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var baseUnit = baseUnitChoices[0]
    @State private var vendor = ""
    @State private var category = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(name).font(.headline)
                }
                Section("Base unit") {
                    Picker("Base unit", selection: $baseUnit) {
                        ForEach(baseUnitChoices, id: \.self) { choice in
                            Text(choice).tag(choice)
                        }
                    }
                }
                Section {
                    TextField("Vendor (optional)", text: $vendor)
                    TextField("Category (optional)", text: $category)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                }
            }
        }
    }

    private func create() {
        guard let edits = appModel.edits else { return }
        errorMessage = nil
        let trimmedVendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let id = try edits.createIngredient(
                name: name, baseUnit: baseUnit,
                vendor: trimmedVendor.isEmpty ? nil : trimmedVendor,
                category: trimmedCategory.isEmpty ? nil : trimmedCategory)
            // A genuine local write -- mints a queued insert op, same as
            // every other `LocalEdits` mutation call site (`PurchaseEntryView
            // .save()`'s own `createPurchase` path, `IngredientsListView`'s
            // tombstone path) -- so it gets the same "schedule a sync right
            // after the edit" treatment.
            appModel.syncSoon()
            onCreated(id, name)
        } catch let error as LocalEdits.EditError {
            if case .duplicate(let existingId, let existingName) = error {
                // No `syncSoon()` here on purpose: `createIngredient` throws
                // `.duplicate` BEFORE it ever calls `store.enqueue` (see its
                // own doc comment / implementation), so adopting the
                // existing id mints no op and changes nothing that needs
                // pushing -- this is a pure local read, not a write.
                onCreated(existingId, existingName)
            }
            // `.inUse` is never thrown by `createIngredient` (only by
            // `tombstoneIngredient`) -- no other case reaches here.
        } catch let error as KernelError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
