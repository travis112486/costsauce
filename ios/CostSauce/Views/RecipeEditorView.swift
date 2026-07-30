// The CostSauce recipe editor — Task 8 built the create path: composing a
// new dish entirely offline as an in-memory `RecipeDraft` (spec D4) with a
// live plate-cost preview, writing NOTHING to the local store until Save.
// Task 9 fills in `.edit(recipeId:)`, which works directly on stored rows
// instead of a draft (D4's other half, immediate-write): an existing dish
// is live data, so there is no draft and no Save button on this path --
// every change (a field blur/return, a debounced quantity edit, an added
// or removed line) writes its row and enqueues its op the moment it
// happens, then calls `appModel.syncSoon()`. Reads come from
// `LocalStore.recipe(id:)`/`liveRecipeItems(recipeId:)` through the same
// `RefreshKey`/`.task(id:)` idiom the create path (and every sibling view)
// already uses, so a pull that changes the recipe re-renders it here too.
//
// Global Constraints: every money/qty/percentage value is a STRING end to
// end — `RecipeDraft.name`/`menuPrice`/`targetFcPct` and each line's `qty`
// are plain `TextField` string bindings (decimal-pad keyboards for the
// numeric ones), never routed through Double/Float/Decimal. The edit
// path's own `nameText`/`menuPriceText`/`targetFcPctText`/`qtyTexts` follow
// the exact same rule.
// `RecipeDraft.validate()` (Task 3) is the ONLY place CREATE-path
// validation rules live — this file only maps its `DraftError` cases to
// their exact user-facing strings (Task 3's own doc comment: "The messages
// above are the exact user-facing strings; they live in the VIEW (Task
// 8), not here") and renders them next to the offending field; it never
// re-implements a rule `validate()` already owns. The edit path reuses
// several of those same frozen strings (`message(for:)`) for the
// equivalent per-field commit failures rather than inventing new text or
// surfacing `LocalEdits`' own internal `KernelError.message` (English
// meant for a log, not a user).
//
// `appModel.canEditRecipes` (Task 6) gates the Save button on the create
// path and every write affordance on the edit path (Task 9): a bookkeeper
// reaches a fully read-only rendering of the SAME fields/lines/preview,
// never a blank or missing screen, because reading is permitted by RLS.
// This screen is normally unreachable for a bookkeeper at all for
// CREATION (Task 10 hides the "+" entry point entirely), so the disabled
// Save button there is a second line of defence, not the primary gate --
// but EDITING an existing recipe stays reachable (a bookkeeper can still
// view costing), so the edit path's read-only rendering is not a backstop,
// it's load-bearing.

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

    // MARK: - Edit-path state (Task 9)

    /// The stored recipe row itself. `LocalStore.recipe(id:)` is NOT
    /// filtered by `deleted_at` (same contract as `ingredient(id:)`), so a
    /// recipe tombstoned from elsewhere while this screen is open still
    /// reads back non-nil with `deleted_at` set, which `editContent` below
    /// turns into a "deleted" state rather than a crash or a stale form.
    @State private var recipe: LocalRecipe?
    @State private var lines: [LocalRecipeItem] = []

    /// Mirrors of the stored recipe row's editable columns. Reseeded from
    /// `recipe` on every reload UNLESS the matching field is the one
    /// currently focused (`loadEditState`'s guard) -- otherwise an
    /// unrelated write elsewhere (which bumps `pendingCount` and reruns
    /// `.task(id:)`) would silently overwrite whatever the user is mid-
    /// typing into this field before they ever get a chance to commit it.
    @State private var nameText = ""
    @State private var menuPriceText = ""
    @State private var targetFcPctText = ""
    @State private var nameFieldInvalid = false
    @State private var menuPriceFieldInvalid = false
    @State private var targetFcPctFieldInvalid = false
    /// A thrown `KernelError.message` from `updateRecipeFields` itself --
    /// only reachable as a backstop, since `commitName`/`commitMenuPrice`/
    /// `commitTargetFcPct` already pre-validate with the same positivity
    /// check `RecipeDraft.validate()` uses before ever calling it.
    @State private var recipeFieldsErrorMessage: String?

    /// Per-line quantity text, keyed by the STORED `recipe_items.id` (never
    /// a fresh id of its own — unlike the create path's `RecipeDraft.Line`,
    /// there is no local-only line identity here). Reseeded from `lines` on
    /// reload with the same currently-focused-field carve-out as the three
    /// recipe fields above.
    @State private var qtyTexts: [String: String] = [:]
    @State private var qtyErrors: [String: String] = [:]
    /// One coalescing debounce `Task` per line, same cancel-then-resleep
    /// shape as `AppModel.syncSoon()` -- keyed by line id so editing two
    /// lines' quantities in quick succession debounces each independently
    /// rather than one line's edit resetting another's timer.
    @State private var qtyDebounceTasks: [String: Task<Void, Never>] = [:]

    @FocusState private var focusedField: EditField?

    @State private var addLineDestinationPresented = false
    @State private var newLineIngredient: LocalIngredient?
    @State private var newLineQtyText = ""
    @State private var addLineErrorMessage: String?

    @State private var pendingRemoveLine: LocalRecipeItem?
    @State private var lastLineMessage: String?

    @State private var deleteRecipeConfirming = false
    @State private var deleteErrorMessage: String?

    var body: some View {
        Group {
            switch mode {
            case .create:
                createForm
            case .edit(let recipeId):
                editContent(recipeId: recipeId)
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
    /// `ingredients`/`drift` back the preview for BOTH modes; `.edit` also
    /// reloads the recipe row and its live lines via `loadEditState`.
    private func loadStoreData() {
        guard let store = appModel.store else {
            ingredients = []
            drift = [:]
            loadError = nil
            recipe = nil
            lines = []
            return
        }
        do {
            ingredients = try store.liveIngredients()
            drift = Costing.driftByIngredient(purchases: try store.allLivePurchases())
            if case .edit(let recipeId) = mode {
                try loadEditState(store: store, recipeId: recipeId)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// `recipe`/`lines` themselves are always overwritten -- they're pure
    /// reflections of the store, never user-typed. The per-field TEXT
    /// mirrors are the ones that skip a field currently under the user's
    /// finger (`focusedField`), per this file's top doc comment.
    private func loadEditState(store: LocalStore, recipeId: String) throws {
        let fetchedRecipe = try store.recipe(id: recipeId)
        let fetchedLines = try store.liveRecipeItems(recipeId: recipeId)
        recipe = fetchedRecipe
        lines = fetchedLines

        if focusedField != .name { nameText = fetchedRecipe?.name ?? "" }
        if focusedField != .menuPrice { menuPriceText = fetchedRecipe?.menu_price ?? "" }
        if focusedField != .targetFcPct { targetFcPctText = fetchedRecipe?.target_fc_pct ?? "" }

        for line in fetchedLines where focusedField != .lineQty(line.id) {
            qtyTexts[line.id] = line.qty_base_units
        }
        // Prune state for lines that are no longer live (removed here or
        // tombstoned elsewhere) so a reused id can never resurrect a stale
        // error/text after the line itself is gone.
        let liveIds = Set(fetchedLines.map(\.id))
        qtyTexts = qtyTexts.filter { liveIds.contains($0.key) }
        qtyErrors = qtyErrors.filter { liveIds.contains($0.key) }
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

    // MARK: - Edit form (Task 9)

    @ViewBuilder
    private func editContent(recipeId: String) -> some View {
        if let loadError {
            ContentUnavailableView(
                "Couldn't Load Recipe", systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if let recipe, recipe.deleted_at == nil {
            editForm(recipe: recipe, recipeId: recipeId)
        } else if recipe?.deleted_at != nil {
            // The recipe was tombstoned (here, moments ago via `deleteRecipe`
            // and `dismiss()` raced by the reload, or from another device)
            // — a stale form with no live row behind it would be worse than
            // this plain state.
            ContentUnavailableView(
                "Recipe Deleted", systemImage: "trash",
                description: Text("This recipe has been deleted."))
        } else {
            ProgressView()
        }
    }

    private func editForm(recipe: LocalRecipe, recipeId: String) -> some View {
        Form {
            editRecipeFieldsSection(recipe: recipe)
            editLinesSection
            Section("Preview") {
                PlatePreview(result: editPreviewResult, suppressSuggestions: appModel.suppressSuggestions)
            }
            if appModel.canEditRecipes {
                Section {
                    Button("Delete Recipe", role: .destructive) {
                        deleteErrorMessage = nil
                        deleteRecipeConfirming = true
                    }
                }
            }
            if let deleteErrorMessage {
                Section {
                    Text(deleteErrorMessage).foregroundStyle(.red)
                }
            }
        }
        .onSubmit {
            // The only field with a real return key (default keyboard) is
            // Name -- the decimal-pad fields have none. Dropping focus here
            // routes through the SAME `onChange(of: focusedField)` blur
            // handler below, so "return" and "blur" commit through one
            // path, not two.
            focusedField = nil
        }
        .onChange(of: focusedField) { oldValue, newValue in
            guard let oldValue, oldValue != newValue else { return }
            switch oldValue {
            case .name: commitName(recipe: recipe, recipeId: recipeId)
            case .menuPrice: commitMenuPrice(recipe: recipe, recipeId: recipeId)
            case .targetFcPct: commitTargetFcPct(recipe: recipe, recipeId: recipeId)
            case .lineQty: break  // Quantity commits on its own debounce timer, not on blur.
            }
        }
        .confirmationDialog(
            "Delete \(recipe.name)?",
            isPresented: $deleteRecipeConfirming,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteRecipe(recipeId: recipeId) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recipe and its \(lines.count) ingredient lines.")
        }
        .confirmationDialog(
            "Remove \(removeLineIngredientName)?",
            isPresented: confirmRemoveLineBinding,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingRemoveLine { removeLine(pendingRemoveLine) }
            }
            Button("Cancel", role: .cancel) { pendingRemoveLine = nil }
        }
        .alert("Can't Remove Ingredient", isPresented: lastLineAlertBinding) {
            Button("OK") {}
        } message: {
            Text(lastLineMessage ?? "")
        }
        .navigationDestination(isPresented: $addLineDestinationPresented) {
            addLineDestination(recipeId: recipeId)
        }
    }

    @ViewBuilder
    private func editRecipeFieldsSection(recipe: LocalRecipe) -> some View {
        Section("Recipe") {
            if appModel.canEditRecipes {
                TextField("Name", text: $nameText)
                    .focused($focusedField, equals: .name)
                if nameFieldInvalid {
                    Text(message(for: .nameEmpty)).font(.caption).foregroundStyle(.red)
                }
                TextField("Menu price", text: $menuPriceText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .menuPrice)
                if menuPriceFieldInvalid {
                    Text(message(for: .menuPriceInvalid)).font(.caption).foregroundStyle(.red)
                }
                TextField("Target food cost %", text: $targetFcPctText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .targetFcPct)
                if targetFcPctFieldInvalid {
                    Text(message(for: .targetFcPctInvalid)).font(.caption).foregroundStyle(.red)
                }
            } else {
                // Bookkeeper: plain text, no `TextField`, no focus, no
                // commit path at all -- reading is permitted by RLS, editing
                // is not.
                LabeledContent("Name", value: nameText.isEmpty ? "—" : nameText)
                LabeledContent("Menu price", value: menuPriceText.isEmpty ? "—" : "$\(menuPriceText)")
                LabeledContent(
                    "Target food cost %",
                    value: targetFcPctText.isEmpty ? "—" : "\(targetFcPctText)%")
            }
            if let recipeFieldsErrorMessage {
                Text(recipeFieldsErrorMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var editLinesSection: some View {
        Section("Ingredients") {
            ForEach(lines, id: \.id) { line in
                let row = EditLineRow(
                    name: ingredientsById[line.ingredient_id]?.name ?? "—",
                    baseUnit: ingredientsById[line.ingredient_id]?.base_unit,
                    qty: qtyBinding(for: line),
                    errorMessage: qtyErrors[line.id],
                    isEditable: appModel.canEditRecipes,
                    focus: $focusedField,
                    focusValue: .lineQty(line.id))
                if appModel.canEditRecipes {
                    row.swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingRemoveLine = line
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                } else {
                    row
                }
            }
            if appModel.canEditRecipes {
                Button {
                    newLineIngredient = nil
                    newLineQtyText = ""
                    addLineErrorMessage = nil
                    addLineDestinationPresented = true
                } label: {
                    Label("Add ingredient", systemImage: "plus")
                }
            }
        }
    }

    /// The picker, pushed (never a `.sheet` inside this already-pushed
    /// screen's own `.sheet` — see the create path's `addIngredientDestination`
    /// doc comment for why), plus a quantity step below it: unlike the
    /// create path's `addLine` (which just appends a blank-qty draft line),
    /// `LocalEdits.addRecipeLine` writes immediately and REQUIRES an
    /// already-positive `qty` argument, so a quantity has to be collected
    /// here, before the line can exist at all.
    private func addLineDestination(recipeId: String) -> some View {
        Form {
            IngredientPickerView(
                appModel: appModel,
                excludedIngredientIds: Set(lines.map(\.ingredient_id)),
                onPick: { ingredient in
                    newLineIngredient = ingredient
                    addLineErrorMessage = nil
                },
                onClear: { newLineIngredient = nil },
                onQueryEdited: {})
            if let newLineIngredient {
                Section("Quantity") {
                    HStack {
                        TextField("Qty", text: $newLineQtyText)
                            .keyboardType(.decimalPad)
                        Text(newLineIngredient.base_unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let addLineErrorMessage {
                        Text(addLineErrorMessage).font(.caption).foregroundStyle(.red)
                    }
                    Button("Add") { addLine(recipeId: recipeId) }
                        .disabled(newLineQtyText.isEmpty)
                }
            }
        }
        .navigationTitle("Add Ingredient")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Edit-path field commits

    /// Blur/return commit for Name: blank shows the SAME frozen string
    /// `RecipeDraft.DraftError.nameEmpty` renders on the create path and
    /// mints nothing; unchanged (compared against the STORED `recipe.name`,
    /// not against whatever the last commit happened to write) also mints
    /// nothing, per `LocalEdits.updateRecipeFields`'s own doc comment — that
    /// method diffs only "was a value supplied," never against the current
    /// row, so this view is the one place the "did it actually change"
    /// check has to live.
    private func commitName(recipe: LocalRecipe, recipeId: String) {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameFieldInvalid = true
            return
        }
        nameFieldInvalid = false
        guard trimmed != recipe.name else { return }
        commitRecipeFields(recipeId: recipeId, name: trimmed, menuPrice: nil, targetFcPct: nil)
    }

    private func commitMenuPrice(recipe: LocalRecipe, recipeId: String) {
        let trimmed = menuPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? Rational.parseDec(trimmed), value.isPositive else {
            menuPriceFieldInvalid = true
            return
        }
        menuPriceFieldInvalid = false
        guard trimmed != recipe.menu_price else { return }
        commitRecipeFields(recipeId: recipeId, name: nil, menuPrice: trimmed, targetFcPct: nil)
    }

    private func commitTargetFcPct(recipe: LocalRecipe, recipeId: String) {
        let trimmed = targetFcPctText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? Rational.parseDec(trimmed), value.isPositive else {
            targetFcPctFieldInvalid = true
            return
        }
        targetFcPctFieldInvalid = false
        guard trimmed != recipe.target_fc_pct else { return }
        commitRecipeFields(recipeId: recipeId, name: nil, menuPrice: nil, targetFcPct: trimmed)
    }

    /// Exactly one of `name`/`menuPrice`/`targetFcPct` is ever non-nil at a
    /// call site above -- each field commits independently on its OWN blur,
    /// so this never batches two changed fields into one op.
    private func commitRecipeFields(recipeId: String, name: String?, menuPrice: String?, targetFcPct: String?) {
        guard let edits = appModel.edits else { return }
        recipeFieldsErrorMessage = nil
        do {
            try edits.updateRecipeFields(id: recipeId, name: name, menuPrice: menuPrice, targetFcPct: targetFcPct)
            appModel.syncSoon()
        } catch let error as KernelError {
            recipeFieldsErrorMessage = error.message
        } catch {
            recipeFieldsErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Edit-path line quantity (debounced)

    private func qtyBinding(for line: LocalRecipeItem) -> Binding<String> {
        Binding(
            get: { qtyTexts[line.id] ?? line.qty_base_units },
            set: { newValue in
                qtyTexts[line.id] = newValue
                scheduleQtyCommit(itemId: line.id, text: newValue)
            })
    }

    /// Cancel-then-resleep, the exact shape `AppModel.syncSoon()` already
    /// uses for its own debounce: typing "0.25" restarts this 500ms timer
    /// on every keystroke, so only the LAST keystroke's timer ever survives
    /// to fire — one op, not four.
    private func scheduleQtyCommit(itemId: String, text: String) {
        qtyDebounceTasks[itemId]?.cancel()
        qtyDebounceTasks[itemId] = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commitQty(itemId: itemId, text: text)
        }
    }

    /// A blank or unparseable value shows the field error and mints
    /// NOTHING -- the last good quantity (still sitting in the store row,
    /// untouched) stands, per spec §9. Pre-validated locally with the same
    /// positivity check every other field here uses, rather than letting
    /// `updateRecipeLineQty` throw and catching its `KernelError` --
    /// keeps the exact same frozen "Quantity must be greater than zero."
    /// string the create path already shows for the equivalent case.
    ///
    /// Also skips when `text` already matches the line's STORED
    /// `qty_base_units` -- found live, not theorized: scrolling a line's
    /// `TextField` into view and tapping it to focus (no typing at all)
    /// reliably fired this Binding's `set` once with the field's own
    /// unchanged starting text, which -- absent this guard -- queued a
    /// pointless `{"qty_base_units": "2.0000"}` update op for a value that
    /// never actually changed, confirmed by reading `pending_ops` directly
    /// off the simulator's on-disk store during Task 9's own simulator
    /// walk. `updateRecipeLineQty` has no such diff built in (its own doc
    /// comment: `fields` is always exactly `{qty_base_units}` when called),
    /// so -- same as `commitName`/`commitMenuPrice`/`commitTargetFcPct`
    /// diffing against `recipe` before calling `updateRecipeFields` -- this
    /// is the one place that check can live.
    private func commitQty(itemId: String, text: String) {
        qtyDebounceTasks[itemId] = nil
        guard let edits = appModel.edits else { return }
        guard let value = try? Rational.parseDec(text), value.isPositive else {
            qtyErrors[itemId] = "Quantity must be greater than zero."
            return
        }
        qtyErrors[itemId] = nil
        guard lines.first(where: { $0.id == itemId })?.qty_base_units != text else { return }
        do {
            try edits.updateRecipeLineQty(itemId: itemId, qty: text)
            appModel.syncSoon()
        } catch let error as KernelError {
            qtyErrors[itemId] = error.message
        } catch {
            qtyErrors[itemId] = error.localizedDescription
        }
    }

    // MARK: - Edit-path add/remove line, delete recipe

    /// `IngredientPickerView`'s own `excludedIngredientIds` keeps an
    /// already-on-the-recipe ingredient out of its match/near-match/
    /// create-new results (including the create-new duplicate-adoption
    /// refusal), so `EditError.duplicate` cannot normally surface here --
    /// caught anyway rather than crashing, same defensive posture the
    /// picker's own doc comment describes for its "fix round 2".
    private func addLine(recipeId: String) {
        guard let edits = appModel.edits, let ingredient = newLineIngredient else { return }
        addLineErrorMessage = nil
        guard let value = try? Rational.parseDec(newLineQtyText), value.isPositive else {
            addLineErrorMessage = "Quantity must be greater than zero."
            return
        }
        do {
            _ = try edits.addRecipeLine(recipeId: recipeId, ingredientId: ingredient.id, qty: newLineQtyText)
            appModel.syncSoon()
            newLineIngredient = nil
            newLineQtyText = ""
            addLineDestinationPresented = false
        } catch let error as LocalEdits.EditError {
            if case .duplicate = error {
                addLineErrorMessage = "That ingredient is already on this recipe."
            }
        } catch let error as KernelError {
            addLineErrorMessage = error.message
        } catch {
            addLineErrorMessage = error.localizedDescription
        }
    }

    /// `tombstoneRecipeLine`'s own local guard runs BEFORE any op is queued
    /// (its own doc comment) -- `EditError.lastLine` here is just surfacing
    /// that guard's result as the brief's alert, never a network round trip.
    private func removeLine(_ line: LocalRecipeItem) {
        pendingRemoveLine = nil
        guard let edits = appModel.edits else { return }
        do {
            try edits.tombstoneRecipeLine(itemId: line.id)
            appModel.syncSoon()
        } catch let error as LocalEdits.EditError {
            if case .lastLine = error {
                lastLineMessage = "A recipe needs at least one ingredient. Delete the recipe instead."
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// `tombstoneRecipe` enqueues N+1 ops (every live line plus the recipe
    /// itself) in ONE transaction (its own doc comment) -- this view never
    /// enumerates lines itself for the delete, it just calls through.
    private func deleteRecipe(recipeId: String) {
        guard let edits = appModel.edits else { return }
        deleteErrorMessage = nil
        do {
            try edits.tombstoneRecipe(id: recipeId)
            appModel.syncSoon()
            dismiss()
        } catch let error as KernelError {
            deleteErrorMessage = error.message
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }

    private var removeLineIngredientName: String {
        guard let pendingRemoveLine else { return "" }
        return ingredientsById[pendingRemoveLine.ingredient_id]?.name ?? "this ingredient"
    }

    private var confirmRemoveLineBinding: Binding<Bool> {
        Binding(get: { pendingRemoveLine != nil }, set: { if !$0 { pendingRemoveLine = nil } })
    }

    private var lastLineAlertBinding: Binding<Bool> {
        Binding(get: { lastLineMessage != nil }, set: { if !$0 { lastLineMessage = nil } })
    }

    // MARK: - Edit-path preview

    /// Same `Costing.previewPlate` call the create path's `previewResult`
    /// makes, over the STORED lines but each line's LIVE `qtyTexts` entry
    /// (falling back to the stored qty for a line not currently being
    /// typed into) -- so the preview reacts to every keystroke exactly like
    /// the create path's draft preview does, even though the actual
    /// `LocalEdits` write for that keystroke is still debounced. A mid-typing
    /// unparseable qty degrades this to "no preview yet," never a crash --
    /// same `try?` reasoning as `previewResult`'s own doc comment.
    private var editPreviewResult: Costing.PreviewResult? {
        try? Costing.previewPlate(
            lines: lines.map { (ingredientId: $0.ingredient_id, qty: qtyTexts[$0.id] ?? $0.qty_base_units) },
            menuPrice: positiveDecimalOrNil(menuPriceText),
            targetFcPct: positiveDecimalOrNil(targetFcPctText),
            ingredients: ingredients, drift: drift)
    }
}

/// Field identity for the edit path's `@FocusState`, and the debounce/
/// reload-skip key for quantity edits -- `.lineQty` carries the STORED
/// `recipe_items.id`, never a view-only identity like the create path's
/// `RecipeDraft.Line.id`.
private enum EditField: Hashable {
    case name
    case menuPrice
    case targetFcPct
    case lineQty(String)
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

// MARK: - Edit-path line row

/// The edit path's line row: same visual shape as `LineRow`, plus the two
/// things the create path never needed -- a read-only rendering for a
/// bookkeeper (`isEditable`) and the line's own `focused` binding (so
/// `loadEditState` can tell this line's quantity is under the user's
/// finger and skip reseeding it out from under them). The ingredient name
/// is always plain text, never a picker -- Task 9's brief, matching web
/// (web/js/app.js:802-810): a line's ingredient is immutable over sync, so
/// changing it is remove-then-add, never offered as an in-place edit.
private struct EditLineRow: View {
    let name: String
    let baseUnit: String?
    let qty: Binding<String>
    let errorMessage: String?
    let isEditable: Bool
    let focus: FocusState<EditField?>.Binding
    let focusValue: EditField

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                if isEditable {
                    TextField("Qty", text: qty)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused(focus, equals: focusValue)
                } else {
                    Text(qty.wrappedValue)
                        .foregroundStyle(.secondary)
                }
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
