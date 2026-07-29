// The CostSauce purchase entry form — Task 12's real Add tab content,
// replacing Task 9's placeholder. Every write here goes through
// `LocalEdits` (ingredient creation, purchase creation); this screen never
// touches `LocalStore`'s write surface directly and never opens a network
// connection itself -- offline is the point (§11): matching, ingredient
// creation, and purchase creation are all local-store operations, and the
// only thing that ever reaches the network is the debounced
// `appModel.syncSoon()` call after a successful save.
//
// Global Constraints: money/qty values are STRINGS end to end -- `qty`,
// `unit`, `qtyInCase`, `totalPrice` are passed through to
// `LocalEdits.createPurchase` exactly as typed. `qty_base_units` is never
// computed in this file: `createPurchase` (via `Kernel.normalizePurchase`)
// is the sole owner of that derivation, and the post-save "success
// indicator" reads it back from the row `createPurchase` just wrote rather
// than re-deriving it here. `purchased_on` is never touched by
// Date/Calendar arithmetic -- the `DatePicker`'s own `Date` is only ever
// read via `Kernel.todayLocalISO(now:)` (the same "read local Y/M/D
// components" call the default value itself uses), never added to or
// subtracted from.

import SwiftUI
import CostSauceKit

struct PurchaseEntryView: View {
    let appModel: AppModel

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

    // Purchase fields.
    @State private var purchaseDate = Date()
    @State private var qty = ""
    @State private var unit = ""
    @State private var qtyInCase = ""
    @State private var totalPrice = ""

    @State private var errorMessage: String?
    @State private var savedMessage: String?

    var body: some View {
        Form {
            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                }
            }
            if let savedMessage {
                // Deliberately OUTSIDE the ingredient-gated section below --
                // `resetFormKeepingDate()` clears the selection right after
                // a save, which would otherwise carry this banner away with
                // it before the user ever saw it.
                Section {
                    Label(savedMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            ingredientSection
            if let effectiveIngredient {
                purchaseDetailsSection(for: effectiveIngredient)
            } else {
                Section {
                    Text("Search for an ingredient above, or create a new one, to continue.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: RefreshKey(appModel: appModel)) {
            loadCandidates()
        }
        .onChange(of: effectiveSelectionId) { _, newId in
            guard let newId, let ingredient = ingredientsById[newId] else { return }
            unit = unitChoices(for: ingredient).first ?? ""
            qtyInCase = ""
        }
        .onChange(of: unit) { _, newUnit in
            if newUnit != "case" {
                qtyInCase = ""
            }
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

    private var matchResult: Kernel.Match? {
        Kernel.matchIngredient(name: nameQuery, candidates: candidates)
    }

    /// `nearMatches`' own top-3 (created_at, id) order, minus whichever
    /// candidate is already shown as the auto-picked row above -- avoids
    /// showing the same ingredient twice.
    private var nearMatchRows: [Kernel.Candidate] {
        Kernel.nearMatches(name: nameQuery, candidates: candidates)
            .filter { $0.id != matchResult?.id }
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
                savedMessage = nil
            }
        )
    }

    private func unitChoices(for ingredient: LocalIngredient) -> [String] {
        appModel.edits?.unitChoices(baseUnit: ingredient.base_unit) ?? []
    }

    // MARK: - Purchase fields

    @ViewBuilder
    private func purchaseDetailsSection(for ingredient: LocalIngredient) -> some View {
        Section("Purchase") {
            DatePicker("Date", selection: $purchaseDate, displayedComponents: .date)
            TextField("Quantity", text: $qty)
                .keyboardType(.decimalPad)
            Picker("Unit", selection: $unit) {
                ForEach(unitChoices(for: ingredient), id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            if unit == "case" {
                TextField("Quantity per case", text: $qtyInCase)
                    .keyboardType(.decimalPad)
            }
            TextField("Total price", text: $totalPrice)
                .keyboardType(.decimalPad)
        }
        if let errorMessage {
            Section {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        Section {
            Button("Save Purchase") {
                save()
            }
            .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        effectiveIngredient != nil && !qty.isEmpty && !unit.isEmpty && !totalPrice.isEmpty
            && (unit != "case" || !qtyInCase.isEmpty)
    }

    /// `Kernel.todayLocalISO(now:)` reading the `DatePicker`'s own `Date` --
    /// the one sanctioned "read local Y/M/D components" use (same call the
    /// default `purchaseDate = Date()` resolves through), never
    /// `DateFormatter`/`Calendar` add-subtract arithmetic.
    private var purchasedOn: String {
        Kernel.todayLocalISO(now: purchaseDate)
    }

    /// Save → `createPurchase` → success indicator (`Kernel.unitPrice` read
    /// back from the row `createPurchase` just wrote, never re-derived from
    /// the raw form fields) → `syncSoon()` → form resets keeping the date.
    private func save() {
        guard let edits = appModel.edits, let ingredient = effectiveIngredient else { return }
        errorMessage = nil
        savedMessage = nil
        do {
            let id = try edits.createPurchase(
                ingredientId: ingredient.id, purchasedOn: purchasedOn, qty: qty, unit: unit,
                qtyInCase: unit == "case" ? qtyInCase : nil, totalPrice: totalPrice)
            savedMessage = successMessage(purchaseId: id, ingredient: ingredient)
            appModel.syncSoon()
            resetFormKeepingDate()
        } catch let error as KernelError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func successMessage(purchaseId: String, ingredient: LocalIngredient) -> String {
        guard let store = appModel.store,
            let purchase = try? store.livePurchases(ingredientId: ingredient.id)
                .first(where: { $0.id == purchaseId }),
            let unitPrice = try? Kernel.unitPrice(
                totalPrice: purchase.total_price, qtyBaseUnits: purchase.qty_base_units)
        else {
            return "Purchase saved."
        }
        return "Saved — $\(unitPrice)/\(ingredient.base_unit)"
    }

    private func resetFormKeepingDate() {
        nameQuery = ""
        manualSelection = nil
        qty = ""
        unit = ""
        qtyInCase = ""
        totalPrice = ""
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
            onCreated(id, name)
        } catch let error as LocalEdits.EditError {
            if case .duplicate(let existingId, let existingName) = error {
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
