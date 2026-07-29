// The CostSauce Settings tab — Task 13's real view, replacing Task 9's
// placeholder. Four sections (location settings, plan, members entry
// point, account) plus a DEBUG-only diagnostics section.
//
// Global Constraints: money/pct values (`targetFcPct`, `driftThresholdPct`)
// are STRINGS end to end, rendered/edited verbatim -- never routed through
// Double/Float/Decimal.
//
// `AppModel.membership` (Task 9) is populated only on the SLOW bootstrap
// path (`proceedWithMembership`) -- a later launch's fast path
// (`tryFastPathToMain`) binds the store and enters `.main` WITHOUT ever
// setting it. Relying on `appModel.membership` here would leave the Plan
// section and every owner-only Members control silently missing on the
// common "device already bound" launch, which is most launches after the
// first. This file (and `MembersView`) resolve their own membership
// snapshot instead, via a fresh `/me` call matched against
// `appModel.boundOrgId` (reliably set by `attachStore` on BOTH paths) --
// falling back to `appModel.membership` only if that online call itself
// fails, so a real owner briefly offline still sees whatever the last
// bootstrap/refresh happened to cache rather than nothing at all.
//
// Identity/sign-out/switch-and-erase flows are Task 14's own screens
// (`BlockedStateViews`, per that task's brief) -- signing out here would
// flip `SessionController.state` without ever flipping `AppModel.phase`
// (nothing observes that transition yet) or clearing the in-memory
// `TokenBox`, leaving the app in a signed-out-but-still-showing-MainTabView
// limbo. The confirm dialog's wording/logic is real (frozen §13 text); its
// destructive action routes to a placeholder, same idiom `MainTabView`
// already uses for `PendingQueuePlaceholderView`/`OrgDeletedPlaceholderView`.
// Export organization data is likewise deferred to a placeholder here (Task
// 14's own org-deleted recovery screen owns the export affordance this
// project actually ships with) even though `ApiClient.exportOrg` already
// exists and is already tested -- see this task's report for the full
// reasoning.

import SwiftUI
import CostSauceKit

struct SettingsView: View {
    let appModel: AppModel

    @State private var meResponse: MeResponse?
    @State private var meLoadError: String?
    @State private var resolvedMembership: Membership?

    @State private var locationsCount: Int?
    @State private var membersCount: Int?

    @State private var signOutConfirmPresented = false
    @State private var signOutPlaceholderPresented = false
    @State private var exportPlaceholderPresented = false

    var body: some View {
        Form {
            locationSection
            planSection
            membersSection
            accountSection
            #if DEBUG
            debugSection
            #endif
        }
        .task {
            await loadAccountAndPlan()
        }
        .sheet(isPresented: $signOutPlaceholderPresented) {
            SignOutPlaceholderView()
        }
        .sheet(isPresented: $exportPlaceholderPresented) {
            ExportPlaceholderView()
        }
    }

    // MARK: - Location

    @ViewBuilder
    private var locationSection: some View {
        if let location = appModel.currentLocation {
            LocationSettingsSection(appModel: appModel, location: location)
        } else {
            // Locations don't sync through the pull loop (§5.5) --
            // `currentLocation` only ever comes from an explicit
            // `/locations` fetch (same gap `DashboardView`'s own
            // `currentLocation == nil` branch documents). Rare in
            // practice (populated at bind time on both bootstrap paths),
            // but possible right after a fresh fast-path launch before
            // `refreshOnlineData()` has landed.
            Section("Location") {
                HStack {
                    ProgressView()
                    Text("Loading your location…")
                }
            }
        }
    }

    // MARK: - Plan

