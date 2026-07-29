// The CostSauce Members screen — pushed from `SettingsView`'s "Manage
// Members" row. Online-only throughout: the roster and every mutation
// (`setRole`/`removeMember`/`invite`/`acceptInvite`) go straight through
// `AppModel.api`, never `LocalEdits` -- there is no local-store read or
// write anywhere in this file.
//
// Owner-only controls (role menu / swipe-remove / invite form) gate on a
// freshly-resolved caller role for `appModel.boundOrgId`, NOT
// `appModel.membership` -- see `SettingsView.swift`'s file header for why
// (`AppModel`'s fast bootstrap path never populates `membership`, so most
// launches after the first would otherwise hide every owner control even
// for a real owner).

import SwiftUI
import CostSauceKit

struct MembersView: View {
    let appModel: AppModel

    @State private var members: [MemberOut] = []
    @State private var loadError: String?
    @State private var isOwner = false

    @State private var roleChangeError: String?
    @State private var removeError: String?

    @State private var inviteEmail = ""
    // "Bookkeeper" (this app's own day-to-day purchase-entry role) rather
    // than "owner" as the default pick -- inviting someone should never
    // silently hand out ownership by default.
    @State private var inviteRole = "bookkeeper"
    @State private var inviteBusy = false
    @State private var inviteError: String?
    @State private var inviteToken: String?
    @State private var inviteInfoMessage: String?

    @State private var acceptToken = ""
    @State private var acceptBusy = false
    @State private var acceptError: String?
    @State private var acceptSuccess: String?

    /// `api/routes/members.py`'s `ROLES` tuple, verbatim order.
    private let roleChoices = ["owner", "manager", "bookkeeper"]

    var body: some View {
        List {
            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                    Button("Try Again") { Task { await load() } }
                }
            }
            rosterSection
            if isOwner {
                inviteSection
            }
            acceptInviteSection
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .alert("Couldn't Change Role", isPresented: errorAlertBinding($roleChangeError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(roleChangeError ?? "")
        }
        .alert("Couldn't Remove Member", isPresented: errorAlertBinding($removeError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removeError ?? "")
        }
        .alert("Couldn't Send Invite", isPresented: errorAlertBinding($inviteError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inviteError ?? "")
        }
    }

