// The CostSauce main tab shell — Dashboard / Ingredients / Add / Settings.
// Dashboard is Task 10's real view; Ingredients is Task 11's real view
// (list + push-navigated detail); Add is Task 12's real view (purchase
// entry with local fuzzy pick); Settings' content is still a placeholder
// standing in for Task 13's real view. Every tab carries the sync status
// chip in its toolbar (§13). The Settings tab badges `pendingCount`, the
// chip routes to a re-auth sheet or a pending-queue placeholder depending
// on `SyncState`, and an org-deleted sync state auto-presents a
// full-screen placeholder — all three are real screens/flows only from
// Task 14 onward; see this task's report for the hand-off notes.

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
            Tab("Settings", systemImage: "gearshape") {
                TabRootView(title: "Settings", appModel: appModel, reauthPresented: $reauthPresented) {
                    ContentUnavailableView(
                        "Settings", systemImage: "gearshape",
                        description: Text("Arrives in a later task."))
                }
            }
            .badge(appModel.pendingCount > 0 ? appModel.pendingCount : 0)
        }
        .sheet(isPresented: $reauthPresented) {
            ReauthSheet(appModel: appModel, isPresented: $reauthPresented)
        }
        .fullScreenCover(isPresented: orgDeletedBinding) {
            OrgDeletedPlaceholderView()
        }
    }

    /// `.blocked(.orgDeleted)` auto-presents (Task 14 builds the real
    /// screen with export/erase actions) — no dismiss action is wired
    /// here on purpose, matching the placeholder's "no actions yet" scope.
    private var orgDeletedBinding: Binding<Bool> {
        Binding(
            get: { appModel.syncState == .blocked(.orgDeleted) },
            set: { _ in }
        )
    }
}

/// One tab's own `NavigationStack` + navigation title + sync chip
/// toolbar + the chip's non-auth tap destination (a placeholder standing
/// in for Task 14's `PendingQueueView`). Each tab gets its own instance,
/// so each keeps independent push-navigation state.
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
                    PendingQueuePlaceholderView()
                }
        }
    }
}

private struct PendingQueuePlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Pending Changes",
            systemImage: "tray",
            description: Text("The full pending-changes queue arrives in a later task.")
        )
    }
}

/// `.blocked(.authRequired)` (or `SessionController.needsReauth`, the same
/// underlying signal) reuses `LoginView`'s form. This task's version adopts
/// the new session and re-syncs; Task 14 additionally compares the new
/// session's userId against the bound store's identity and routes to an
/// identity-mismatch screen on a mismatch.
private struct ReauthSheet: View {
    let appModel: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            LoginView(appModel: appModel) { session in
                appModel.completeReauth(session: session)
                isPresented = false
            }
            .navigationTitle("Sign In Again")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

private struct OrgDeletedPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Organization Deleted",
            systemImage: "trash",
            description: Text("This organization is scheduled for deletion. Recovery and export options arrive in a later task.")
        )
    }
}