    /// D9, §15: read-only rows from the bound membership's `Entitlement`.
    /// 3.1.1(a) posture -- one plain `Link`, no purchase UI, no CTA
    /// styling, no price display anywhere in this section.
    @ViewBuilder
    private var planSection: some View {
        Section("Plan") {
            if let membership = resolvedMembership {
                LabeledContent("Plan", value: membership.entitlement.plan.capitalized)
                LabeledContent(
                    "Locations",
                    value: countLine(locationsCount, of: membership.entitlement.maxLocations))
                LabeledContent(
                    "Members",
                    value: countLine(membersCount, of: membership.entitlement.maxMembers))
                if let maxInvoices = membership.entitlement.maxInvoicesPerMonth {
                    LabeledContent("Invoices per month", value: "\(maxInvoices)")
                }
                if let maxRecipes = membership.entitlement.maxRecipes {
                    LabeledContent("Recipes", value: "\(maxRecipes)")
                }
            } else if let meLoadError {
                Text(meLoadError).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            Link("Manage plan at costsauce.com", destination: URL(string: "https://costsauce.com")!)
        }
    }

    /// "N of maxX" when the live count landed, else just the limit --
    /// never blocks the whole Plan section over a best-effort count read.
    private func countLine(_ n: Int?, of limit: Int) -> String {
        guard let n else { return "— of \(limit)" }
        return "\(n) of \(limit)"
    }

    // MARK: - Members

    private var membersSection: some View {
        Section("Members") {
            NavigationLink("Manage Members") {
                MembersView(appModel: appModel)
            }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Signed in as", value: meResponse?.contactEmail ?? "—")
            Button("Sign Out", role: .destructive) {
                signOutConfirmPresented = true
            }
            if resolvedMembership?.role == "owner" {
                Button("Export Organization Data") {
                    exportPlaceholderPresented = true
                }
            }
            // Deletion initiation is deliberately absent here (Global
            // Constraints -- Phase 5 prep): no delete-account/delete-org row.
        }
        .confirmationDialog(
            "Sign Out?", isPresented: $signOutConfirmPresented, titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                signOutPlaceholderPresented = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
    }

    /// §13 verbatim for the pending-changes case; sign-out never wipes the
    /// local store either way -- the identity binding protects it.
    private var signOutMessage: String {
        guard appModel.pendingCount > 0 else {
            return "You can sign back in anytime — your local data stays on this device."
        }
        return "\(appModel.pendingCount) changes haven't synced. They'll stay on this device and sync when you sign back in."
    }

    // MARK: - Debug

    #if DEBUG
    private var debugSection: some View {
        Section("Debug") {
            LabeledContent("API Base URL") {
                TextField("http://127.0.0.1:8400", text: apiBaseURLBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
            }
            Text("Restart the app for a changed URL to take effect.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Sync Now") {
                Task { await appModel.syncEngine?.syncNow() }
            }
            LabeledContent("Cursor", value: cursorText)
            LabeledContent("Pending", value: "\(appModel.pendingCount)")
        }
    }

    /// `AppModel.resolveBaseURL()` only ever reads this key at `init` time
    /// -- `ApiClient.baseURL` is a `let`, so editing this field changes
    /// what the NEXT launch resolves to, not the running session (the
    /// caption above says as much).
    private var apiBaseURLBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "apiBaseURL") ?? "" },
            set: { UserDefaults.standard.set($0, forKey: "apiBaseURL") }
        )
    }

    private var cursorText: String {
        guard let store = appModel.store, let meta = try? store.meta() else { return "—" }
        return "\(meta.cursor)"
    }
    #endif

    // MARK: - loading

    /// One `/me` call resolves BOTH the signed-in address (Account) and
    /// this org's fresh `Membership` (Plan + Members' owner-only gate) --
    /// see the file header for why this can't just read
    /// `appModel.membership`. `locations`/`members` counts are two more
    /// online-only reads, best-effort ("—" on failure via `countLine`,
    /// never a blocking error state -- the Plan section's counts are
    /// informational, not worth interrupting Settings over).
    private func loadAccountAndPlan() async {
        do {
            let response = try await appModel.api.me()
            meResponse = response
            resolvedMembership =
                response.memberships.first(where: { $0.orgId == appModel.boundOrgId })
                ?? appModel.membership
            meLoadError = nil
        } catch let error as ApiError {
            meLoadError = error.message
            resolvedMembership = appModel.membership
        } catch {
            meLoadError = error.localizedDescription
            resolvedMembership = appModel.membership
        }

        guard let orgId = appModel.boundOrgId else { return }
        if let locations = try? await appModel.api.locations(orgId: orgId) {
            locationsCount = locations.count
        }
        if let members = try? await appModel.api.members(orgId: orgId) {
            membersCount = members.count
        }
    }
}