    private func errorAlertBinding(_ value: Binding<String?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    // MARK: - roster

    private var rosterSection: some View {
        Section("Members") {
            ForEach(members) { member in
                MemberRow(
                    member: member,
                    isCaller: member.userId == callerUserId,
                    isOwner: isOwner,
                    roleChoices: roleChoices,
                    onSetRole: { role in Task { await setRole(member: member, role: role) } }
                )
                .swipeActions(edge: .trailing) {
                    if isOwner {
                        Button(role: .destructive) {
                            Task { await removeMember(member) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var callerUserId: String? {
        if case .active(let session) = appModel.session.state {
            return session.userId
        }
        return nil
    }

    // MARK: - invite (owner-only)

    @ViewBuilder
    private var inviteSection: some View {
        Section("Invite a Member") {
            TextField("Email", text: $inviteEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Picker("Role", selection: $inviteRole) {
                ForEach(roleChoices, id: \.self) { role in
                    Text(role.capitalized).tag(role)
                }
            }
            Button("Send Invite") {
                Task { await sendInvite() }
            }
            .disabled(trimmedInviteEmail.isEmpty || inviteBusy)
            if inviteBusy {
                ProgressView()
            }
            // `token` is non-nil only when the server's own
            // RETURN_INVITE_TOKEN_ENABLED env flag is on
            // (api/routes/members.py) -- until Phase 3 wires real email
            // delivery, that's the ONLY channel a token reaches anyone
            // through, so a nil token isn't an error, just "recorded, not
            // deliverable yet."
            if let inviteToken {
                ShareLink(item: inviteToken) {
                    Label("Share Invite Code", systemImage: "square.and.arrow.up")
                }
            } else if let inviteInfoMessage {
                Text(inviteInfoMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedInviteEmail: String {
        inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - accept invite (any role)

    private var acceptInviteSection: some View {
        Section("Have an invite code?") {
            TextField("Invite code", text: $acceptToken)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Accept Invite") {
                Task { await acceptInviteTapped() }
            }
            .disabled(trimmedAcceptToken.isEmpty || acceptBusy)
            if acceptBusy {
                ProgressView()
            }
            if let acceptError {
                Text(acceptError).foregroundStyle(.red)
            }
            if let acceptSuccess {
                Label(acceptSuccess, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var trimmedAcceptToken: String {
        acceptToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - loading / mutations

    /// Roster + caller role come from two separate calls (`members` has no
    /// per-row "is this the caller's own role at owner level" signal) --
    /// see the file header for why the role read is a fresh `/me`, not
    /// `appModel.membership`.
    private func load() async {
        guard let orgId = appModel.boundOrgId else {
            members = []
            isOwner = false
            loadError = nil
            return
        }
        do {
            members = try await appModel.api.members(orgId: orgId)
            let me = try await appModel.api.me()
            let role = me.memberships.first(where: { $0.orgId == orgId })?.role
                ?? appModel.membership?.role
            isOwner = role == "owner"
            loadError = nil
        } catch let error as ApiError {
            loadError = error.message
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func setRole(member: MemberOut, role: String) async {
        guard let orgId = appModel.boundOrgId else { return }
        do {
            _ = try await appModel.api.setRole(orgId: orgId, userId: member.userId, role: role)
            await load()
        } catch let error as ApiError {
            // 409 last-owner (and anything else the server reports) shown
            // verbatim -- the brief's own frozen requirement.
            roleChangeError = error.message
        } catch {
            roleChangeError = error.localizedDescription
        }
    }

    private func removeMember(_ member: MemberOut) async {
        guard let orgId = appModel.boundOrgId else { return }
        do {
            try await appModel.api.removeMember(orgId: orgId, userId: member.userId)
            await load()
        } catch let error as ApiError {
            removeError = error.message
        } catch {
            removeError = error.localizedDescription
        }
    }

    private func sendInvite() async {
        guard let orgId = appModel.boundOrgId else { return }
        let email = trimmedInviteEmail
        guard !email.isEmpty else { return }
        inviteBusy = true
        inviteToken = nil
        inviteInfoMessage = nil
        defer { inviteBusy = false }
        do {
            let result = try await appModel.api.invite(orgId: orgId, email: email, role: inviteRole)
            if let token = result.token {
                inviteToken = token
            } else {
                inviteInfoMessage =
                    "Invite recorded. Invite emails aren't wired up yet — share the token from an admin session."
            }
            inviteEmail = ""
        } catch let error as ApiError {
            // 402 plan-limit (and anything else the server reports) shown
            // verbatim -- the brief's own frozen requirement.
            inviteError = error.message
        } catch {
            inviteError = error.localizedDescription
        }
    }

    /// `acceptInvite` succeeding is the real action; the trailing `/me`
    /// refetch is best-effort (`try?`) per the brief's own
    /// "-> acceptInvite -> refetch /me" -- a failure there doesn't undo or
    /// re-alert on top of an already-successful accept.
    private func acceptInviteTapped() async {
        let token = trimmedAcceptToken
        guard !token.isEmpty else { return }
        acceptBusy = true
        acceptError = nil
        acceptSuccess = nil
        defer { acceptBusy = false }
        do {
            let result = try await appModel.api.acceptInvite(token: token)
            _ = try? await appModel.api.me()
            acceptToken = ""
            acceptSuccess = "Joined as \(result.role)."
            await load()
        } catch let error as ApiError {
            acceptError = error.message
        } catch {
            acceptError = error.localizedDescription
        }
    }
}

// MARK: - row

private struct MemberRow: View {
    let member: MemberOut
    let isCaller: Bool
    let isOwner: Bool
    let roleChoices: [String]
    let onSetRole: (String) -> Void

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text(member.contactEmail ?? "member")
                if isCaller {
                    Text("(you)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isOwner {
                Menu {
                    ForEach(roleChoices, id: \.self) { role in
                        Button(role.capitalized) { onSetRole(role) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(member.role.capitalized)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(member.role.capitalized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
