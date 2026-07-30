// The CostSauce §13 blocked-state flows — replaces Task 9's three
// placeholders (`MainTabView`'s private `ReauthSheet`/
// `OrgDeletedPlaceholderView`, `CostSauceApp`'s `IdentityMismatchPlaceholderView`)
// with the real screens. Every destructive action here routes through a
// dedicated `AppModel` method (`switchAccountAndErase`/
// `eraseDeviceAndSignOut`/`signOut`) — this file only collects
// confirmation and renders state; the actual disk/session mutation lives
// in `AppModel.swift`, the one place app-target code is allowed to hold
// state and orchestration.
//
// §13 binds all three: 401 → hold the queue + offer re-auth; 410 → freeze
// writes, offer export, wipe only on an explicit confirm; an identity
// switch → refuse to flush, offer export, require an explicit typed
// "switch and erase". No path here can destroy local data without an
// explicit user confirmation — see this task's report for the full walk.

import SwiftUI
import CostSauceKit

// MARK: - re-auth sheet (.authRequired / SessionController.needsReauth)

/// `AppModel.completeReauth` does the actual same-identity-adopt-and-sync
/// vs. different-identity-mismatch branching (a Task 9 review fix); this
/// view only supplies the brief's reassurance line ahead of `LoginView`'s
/// own form and the sheet chrome. Reused from both `MainTabView` (the
/// chip's `.blocked(.authRequired)` tap) and anywhere else `SessionController
/// .needsReauth` needs the same recovery surface.
struct ReauthSheetView: View {
    let appModel: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Your session expired. Your data is safe on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                LoginView(appModel: appModel) { session in
                    appModel.completeReauth(session: session)
                    isPresented = false
                }
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

// MARK: - identity mismatch (AppModel.Phase.identityMismatch)

/// §13's "identity switch → refuse flush, offer export, explicit 'switch
/// and erase'" — reached from BOTH `AppModel.bindAndEnterMain` (a fresh
/// sign-in whose session doesn't match this device's existing store) and
/// `AppModel.completeReauth` (a re-auth that authenticates as someone
/// else). `AppModel.mismatchedStore` is the conflicting store already on
/// this device for either path — export and erase both read/act on THAT,
/// never `appModel.store` (which is `nil` on the `bindAndEnterMain` path;
/// see that method's doc comment).
struct IdentityMismatchView: View {
    let appModel: AppModel

    @State private var eraseSheetPresented = false
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This device holds unsynced changes for a different account.")
                }
                Section {
                    exportButton
                }
                Section {
                    Button("Switch Account and Erase", role: .destructive) {
                        eraseSheetPresented = true
                    }
                    Button("Cancel") {
                        appModel.signOut()
                    }
                }
            }
            .navigationTitle("Different Account")
            .alert("Export Failed", isPresented: exportErrorBinding) {
                Button("OK") {}
            } message: {
                Text(exportError ?? "")
            }
            .sheet(isPresented: $eraseSheetPresented) {
                TypedEraseConfirmationSheet(
                    title: "Switch Account and Erase",
                    message: "This permanently deletes this device's unsynced changes for the previous account so you can continue signing in. This can't be undone.",
                    isPresented: $eraseSheetPresented
                ) {
                    appModel.switchAccountAndErase()
                }
            }
        }
    }

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
        guard let mismatchedStore = appModel.mismatchedStore else { return }
        do {
            let data = try mismatchedStore.exportPendingOps()
            exportURL = try PendingOpsExport.write(data)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }
}

