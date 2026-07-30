// A new recipe composed in memory, before it becomes rows plus sync ops.
//
// Phase 2b's hybrid edit model: a NEW recipe lives entirely as a
// `RecipeDraft` while the user is composing it, and only becomes local rows
// plus a `PendingOp` batch when they tap Save (`LocalEdits.saveNewRecipe`,
// in LocalEdits.swift). An EXISTING recipe's edits apply immediately, via
// `LocalEdits.updateRecipeFields`/`addRecipeLine`/`updateRecipeLineQty`/
// `tombstoneRecipeLine` -- this type has nothing to do with that half.
//
// `validate()` is the phase's specification of what a well-formed recipe
// is: it is PURE (no store access, no I/O), lives in the Kit rather than
// the SwiftUI view because the app target has no unit-test harness, and is
// the ONLY place these rules may live -- the editor view (Task 8) renders
// its errors but must never re-implement them.

import Foundation

public struct RecipeDraft: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        /// View identity ONLY -- never persisted. A draft line has no
        /// server-side id until `saveNewRecipe` mints one at Save time.
        public let id: UUID
        public var ingredientId: String
        public var qty: String

        public init(ingredientId: String, qty: String) {
            self.id = UUID()
            self.ingredientId = ingredientId
            self.qty = qty
        }
    }

    public var name: String
    public var menuPrice: String
    public var targetFcPct: String
    /// PRESENTATION ONLY (spec §6): the array's order is never persisted --
    /// there is no order column on `recipe_items`, and stored reads always
    /// come back ordered by ingredient name.
    public var lines: [Line]

    public init(
        name: String = "", menuPrice: String = "",
        targetFcPct: String = "30.00", lines: [Line] = []
    ) {
        self.name = name
        self.menuPrice = menuPrice
        self.targetFcPct = targetFcPct
        self.lines = lines
    }

    public enum DraftError: Error, Equatable {
        case nameEmpty
        case menuPriceInvalid
        case targetFcPctInvalid
        case noLines
        case lineQtyInvalid(lineId: UUID)
        case duplicateIngredient(ingredientId: String)
    }

    /// PURE -- no store, no view state. Returns ALL failures, in the enum's
    /// declaration order above, so the editor can mark every bad field at
    /// once rather than fixing one error at a time. `menuPrice`/
    /// `targetFcPct` need only be a positive `Rational` -- a value with
    /// more decimals than its column (e.g. "18.005") is accepted verbatim
    /// here; the server's `numeric` column is the authority on precision,
    /// same as how purchase totals already behave.
    public func validate() -> [DraftError] {
        var errors: [DraftError] = []

        if Kernel.normalizeName(name).isEmpty {
            errors.append(.nameEmpty)
        }
        if !Self.isPositiveDecimal(menuPrice) {
            errors.append(.menuPriceInvalid)
        }
        if !Self.isPositiveDecimal(targetFcPct) {
            errors.append(.targetFcPctInvalid)
        }
        if lines.isEmpty {
            errors.append(.noLines)
        }
        for line in lines where !Self.isPositiveDecimal(line.qty) {
            errors.append(.lineQtyInvalid(lineId: line.id))
        }
        var seenIngredientIds: Set<String> = []
        for line in lines where !seenIngredientIds.insert(line.ingredientId).inserted {
            errors.append(.duplicateIngredient(ingredientId: line.ingredientId))
        }

        return errors
    }

    private static func isPositiveDecimal(_ s: String) -> Bool {
        (try? Rational.parseDec(s))?.isPositive ?? false
    }
}
