// The CostSauce main tab shell — Dashboard / Ingredients / Add / Settings.
// Dashboard is Task 10's real view; Ingredients is Task 11's real view
// (list + push-navigated detail); Add is Task 12's real view (purchase
// entry with local fuzzy pick); Settings is Task 13's real view (location
// settings, plan surface, members, account). Every tab carries the sync
// status chip in its toolbar (§13). The Settings tab badges `pendingCount`,
// the chip routes to a re-auth sheet (`ReauthSheetView`) or the pending
// queue (`PendingQueueView`) depending on `SyncState`, and an org-deleted
// sync state auto-presents a full-screen recovery view (`OrgDeletedView`)
// — all three are Task 14's real screens, in `BlockedStateViews.swift`/
// `PendingQueueView.swift` (Task 9's placeholders stood in for them here).

import SwiftUI
import CostSauceKit

struct MainTabView: View {
    let appModel: AppModel
    @State private var reauthPresented = false

    var body: some View {
        TabView {
            Tab("Dashboard", systemImage: "chart.bar") {
                TabRootView(title: "Dashboard", appModel: appModel, reauthPresented: $reauthPresented) {
                    DashboardView(appModel: appModel)
                }
            }
            Tab("Ingredients", systemImage: "carrot") {
                TabRootView(title: "Ingredients", appModel: appModel, reauthPresented: $reauthPresented) {
                    IngredientsListView(appModel: appModel)
                }
            }
            Tab("Add", systemImage: "plus.circle") {
                TabRootView(title: "Add", appModel: appModel, reauthPresented: $reauthPresented) {
                    PurchaseEntryView(appModel: appModel)
                }
            }
            Tab("Invoices", systemImage: "doc.viewfinder") {
                TabRootView(title: "Invoices", appModel: appModel, reauthPresented: $reauthPresented) {
                    InvoiceListView(appModel: appModel)
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                TabRootView(title: "Settings", appModel: appModel, reauthPresented: $reauthPresented) {
                    SettingsView(appModel: appModel)
                }
            }
            .badge(appModel.pendingCount > 0 ? appModel.pendingCount : 0)
        }
        .sheet(isPresented: $reauthPresented) {
            ReauthSheetView(appModel: appModel, isPresented: $reauthPresented)
        }
        .fullScreenCover(isPresented: orgDeletedBinding) {
            OrgDeletedView(appModel: appModel)
        }
    }

    /// `.blocked(.orgDeleted)` auto-presents `OrgDeletedView` — no dismiss
    /// action is wired here; that view's own actions (export/erase) are
    /// what get the user out of this state (erasing routes `phase` back
    /// to `.login` via `AppModel.eraseDeviceAndSignOut`, which dismisses
    /// this cover as a side effect of `MainTabView` no longer rendering).
    private var orgDeletedBinding: Binding<Bool> {
        Binding(
            get: { appModel.syncState == .blocked(.orgDeleted) },
            set: { _ in }
        )
    }
}

/// One tab's own `NavigationStack` + navigation title + sync chip
/// toolbar + the chip's non-auth tap destination (Task 14's real
/// `PendingQueueView`). Each tab gets its own instance, so each keeps
/// independent push-navigation state.
private struct TabRootView<Content: View>: View {
    let title: String
    let appModel: AppModel
    @Binding var reauthPresented: Bool
    @State private var pendingQueuePresented = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SyncStatusChip(
                            state: appModel.syncState,
                            pendingCount: appModel.pendingCount
                        ) {
                            if case .blocked(.authRequired) = appModel.syncState {
                                reauthPresented = true
                            } else {
                                pendingQueuePresented = true
                            }
                        }
                    }
                }
                .navigationDestination(isPresented: $pendingQueuePresented) {
                    PendingQueueView(appModel: appModel)
                }
        }
    }
}