/// The identity-mismatch screen's one "type ERASE to confirm" gate — the
/// brief's own stricter-than-usual bar for this specific action ("user
/// must type 'ERASE'"), distinct from every other destructive action in
/// this app (a plain `confirmationDialog`), because this one is the only
/// one that can discard ANOTHER account's still-unexported local data.
private struct TypedEraseConfirmationSheet: View {
    let title: String
    let message: String
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(message)
                }
                Section {
                    TextField("Type ERASE to confirm", text: $typed)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Button(title, role: .destructive) {
                        isPresented = false
                        onConfirm()
                    }
                    .disabled(typed != "ERASE")
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

// MARK: - org deleted (SyncState.blocked(.orgDeleted))

/// §6.2's "freeze writes, offer export, wipe only on explicit confirm" —
/// this state is a `syncState` value, not a `phase`, so `appModel.store`
/// stays attached the whole time (only the sync engine's PUSH is
/// blocked); export and erase both operate on it directly. Role
/// resolution mirrors `SettingsView`/`MembersView`'s own pattern (a fresh
/// `/me` matched against `boundOrgId`, never `appModel.membership` — see
/// `SettingsView.swift`'s file header for why) — GET requests keep
/// working through the grace window even though sync PUSH now 410s, so
/// this call is expected to succeed.
struct OrgDeletedView: View {
    let appModel: AppModel

    @State private var resolvedMembership: Membership?
    @State private var pendingExportURL: URL?
    @State private var pendingExportError: String?
    @State private var orgExportBusy = false
    @State private var orgExportURL: URL?
    @State private var orgExportError: String?
    @State private var eraseConfirmPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This organization is scheduled for deletion.")
                }
                Section {
                    pendingExportRow
                }
                if resolvedMembership?.role == "owner" {
                    Section {
                        orgExportRow
                    }
                }
                Section {
                    Button("Erase This Device's Copy", role: .destructive) {
                        eraseConfirmPresented = true
                    }
                }
            }
            .navigationTitle("Organization Deleted")
            .task {
                await loadMembership()
            }
            .confirmationDialog(
                "Erase this device's copy?",
                isPresented: $eraseConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("Erase", role: .destructive) {
                    appModel.eraseDeviceAndSignOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes every unsynced change on this device. This can't be undone.")
            }
        }
    }

    // MARK: - export pending (local queue)

    @ViewBuilder
    private var pendingExportRow: some View {
        if let pendingExportURL {
            ShareLink(item: pendingExportURL) {
                Label("Export Pending Changes", systemImage: "square.and.arrow.up")
            }
        } else {
            Button {
                exportPending()
            } label: {
                Label("Export Pending Changes", systemImage: "square.and.arrow.up")
            }
        }
        if let pendingExportError {
            Text(pendingExportError).foregroundStyle(.red)
        }
    }

    private func exportPending() {
        pendingExportError = nil
        guard let store = appModel.store else { return }
        do {
            let data = try store.exportPendingOps()
            pendingExportURL = try PendingOpsExport.write(data)
        } catch {
            pendingExportError = error.localizedDescription
        }
    }

    // MARK: - export organization (owner, server-side)

    /// Owner-only, org-wide ZIP export (distinct from the local
    /// pending-op queue above) — identical idiom to `SettingsView.
    /// exportOrganizationData`: `ApiClient.exportOrg` (Task 7, already
    /// tested) is a stateless GET with no session/identity side effects,
    /// still reachable through the §6.2 grace window.
    @ViewBuilder
    private var orgExportRow: some View {
        if let orgExportURL {
            ShareLink(item: orgExportURL) {
                Label("Export Organization Data", systemImage: "square.and.arrow.up")
            }
        } else {
            Button("Export Organization Data") {
                Task { await exportOrganizationData() }
            }
            .disabled(orgExportBusy)
        }
        if orgExportBusy {
            ProgressView()
        }
        if let orgExportError {
            Text(orgExportError).foregroundStyle(.red)
        }
    }

    private func exportOrganizationData() async {
        guard let orgId = appModel.boundOrgId else { return }
        orgExportBusy = true
        orgExportError = nil
        defer { orgExportBusy = false }
        do {
            let data = try await appModel.api.exportOrg(orgId: orgId)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("costsauce-export.zip")
            try data.write(to: url, options: .atomic)
            orgExportURL = url
        } catch let error as ApiError {
            orgExportError = error.message
        } catch {
            orgExportError = error.localizedDescription
        }
    }

    // MARK: - role resolution

    /// Same `/me`-resolves-a-fresh-`Membership`-for-`boundOrgId` shape
    /// `SettingsView`/`MembersView` use, found by the same grep for
    /// `api.me()` across `ios/CostSauce/` that turned those two up — so it
    /// gets the identical `AppModel.recordCallerRole` write-back on a
    /// resolved match. In practice this rarely fires: this screen only
    /// shows once the org has been deleted server-side, so `/me`'s
    /// memberships list has usually already stopped including it by the
    /// time this runs. During the §6.2 grace window it still could, and the
    /// role snapshot's own rule is "every successful /me that resolves a
    /// membership for boundOrgId," not "every one except this view."
    private func loadMembership() async {
        guard let orgId = appModel.boundOrgId else {
            resolvedMembership = appModel.membership
            return
        }
        do {
            let response = try await appModel.api.me()
            if let freshMembership = response.memberships.first(where: { $0.orgId == orgId }) {
                resolvedMembership = freshMembership
                appModel.recordCallerRole(freshMembership.role, orgId: orgId)
            } else {
                resolvedMembership = appModel.membership
            }
        } catch {
            resolvedMembership = appModel.membership
        }
    }
}
