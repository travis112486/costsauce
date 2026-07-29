// The CostSauce pending-changes queue — replaces Task 9's placeholder,
// pushed from the sync status chip's tap (any non-`.authRequired` state)
// and from the Settings tab's badge. Two sections over the SAME
// `PendingOp` rows `LocalStore.pendingOps(state:)` already exposes
// (Task 5): "Waiting to sync" (`.queued` — will resolve on the next
// successful sync, no action needed) and "Needs attention"
// (`.needsAttention` — `SyncEngine.apply(_:to:)`'s doc comment is explicit
// this state is terminal and never retried automatically; this screen is
// what "resolves it"). The toolbar's "Export pending changes" affordance
// (§13's export-before-loss contract) is available regardless of which
// section is empty — it's attached to `content`, not to either section,
// so it survives the empty-queue state too.
//
// Global Constraints: every summary/reason string below is rendered
// VERBATIM from `PendingOp.fields`/`reason` — never reformatted, never
// routed through Double/Float/Decimal (money/qty/pct are strings
// end-to-end).

import SwiftUI
import CostSauceKit

struct PendingQueueView: View {
    let appModel: AppModel

    @State private var queued: [PendingOp] = []
    @State private var needsAttention: [PendingOp] = []
    @State private var pendingDiscard: PendingOp?
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        content
            .navigationTitle("Pending Changes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    exportButton
                }
            }
            .confirmationDialog(
                "Discard this change?",
                isPresented: discardConfirmBinding,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    if let pendingDiscard { discard(pendingDiscard) }
                }
                Button("Cancel", role: .cancel) {
                    pendingDiscard = nil
                }
            } message: {
                Text("The local value stays until the next sync refreshes it from the server.")
            }
            .alert("Export Failed", isPresented: exportErrorBinding) {
                Button("OK") {}
            } message: {
                Text(exportError ?? "")
            }
            .task(id: RefreshKey(appModel: appModel)) {
                load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if queued.isEmpty && needsAttention.isEmpty {
            ContentUnavailableView(
                "All Synced", systemImage: "checkmark.circle",
                description: Text("Nothing is waiting to sync."))
        } else {
            List {
                if !queued.isEmpty {
                    Section("Waiting to sync") {
                        ForEach(queued, id: \.op_id) { op in
                            Text(summary(for: op))
                        }
                    }
                }
                if !needsAttention.isEmpty {
                    Section("Needs attention") {
                        ForEach(needsAttention, id: \.op_id) { op in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary(for: op))
                                Text(reasonText(for: op))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDiscard = op
                                } label: {
                                    Label("Discard", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - export

    @ViewBuilder
    private var exportButton: some View {
        if let exportURL {
            ShareLink(item: exportURL) {
                Label("Export Pending Changes", systemImage: "square.and.arrow.up")
            }
        } else {
            Button {
                exportPending()
            } label: {
                Label("Export Pending Changes", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func exportPending() {
        exportError = nil
        guard let store = appModel.store else { return }
        do {
            let data = try store.exportPendingOps()
            exportURL = try PendingOpsExport.write(data)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    // MARK: - discard

    private var discardConfirmBinding: Binding<Bool> {
        Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } })
    }

    /// `deleteOp` (Task 5, already tested) is the resolution `SyncEngine`'s
    /// own doc comment on `needs_attention` points at. `syncSoon()` both
    /// refreshes `pendingCount` immediately (so the chip/badge and this
    /// screen's own `RefreshKey` reflect the discard right away) and
    /// kicks a debounced sync for whatever else is still queued — same
    /// idiom `IngredientsListView.delete`/`PurchaseEntryView` use after
    /// every local write.
    private func discard(_ op: PendingOp) {
        pendingDiscard = nil
        try? appModel.store?.deleteOp(opId: op.op_id)
        appModel.syncSoon()
    }

    // MARK: - loading

    private func load() {
        guard let store = appModel.store else {
            queued = []
            needsAttention = []
            return
        }
        queued = (try? store.pendingOps(state: .queued)) ?? []
        needsAttention = (try? store.pendingOps(state: .needsAttention)) ?? []
    }

    // MARK: - summaries

    /// "table + kind + a salient field" per the brief's three frozen
    /// examples: `"New purchase — 2026-07-29"` (insert, `purchased_on`),
    /// `"New ingredient — Brisket"` (insert, `name`), `"Delete purchase"`
    /// (a tombstone update — `fields == {deleted_at}`, no salient value to
    /// show). `LocalEdits` (Task 6) only ever mints these four shapes
    /// (`createIngredient`/`createPurchase`/`tombstonePurchase`/
    /// `tombstoneIngredient`), so a tombstone is always identifiable by
    /// `fields` containing `deleted_at` regardless of table.
    private func summary(for op: PendingOp) -> String {
        let noun = singularTableName(op.table)
        if op.fields.keys.contains("deleted_at") {
            return "Delete \(noun)"
        }
        let verb = op.kind == .insert ? "New" : "Update"
        if let salient = salientValue(for: op), !salient.isEmpty {
            return "\(verb) \(noun) — \(salient)"
        }
        return "\(verb) \(noun)"
    }

    private func salientValue(for op: PendingOp) -> String? {
        switch op.table {
        case "purchases":
            return op.fields["purchased_on"] ?? nil
        case "ingredients":
            return op.fields["name"] ?? nil
        default:
            return nil
        }
    }

    private func singularTableName(_ table: String) -> String {
        switch table {
        case "ingredients": return "ingredient"
        case "purchases": return "purchase"
        case "recipes": return "recipe"
        case "recipe_items": return "recipe item"
        default: return table
        }
    }

    /// CS425: a `client_mutated_at`-related server rejection is very often
    /// caused by this device's own clock being wrong (skewed relative to
    /// the server) — surfaced as a concrete next step rather than leaving
    /// the raw server reason as the only guidance.
    private func reasonText(for op: PendingOp) -> String {
        let reason = op.reason ?? "needs attention"
        guard reason.contains("client_mutated_at") else { return reason }
        return reason + " Check this device's clock."
    }
}

/// What `.task(id:)` reruns `load()` on — same `syncState`/`pendingCount`
/// pair `IngredientsListView.RefreshKey`/`DashboardView.RefreshKey` use,
/// so a discard, a newly-queued edit, or a state transition (e.g.
/// `needs_attention` landing after a push) all refresh this screen without
/// a dedicated observation layer over `pending_ops`.
private struct RefreshKey: Equatable {
    let syncState: SyncState
    let pendingCount: Int

    @MainActor
    init(appModel: AppModel) {
        syncState = appModel.syncState
        pendingCount = appModel.pendingCount
    }
}

/// Shared by `PendingQueueView` and `BlockedStateViews`' export
/// affordances: writes export `Data` to a fixed `costsauce-pending.json`
/// temp path and returns its URL. `ShareLink(item: URL)` over a LOCAL file
/// shares the file's actual bytes with that filename as the suggested
/// name (same idiom `SettingsView.exportOrganizationData` already uses
/// for its `costsauce-export.zip`), rather than needing a dedicated
/// `Transferable` wrapper just to carry `Data` plus a filename.
enum PendingOpsExport {
    static func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("costsauce-pending.json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