// MARK: - Location settings form

/// Online-only (§13): a network/transport failure shows the fixed message
/// below rather than the `ContentUnavailableView` idiom other screens use
/// for a load failure -- there's nothing to "load" here in the first place
/// (the form is pre-filled synchronously from `location`), so the form
/// stays fully visible and editable for an immediate retry rather than
/// being replaced by an error screen.
private struct LocationSettingsSection: View {
    let appModel: AppModel
    let location: LocationOut

    @State private var baseline: LocationOut?
    @State private var name = ""
    @State private var targetFcPct = ""
    @State private var driftThresholdPct = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    var body: some View {
        Section("Location") {
            TextField("Name", text: $name)
            TextField("Target FC %", text: $targetFcPct)
                .keyboardType(.decimalPad)
            TextField("Drift Threshold %", text: $driftThresholdPct)
                .keyboardType(.decimalPad)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(isSaving || !hasChanges)
                if isSaving {
                    ProgressView()
                }
            }
        }
        // Keyed on `location.id` (stable for this device's whole session),
        // not the whole `location` value -- a later `refreshOnlineData()`
        // landing a fresh `LocationOut` for the SAME id must not clobber
        // in-progress edits. `seed(from:)` is also called directly from
        // `save()`'s success path, which is what keeps `baseline` current
        // after a save without needing this task to re-run.
        .task(id: location.id) {
            seed(from: location)
        }
    }

    private func seed(from location: LocationOut) {
        baseline = location
        name = location.name
        targetFcPct = location.targetFcPct
        driftThresholdPct = location.driftThresholdPct
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedFc: String { targetFcPct.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDrift: String {
        driftThresholdPct.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        guard let baseline else { return false }
        return trimmedName != baseline.name || trimmedFc != baseline.targetFcPct
            || trimmedDrift != baseline.driftThresholdPct
    }

    /// Only the CHANGED fields are sent (unchanged -> nil -> omitted from
    /// the PATCH body, `ApiClient.patchLocation`'s own contract); nothing
    /// changed -> no request at all, guarded by `hasChanges` both here and
    /// on the Save button itself.
    private func save() async {
        guard let baseline, hasChanges else { return }
        isSaving = true
        errorMessage = nil
        savedMessage = nil
        defer { isSaving = false }
        do {
            let updated = try await appModel.api.patchLocation(
                id: baseline.id,
                name: trimmedName != baseline.name ? trimmedName : nil,
                targetFcPct: trimmedFc != baseline.targetFcPct ? trimmedFc : nil,
                driftThresholdPct: trimmedDrift != baseline.driftThresholdPct ? trimmedDrift : nil)
            appModel.applyLocationUpdate(updated)
            seed(from: updated)
            savedMessage = "Saved."
        } catch let error as ApiError {
            errorMessage = error.status == 403 ? "Owner or manager required." : error.message
        } catch {
            errorMessage = "You're offline — settings need a connection."
        }
    }
}

// MARK: - placeholders (Task 14 territory -- see file header)

private struct SignOutPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Sign Out", systemImage: "rectangle.portrait.and.arrow.right",
            description: Text("The full sign-out flow arrives in a later task."))
    }
}

private struct ExportPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Export Organization Data", systemImage: "square.and.arrow.up",
            description: Text("Exporting costsauce-export.zip arrives in a later task."))
    }
}
