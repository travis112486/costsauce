// The CostSauce app shell's model — owns every piece Tasks 3-8's Kit
// exposes (session, API client, optional GoTrue client, and — once
// bootstrap has bound an identity — the local store, its edit surface,
// and the sync engine), plus the navigation `phase` every view in the app
// switches on. Views stay thin; this is the one place app-target code is
// allowed to hold state and orchestration (Global Constraints) — the
// actual business logic (auth, sync, costing, local edits) all lives in
// CostSauceKit already.

import Foundation
import Observation
import CostSauceKit

/// App-target-only errors — `CostSauceKit`'s `StoreError` is the frozen,
/// caller-facing contract for the Kit's OWN failure modes (Global
/// Constraints: no app-target code may widen that type), so a failure that
/// only exists because THIS layer called into the Kit incorrectly (no store
/// attached yet) gets its own small type instead.
enum AppModelError: Error {
    case noStore
}

@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case login
        case bootstrap
        case main
        case identityMismatch
    }

    enum BootstrapStep: Equatable {
        case loading
        case chooseMembership([Membership])
        case noOrganization
        case chooseLocation([LocationOut])
        case noLocations
    }

    // MARK: - Kit objects

    let session: SessionController
    let api: ApiClient
    private(set) var gotrue: GoTrueClient?
    private(set) var store: LocalStore?
    private(set) var edits: LocalEdits?
    private(set) var syncEngine: SyncEngine?

    // MARK: - published UI state

    private(set) var phase: Phase = .login
    private(set) var config: AppConfig?
    private(set) var configError: String?
    private(set) var bootstrapStep: BootstrapStep = .loading
    private(set) var bootstrapError: String?
    private(set) var membership: Membership?
    private(set) var currentLocation: LocationOut?
    private(set) var syncState: SyncState = .idle
    private(set) var pendingCount: Int = 0

    /// The caller's role in the bound org — `"owner"` | `"manager"` |
    /// `"bookkeeper"` | `nil`. Task 2b's offline edit-gating signal: see
    /// `canEditRecipes` below and the "role snapshot" section for how this
    /// stays populated across an offline cold start.
    private(set) var callerRole: String?

    /// True unless the latest `SyncEngine.stateStream` value is
    /// `.caughtUp` (§5.5) — dashboards/etc. read this to decide whether a
    /// suggested price is safe to show yet.
    private(set) var suppressSuggestions: Bool = true

    /// Recipe-edit gating (spec §8, decision D2). RLS truth:
    /// `recipe_write`/`recipe_item_write` are owner/manager only
    /// (`supabase/migrations/0012_business_tables.sql:158-188`) —
    /// bookkeepers have read-only access to both recipe tables at the
    /// database level, so an op composed offline by a bookkeeper can never
    /// actually land. This is what keeps the app from ever offering that
    /// dead-end write affordance in the first place.
    ///
    /// Unknown role (`callerRole == nil`) reads as `false` — read-only —
    /// never permissive: a normal launch can't hit this, since bootstrap
    /// always resolves `/me` before `phase` ever reaches `.main` (either
    /// the fresh path's own fetch, via `proceedWithMembership`, or the fast
    /// path's snapshot load, via `tryFastPathToMain`, both below). `nil` is
    /// only reachable right after one of the §13 erase paths clears the
    /// snapshot, before the next successful `/me` repopulates it.
    var canEditRecipes: Bool { callerRole == "owner" || callerRole == "manager" }

    /// §13 identity-mismatch recovery (Task 14): populated exactly when
    /// `phase` flips to `.identityMismatch`, by BOTH throw sites that route
    /// there (`bindAndEnterMain`'s fresh-bootstrap path and
    /// `completeReauth`'s re-auth path — see each method's doc comment).
    /// `mismatchedStore` is the store ALREADY on this device that belongs
    /// to a DIFFERENT identity than whichever session just authenticated —
    /// `IdentityMismatchView`'s "Export pending changes" reads from THIS,
    /// never from `store` (which is `nil` on the `bindAndEnterMain` path,
    /// since `attachStore` never ran there). `mismatchedMeta` is that
    /// store's OWN `(user_id, org_id)`, captured before any wipe (wiping
    /// clears `meta` along with everything else) — the erase path derives
    /// the EXACT ONE store file that was wiped from this
    /// (`store-<user_id>-<org_id>.sqlite`), never a broader sweep: a user
    /// can legitimately hold more than one store file (e.g. membership in
    /// two orgs), and every OTHER file is §13-protected data the on-screen
    /// consent never covered (a review-round-1 fix — see this task's
    /// report for the failure story a `userId`-wide sweep used to allow).
    /// `mismatchedSession` is the just-authenticated session
    /// `completeReauth` deliberately did NOT adopt (see that method's doc
    /// comment) — nil on the `bindAndEnterMain` path, where the new
    /// session is already live in `session.state` and there's nothing left
    /// to adopt.
    private(set) var mismatchedStore: LocalStore?
    private(set) var mismatchedMeta: Meta?
    private(set) var mismatchedSession: Session?

    // MARK: - private wiring

    /// The background transfer arm of the upload outbox (Task 7). Lazy
    /// only to satisfy the `self` reference; `init` forces it immediately,
    /// because recreating the background URLSession at launch is what
    /// re-attaches the app to uploads that ran while it was dead.
    @ObservationIgnored private(set) lazy var uploader = BackgroundUploader(appModel: self)

    private let keychain: KeychainStore
    private let tokenBox: TokenBox
    private(set) var boundOrgId: String?
    private(set) var boundLocationId: String?
    private var syncStateTask: Task<Void, Never>?
    private var syncDebounceTask: Task<Void, Never>?

    init() {
        let keychain = KeychainStore()
        if ProcessInfo.processInfo.environment["UITEST"] == "1" {
            // Task 15's smoke suite depends on every launch starting from a
            // truly clean slate: the device Keychain survives a
            // delete-and-reinstall (§13), so a repeat XCUITest run would
            // otherwise see a leftover session/store from the previous run.
            keychain.wipe()
            try? FileManager.default.removeItem(at: Self.applicationSupportDirectory())
        }
        self.keychain = keychain

        let session = SessionController(keychain: keychain)
        self.session = session

        let tokenBox = TokenBox()
        self.tokenBox = tokenBox
        let api = ApiClient(baseURL: Self.resolveBaseURL()) { tokenBox.get() }
        self.api = api

        if case .active(let active) = session.state {
            tokenBox.set(active.accessToken)
            phase = .bootstrap
        }

        // Set once at wiring time (ApiClient.onUnauthorized is lock-backed,
        // so later reassignment isn't needed — this app never re-points it).
        api.onUnauthorized = { [weak self] in
            Task { @MainActor [weak self] in
                self?.session.tokenExpiredOrUnauthorized()
                self?.tokenBox.set(nil)
            }
        }

        // See `uploader`'s doc comment: forced now so the background
        // session exists from launch, including a headless relaunch whose
        // only purpose is delivering that session's events.
        _ = uploader
    }

    // MARK: - base URL

    /// `UserDefaults` key `apiBaseURL`. Precedence: `API_BASE_URL` process
    /// env (dev/XCUITest) beats a previously-stored value (e.g. a future
    /// DEBUG-only settings field) beats the compiled DEBUG/Release default.
    /// The resolved value is always written back so every later reader
    /// sees one consistent source of truth.
    private static func resolveBaseURL() -> URL {
        let defaults = UserDefaults.standard
        let key = "apiBaseURL"
        #if DEBUG
        let compiledDefault = "http://127.0.0.1:8400"
        #else
        let compiledDefault = "https://api.costsauce.com"
        #endif

        let resolved: String
        if let env = ProcessInfo.processInfo.environment["API_BASE_URL"], !env.isEmpty {
            resolved = env
        } else if let stored = defaults.string(forKey: key), !stored.isEmpty {
            resolved = stored
        } else {
            resolved = compiledDefault
        }

        guard let url = URL(string: resolved) else {
            defaults.set(compiledDefault, forKey: key)
            return URL(string: compiledDefault)!
        }
        defaults.set(resolved, forKey: key)
        return url
    }

    // MARK: - store paths

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CostSauce", isDirectory: true)
    }

    private static func storePath(userId: String, orgId: String) -> String {
        applicationSupportDirectory()
            .appendingPathComponent("store-\(userId)-\(orgId).sqlite")
            .path
    }

    /// Any file already bound to this `userId` (any org) — the bootstrap
    /// brief's "on later launches, existing meta matching the session's
    /// userId skips bootstrap entirely."
    private static func findExistingStorePath(userId: String) -> String? {
        let directory = applicationSupportDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        let prefix = "store-\(userId)-"
        guard let match = entries.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".sqlite") }) else {
            return nil
        }
        return directory.appendingPathComponent(match).path
    }

    /// §13 erase paths (`switchAccountAndErase`/`eraseDeviceAndSignOut`):
    /// deletes EXACTLY the one store file `(userId, orgId)` names — the
    /// SAME file whichever caller's `wipe()` just cleared, and computed the
    /// SAME way `storePath` above always is. Deliberately narrow: a
    /// review-round-1 finding caught an earlier version of this helper
    /// sweeping every `store-<userId>-*.sqlite` file regardless of org,
    /// which silently destroys a DIFFERENT org's still-unexported pending
    /// queue if this identity happens to hold more than one store file
    /// (e.g. two org memberships, or a `tryFastPathToMain` bail-out — a
    /// locked-device `NSFileProtectionComplete` failure on `LocalStore
    /// (path:)`, say — that binds a second org after the first file
    /// couldn't be opened). Every erase screen's on-screen consent (and
    /// its export affordance) only ever covers ONE org's data — the
    /// mismatched/deleted one — so deletion must never reach further than
    /// that. Best-effort (`try?`): a failed delete here still leaves
    /// `LocalStore.wipe()` having already cleared every row INCLUDING
    /// `meta` in the ONE file this call targets, so a failure here is disk
    /// hygiene, never a correctness/identity-mixing risk.
    private static func removeStoreFile(userId: String, orgId: String) {
        try? FileManager.default.removeItem(atPath: Self.storePath(userId: userId, orgId: orgId))
    }

    // MARK: - location snapshot (offline cold start)

    /// `tryFastPathToMain` enters `.main` without ever calling `/locations`
    /// (that only happens later, via `refreshOnlineData`) — so a relaunch
    /// that starts offline, which iOS routinely forces by evicting
    /// backgrounded apps, would otherwise leave `currentLocation` nil, and
    /// with it Dashboard/Settings' location form stuck on "Loading your
    /// location…", for the whole offline session even though nothing about
    /// the last-known location has actually changed. This persists exactly
    /// `LocationOut` (already `Codable` — Dashboard/Settings read all four
    /// of its fields, so there's nothing to trim) to `UserDefaults` so
    /// `tryFastPathToMain` can seed `currentLocation` from the last
    /// successful fetch instead of leaving it nil until a new one lands.
    /// `targetFcPct`/`driftThresholdPct` round-trip as the STRINGS they
    /// already are (Global Constraints) — plain `Codable` synthesis never
    /// touches Double/Float/Decimal.
    ///
    /// Keyed by all three of `(userId, orgId, locationId)`, not
    /// `locationId` alone — the same identity-binding concern
    /// `storePath`/`removeStoreFile` above already guard against applies
    /// here too: a location id is shared by every member of its org, so a
    /// `locationId`-only key would let one member's device read whichever
    /// OTHER member of that same org most recently saved a snapshot for it.
    private static func locationSnapshotKey(userId: String, orgId: String, locationId: String) -> String {
        "locationSnapshot-\(userId)-\(orgId)-\(locationId)"
    }

    /// Called everywhere a fresh `locations()` fetch (or a Settings save's
    /// PATCH response) sets `currentLocation` — `bindAndEnterMain`,
    /// `refreshOnlineData`, `applyLocationUpdate`. A later successful fetch
    /// always overwrites this the same way it overwrites `currentLocation`
    /// itself, so the snapshot never lags more than one fetch behind.
    private static func saveLocationSnapshot(_ location: LocationOut, userId: String, orgId: String) {
        guard let data = try? JSONEncoder().encode(location) else { return }
        UserDefaults.standard.set(
            data, forKey: locationSnapshotKey(userId: userId, orgId: orgId, locationId: location.id))
    }

    private static func loadLocationSnapshot(userId: String, orgId: String, locationId: String) -> LocationOut? {
        guard
            let data = UserDefaults.standard.data(
                forKey: locationSnapshotKey(userId: userId, orgId: orgId, locationId: locationId))
        else { return nil }
        return try? JSONDecoder().decode(LocationOut.self, from: data)
    }

    /// §13 erase paths only (`switchAccountAndErase`/`eraseDeviceAndSignOut`)
    /// — mirrors `removeStoreFile`'s scope exactly: the ONE snapshot the
    /// erased identity owns, never a broader sweep. Ordinary `signOut()`
    /// deliberately does NOT call this: §13 sign-out never wipes local data,
    /// and this snapshot is exactly that kind of data — it sits beside the
    /// same sqlite file that already survives sign-out untouched, so a later
    /// sign-in as the SAME user resumes via `tryFastPathToMain` exactly as
    /// if the app had just relaunched (that method's own doc comment), with
    /// a still-correct location snapshot ready to seed it immediately.
    private static func clearLocationSnapshot(userId: String, orgId: String, locationId: String) {
        UserDefaults.standard.removeObject(
            forKey: locationSnapshotKey(userId: userId, orgId: orgId, locationId: locationId))
    }

    // MARK: - role snapshot (offline edit gating)

    /// Sibling of the location snapshot above, same offline-cold-start
    /// problem: `tryFastPathToMain` never calls `/me`, so without this a
    /// relaunch that starts offline would leave `callerRole` nil — and per
    /// `canEditRecipes`'s doc comment, nil reads as read-only, so a
    /// bookkeeper's device would correctly stay locked out, but so would an
    /// owner's or manager's, with no way to tell the difference until a
    /// fresh `/me` lands. Persisting the last-known role closes that gap
    /// the same way the location snapshot closes it for `currentLocation`.
    ///
    /// Keyed by `(userId, orgId)`, not `(userId, orgId, locationId)` — role
    /// is a property of the MEMBERSHIP, not the location, so folding
    /// `locationId` into the key would needlessly fragment the snapshot
    /// across a member's locations (and miss it entirely the first time
    /// they switch to a location they haven't been bound to before).
    private static func roleSnapshotKey(userId: String, orgId: String) -> String {
        "roleSnapshot-\(userId)-\(orgId)"
    }

    /// Called on every successful `/me` that resolves a membership for the
    /// org in question — `proceedWithMembership` below (the one `/me` call
    /// site inside this file), plus `recordCallerRole`, the wrapper
    /// `SettingsView`/`MembersView`/`OrgDeletedView`'s own `/me` calls go
    /// through (those views resolve membership independently because
    /// `AppModel.membership` is never populated on the fast bootstrap path
    /// — see each file's header). A later successful `/me` always
    /// overwrites this the same way it overwrites `callerRole` itself, so
    /// the snapshot never lags more than one fetch behind.
    private static func saveRoleSnapshot(_ role: String, userId: String, orgId: String) {
        UserDefaults.standard.set(role, forKey: roleSnapshotKey(userId: userId, orgId: orgId))
    }

    private static func loadRoleSnapshot(userId: String, orgId: String) -> String? {
        UserDefaults.standard.string(forKey: roleSnapshotKey(userId: userId, orgId: orgId))
    }

    /// §13 erase paths only (`switchAccountAndErase`/`eraseDeviceAndSignOut`)
    /// — mirrors `clearLocationSnapshot`'s scope exactly: the ONE snapshot
    /// the erased identity owns, never a broader sweep. Ordinary
    /// `signOut()` deliberately does NOT call this, for the same §13
    /// reasoning `clearLocationSnapshot`'s doc comment gives: sign-out never
    /// wipes local data, and this snapshot sits beside the same sqlite file
    /// that already survives sign-out untouched, so a later sign-in as the
    /// SAME user resumes via `tryFastPathToMain` with a still-correct role
    /// snapshot ready to seed it immediately.
    private static func clearRoleSnapshot(userId: String, orgId: String) {
        UserDefaults.standard.removeObject(forKey: roleSnapshotKey(userId: userId, orgId: orgId))
    }

    /// `SettingsView`/`MembersView`/`OrgDeletedView`'s own `/me` calls
    /// resolve a fresh `Membership` for `boundOrgId` without going through
    /// `proceedWithMembership` (they run long after bootstrap, from a
    /// signed-in `.main` session) — this is their write-back path, mirroring
    /// `applyLocationUpdate`. Unlike `applyLocationUpdate`'s counterparts
    /// (those views keep their OWN local `resolvedMembership` copy rather
    /// than writing back to `AppModel.membership`, deliberately, per their
    /// file headers), the role snapshot has no such view-local fallback to
    /// rely on offline, so this DOES write back — both live (`callerRole`,
    /// so `canEditRecipes` reflects it everywhere immediately, not just in
    /// the view that happened to fetch it) and to disk. Guarded on
    /// `orgId == boundOrgId` so a stale or unrelated membership (e.g. a
    /// `/me` response's OTHER org, or a call that lands after the user has
    /// already switched away) can never overwrite the snapshot for the
    /// currently-bound org.
    func recordCallerRole(_ role: String, orgId: String) {
        guard orgId == boundOrgId, let userId = currentUserId else { return }
        callerRole = role
        Self.saveRoleSnapshot(role, userId: userId, orgId: orgId)
    }

    // MARK: - config / GoTrue

    /// `/config`'s null `supabase_url` means the reviewer-only sign-in path
    /// is the only one available (web parity) — `gotrue` stays `nil` in
    /// that case and `LoginView` reads that to decide what to render.
    func loadConfig() async {
        guard config == nil else { return }
        configError = nil
        do {
            let cfg = try await api.config()
            config = cfg
            if let urlString = cfg.supabaseURL, let anonKey = cfg.supabaseAnonKey,
                let url = URL(string: urlString)
            {
                gotrue = GoTrueClient(supabaseURL: url, anonKey: anonKey)
            } else {
                gotrue = nil
            }
        } catch let error as ApiError {
            configError = error.message
        } catch {
            configError = error.localizedDescription
        }
    }

    // MARK: - login

    func completeInitialSignIn(session newSession: Session) {
        session.adopt(newSession)
        tokenBox.set(newSession.accessToken)
        phase = .bootstrap
    }

    /// Re-auth from the sync chip's `.blocked(.authRequired)` tap.
    ///
    /// §13's "identity switch → refuse flush" contract applies here just as
    /// much as it does to `bindAndEnterMain`'s fresh-bootstrap path: the
    /// store already bound in this session belongs to whoever was signed in
    /// BEFORE the token expired, and re-auth on a shared device can easily
    /// land a DIFFERENT person's credentials (a different `userId`) than
    /// the one that store's `meta` records. Resuming `syncNow()` in that
    /// case would silently start flushing one person's local queue to the
    /// server under another person's identity/token.
    ///
    /// Mirrors `bindAndEnterMain`'s handling of the identical
    /// `StoreError.identityMismatch` condition: on a mismatch, this method
    /// does not adopt the new session or touch `tokenBox`/`syncEngine` at
    /// all — it only captures the mismatch context Task 14's real screen
    /// needs (`mismatchedStore`/`mismatchedMeta`/`mismatchedSession`, see
    /// their doc comment above) and flips `phase` to `.identityMismatch`.
    /// Not adopting the session here also matters beyond just this one
    /// call: an adopted-but-mismatched session would still be sitting in
    /// `tokenBox`, available to any OTHER automatic sync trigger
    /// (`refreshOnlineData` on `scenePhase == .active`, a future
    /// `syncSoon()` call) to flush the same wrong-identity queue behind
    /// this guard's back. `newSession` is retained in `mismatchedSession`
    /// instead — `IdentityMismatchView`'s "switch and erase" action is the
    /// only path that ever adopts it (`switchAccountAndErase`), and only
    /// after the OLD identity's store is fully erased.
    func completeReauth(session newSession: Session) {
        if let store, let meta = try? store.meta(), meta.user_id != newSession.userId {
            mismatchedStore = store
            mismatchedMeta = meta
            mismatchedSession = newSession
            phase = .identityMismatch
            return
        }
        session.adopt(newSession)
        tokenBox.set(newSession.accessToken)
        Task { [weak self] in
            await self?.syncEngine?.syncNow()
        }
    }

    // MARK: - sign out

    /// Task 13's ordinary, everyday sign-out (distinct from Task 14's
    /// identity-mismatch/org-deleted recovery flows, which additionally
    /// offer export/switch-and-erase over a store this method never
    /// touches). Per §13, sign-out NEVER wipes the local store — only the
    /// in-memory Kit objects wired to THIS session are torn down (the sync
    /// engine/store/edits, its state-observation task, the debounced-sync
    /// task, and the in-memory token mirror); the sqlite file on disk is
    /// left completely untouched, so a later sign-in as the SAME user
    /// resumes it via `tryFastPathToMain` exactly as if the app had just
    /// relaunched. `currentLocation = nil` and `callerRole = nil` below are
    /// that same in-memory-only teardown — deliberately does NOT call
    /// `clearLocationSnapshot`/`clearRoleSnapshot`: both persisted snapshots
    /// sit beside the sqlite file under the exact same "local data survives
    /// sign-out" rule, and leaving them in place is what lets that same
    /// later sign-in seed `currentLocation`/`callerRole` immediately rather
    /// than spinning (or, for `callerRole`, reading as read-only) again.
    /// Only the §13 erase paths (`switchAccountAndErase`/
    /// `eraseDeviceAndSignOut`) ever call `clearLocationSnapshot`/
    /// `clearRoleSnapshot`, matching exactly where they call
    /// `removeStoreFile`.
    ///
    /// `phase` is routed back to `.login` explicitly here — nothing else in
    /// this file observes `SessionController.state` to do that
    /// (`RootView` in `CostSauceApp.swift` switches on `phase`, not
    /// `session.state`), which is exactly the gap that made calling
    /// `session.signOut()` alone unsafe (it would leave `MainTabView`
    /// rendering over a signed-out session).
    ///
    /// `tokenBox.set(nil)` runs BEFORE `session.signOut()`: this method has
    /// no handle to cancel a sync already in flight (every
    /// `Task { await syncEngine?.syncNow() }` call site elsewhere in this
    /// file is fire-and-forget, not stored), so the one thing it CAN do is
    /// make sure that straggler's next request carries no bearer token —
    /// it 401s closed instead of finishing a flush under a session that's
    /// about to report itself signed out.
    ///
    /// Also clears any `.identityMismatch` context (Task 14): both
    /// `IdentityMismatchView`'s "Cancel" and `eraseDeviceAndSignOut`'s
    /// org-deleted erase route through this method, and a stale
    /// `mismatchedStore`/`mismatchedSession` left over from a PRIOR
    /// mismatch must never leak into whatever this device does next.
    func signOut() {
        syncDebounceTask?.cancel()
        syncDebounceTask = nil
        syncStateTask?.cancel()
        syncStateTask = nil
        tokenBox.set(nil)
        syncEngine = nil
        store = nil
        edits = nil
        boundOrgId = nil
        boundLocationId = nil
        currentLocation = nil
        membership = nil
        callerRole = nil
        pendingCount = 0
        syncState = .idle
        session.signOut()
        phase = .login
        mismatchedStore = nil
        mismatchedMeta = nil
        mismatchedSession = nil
    }

    // MARK: - §13 identity-mismatch / org-deleted recovery (Task 14)

    /// `IdentityMismatchView`'s "Switch account and erase," after the user
    /// typed "ERASE" to confirm. Order matters twice over here:
    ///
    /// 1. `mismatchedMeta` (captured at the moment the mismatch was
    ///    detected, see `completeReauth`/`bindAndEnterMain`) is read into a
    ///    local BEFORE `wipe()` runs, since `wipe()` deletes the store's
    ///    `meta` row along with everything else — reading it after wiping
    ///    would find nothing.
    /// 2. Every strong reference to `mismatchedStore` (both this
    ///    property AND, on `completeReauth`'s path, `store` itself — the
    ///    two are the SAME object there) is dropped BEFORE
    ///    `removeStoreFile` unlinks its file from disk, so GRDB's
    ///    `DatabaseQueue` has already closed the sqlite connection by the
    ///    time the file disappears out from under it, rather than
    ///    unlinking a file a live connection still has open. This is why
    ///    the code below never binds `mismatchedStore` to a local `let` —
    ///    a `guard let mismatchedStore` would keep its OWN strong
    ///    reference alive for the rest of the function's scope regardless
    ///    of `self.mismatchedStore = nil` further down, silently
    ///    reintroducing the exact race this ordering exists to avoid.
    ///    Every access below goes through `self.mismatchedStore` via
    ///    optional chaining instead, so nilling the property really is
    ///    the last strong reference dropped.
    ///
    /// Deletes EXACTLY the one store file `mismatchedMeta` names
    /// (`removeStoreFile`, review-round-1 fix — see this task's report for
    /// why this must never sweep every file for the userId: a second store
    /// file for a DIFFERENT org this identity also holds is data the
    /// on-screen consent never covered) plus that same identity's location
    /// and role snapshots (`clearLocationSnapshot`/`clearRoleSnapshot`),
    /// tears down whatever Kit objects this session had attached (mirrors
    /// `signOut()`'s teardown, minus `session.signOut()` itself — this is a
    /// SWITCH, not a sign-out), then adopts the previously-parked new
    /// session (only non-nil on the `completeReauth` path —
    /// `bindAndEnterMain`'s path already has its session live) and restarts
    /// bootstrap from `.bootstrap` so a brand-new store gets created and
    /// bound under the new identity, exactly like a first-time sign-in.
    func switchAccountAndErase() {
        guard mismatchedStore != nil else { return }
        try? mismatchedStore?.wipe()
        let oldMeta = mismatchedMeta
        let sessionToAdopt = mismatchedSession

        syncDebounceTask?.cancel()
        syncDebounceTask = nil
        syncStateTask?.cancel()
        syncStateTask = nil
        syncEngine = nil
        store = nil
        edits = nil
        boundOrgId = nil
        boundLocationId = nil
        currentLocation = nil
        membership = nil
        callerRole = nil
        pendingCount = 0
        syncState = .idle
        self.mismatchedStore = nil
        self.mismatchedMeta = nil
        self.mismatchedSession = nil

        if let oldMeta {
            Self.removeStoreFile(userId: oldMeta.user_id, orgId: oldMeta.org_id)
            Self.clearLocationSnapshot(
                userId: oldMeta.user_id, orgId: oldMeta.org_id, locationId: oldMeta.location_id)
            Self.clearRoleSnapshot(userId: oldMeta.user_id, orgId: oldMeta.org_id)
        }
        if let sessionToAdopt {
            session.adopt(sessionToAdopt)
            tokenBox.set(sessionToAdopt.accessToken)
        }
        phase = .bootstrap
    }

    /// `OrgDeletedView`'s "Erase this device's copy" (§6.2), after the
    /// user confirmed. The wipe IS the queue discard (§13) — no pending op
    /// survives this, matching `LocalStore.wipe()`'s existing "deletes all
    /// rows including meta" contract — and it's user-confirmed, never
    /// silent. `oldMeta` is read BEFORE `wipe()` for the same reason
    /// `switchAccountAndErase` reads `mismatchedMeta` first: `wipe()`
    /// clears `meta` along with everything else. `removeStoreFile` runs
    /// AFTER `signOut()`, not before: `signOut()` is what drops the last
    /// strong reference to `store` (nils it as part of its own teardown),
    /// so the sqlite connection is closed before its file gets unlinked.
    ///
    /// Deletes EXACTLY the one file `store-<oldMeta.user_id>-
    /// <oldMeta.org_id>.sqlite` names, never a `userId`-wide sweep — a
    /// review-round-1 finding caught the ORIGINAL version of this method
    /// doing exactly that broader sweep, which is a real bug specifically
    /// HERE: this device may legitimately hold a SECOND store file under
    /// this same `userId` for a completely different, still-live org (two
    /// memberships, or a `tryFastPathToMain` bail-out that bound a second
    /// org after the first file failed to open). This screen's export
    /// affordance and `wipe()` call both only ever touch the ONE org that
    /// was actually deleted server-side — a broader sweep would silently
    /// destroy that OTHER org's still-unexported pending queue, which the
    /// on-screen consent never described or covered. The same one-org
    /// scoping applies to `clearLocationSnapshot`/`clearRoleSnapshot`
    /// alongside it. Otherwise identical to `signOut()`, which already
    /// wipes the Keychain (via
    /// `session.signOut()`) and routes `phase` back to `.login` — see that
    /// method's doc comment for why a bare `SessionController.signOut()`
    /// alone isn't enough.
    func eraseDeviceAndSignOut() {
        let oldMeta = try? store?.meta()
        try? store?.wipe()
        signOut()
        if let oldMeta {
            Self.removeStoreFile(userId: oldMeta.user_id, orgId: oldMeta.org_id)
            Self.clearLocationSnapshot(
                userId: oldMeta.user_id, orgId: oldMeta.org_id, locationId: oldMeta.location_id)
            Self.clearRoleSnapshot(userId: oldMeta.user_id, orgId: oldMeta.org_id)
        }
    }

    // MARK: - bootstrap

    func runBootstrap() async {
        bootstrapError = nil
        if await tryFastPathToMain() { return }
        guard case .active(let authSession) = session.state else { return }
        bootstrapStep = .loading
        do {
            let me = try await api.me()
            if let membership = pickDefaultMembership(me.memberships) {
                await proceedWithMembership(membership, userId: authSession.userId)
            } else if me.memberships.isEmpty {
                bootstrapStep = .noOrganization
            } else {
                bootstrapStep = .chooseMembership(me.memberships)
            }
        } catch let error as ApiError {
            bootstrapError = error.message
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    func selectMembership(_ membership: Membership) async {
        guard case .active(let authSession) = session.state else { return }
        await proceedWithMembership(membership, userId: authSession.userId)
    }

    func selectLocation(_ location: LocationOut) {
        guard case .active(let authSession) = session.state, let membership else { return }
        bindAndEnterMain(userId: authSession.userId, orgId: membership.orgId, location: location)
    }

    /// The one `/me`-resolved-membership site inside this file (both
    /// `runBootstrap`'s fresh fetch and `selectMembership`'s picker choice,
    /// which was itself resolved from that same fetch, route through here)
    /// — `callerRole`/`saveRoleSnapshot` are set alongside `self.membership`
    /// for exactly that reason, mirroring `bindAndEnterMain` setting
    /// `currentLocation`/`saveLocationSnapshot` together a few lines below
    /// this method's own call to it.
    private func proceedWithMembership(_ membership: Membership, userId: String) async {
        self.membership = membership
        callerRole = membership.role
        Self.saveRoleSnapshot(membership.role, userId: userId, orgId: membership.orgId)
        bootstrapStep = .loading
        do {
            let locations = try await api.locations(orgId: membership.orgId)
            if let location = pickDefaultLocation(locations) {
                bindAndEnterMain(userId: userId, orgId: membership.orgId, location: location)
            } else if locations.isEmpty {
                bootstrapStep = .noLocations
            } else {
                bootstrapStep = .chooseLocation(locations)
            }
        } catch let error as ApiError {
            bootstrapError = error.message
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    /// `store.bind` throwing `identityMismatch` means this device already
    /// holds a different (user, org) than the one this session just
    /// resolved to — routed to `.identityMismatch` (Task 14's real
    /// screen). The `do` block's own `newStore` isn't reachable from the
    /// `catch` below (Swift scopes a `do`'s `let`s to that block), so the
    /// catch reopens a second `LocalStore` handle at the identical path —
    /// safe, since `bind`'s failure rolled back only the write transaction
    /// it opened, not the file itself, and this app never has two
    /// `LocalStore`s live over the same path at once (the first one falls
    /// out of scope, unretained, the moment `catch` runs). Captured as
    /// `mismatchedStore` (plus its owning `mismatchedMeta`, read via
    /// `meta()` before anything ever wipes it — `switchAccountAndErase`
    /// needs BOTH `user_id` and `org_id` from it to delete exactly the one
    /// file this store's `wipe()` will clear, never a broader sweep) so
    /// `IdentityMismatchView` has something to export/erase. This session
    /// is ALREADY adopted by
    /// the time this runs (`completeInitialSignIn` adopts before
    /// `phase = .bootstrap` ever gets here), so unlike `completeReauth`'s
    /// identical branch, there's no separate "new session" left to park in
    /// `mismatchedSession` — `switchAccountAndErase` only needs to erase
    /// the old store and let `session.state`'s already-active session
    /// carry bootstrap forward.
    private func bindAndEnterMain(userId: String, orgId: String, location: LocationOut) {
        do {
            let newStore = try LocalStore(path: Self.storePath(userId: userId, orgId: orgId))
            try newStore.bind(userId: userId, orgId: orgId, locationId: location.id)
            attachStore(newStore, orgId: orgId, locationId: location.id)
            currentLocation = location
            Self.saveLocationSnapshot(location, userId: userId, orgId: orgId)
            phase = .main
            Task { [weak self] in
                await self?.syncEngine?.syncNow()
            }
        } catch let storeError as StoreError where storeError.kind == .identityMismatch {
            let newStore = try? LocalStore(path: Self.storePath(userId: userId, orgId: orgId))
            mismatchedStore = newStore
            mismatchedMeta = try? newStore?.meta()
            mismatchedSession = nil
            phase = .identityMismatch
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    /// On later launches, a local store already bound to this session's
    /// `userId` skips the membership/location picker flow entirely.
    /// `currentLocation` is seeded from whatever `saveLocationSnapshot` last
    /// persisted for this exact `(userId, orgId, locationId)` — nil if
    /// nothing was ever saved (e.g. a device bound before this snapshot
    /// existed, taking this fast path offline for the very first time) —
    /// which is exactly `DashboardView`/`SettingsView`'s existing
    /// `currentLocation == nil` spinner case, not a new failure mode this
    /// introduces. `callerRole` is seeded the same way from
    /// `loadRoleSnapshot`, for the identical `(userId, orgId)` pair — nil
    /// reads as read-only (`canEditRecipes`'s doc comment), the safe
    /// default for that same never-yet-saved edge case. `refreshOnlineData()`
    /// below still runs and overwrites `currentLocation`/its snapshot the
    /// moment a real fetch lands, but does NOT call `/me` — `callerRole`
    /// only refreshes from a real fetch when the user visits a screen that
    /// does (Settings, Members) or goes through bootstrap again.
    private func tryFastPathToMain() async -> Bool {
        guard case .active(let authSession) = session.state else { return false }
        guard let existingPath = Self.findExistingStorePath(userId: authSession.userId) else { return false }
        guard let existingStore = try? LocalStore(path: existingPath) else { return false }
        guard let meta = try? existingStore.meta(), meta.user_id == authSession.userId else { return false }

        attachStore(existingStore, orgId: meta.org_id, locationId: meta.location_id)
        currentLocation = Self.loadLocationSnapshot(
            userId: meta.user_id, orgId: meta.org_id, locationId: meta.location_id)
        callerRole = Self.loadRoleSnapshot(userId: meta.user_id, orgId: meta.org_id)
        phase = .main
        Task { [weak self] in
            await self?.refreshOnlineData()
        }
        return true
    }

    private func attachStore(_ newStore: LocalStore, orgId: String, locationId: String) {
        store = newStore
        edits = LocalEdits(store: newStore, locationId: locationId)
        let engine = SyncEngine(store: newStore, api: api, orgId: orgId)
        syncEngine = engine
        observeSyncState(engine)
        boundOrgId = orgId
        boundLocationId = locationId
        refreshPendingCount()
    }

    // MARK: - sync plumbing

    /// `engine.stateStream` is read HERE, synchronously, before `Task { }`
    /// below is even created — not inside the Task's own body. `stateStream`'s
    /// own doc comment is explicit about why that ordering matters: registering
    /// the subscriber is synchronous and hop-free, but only if the caller does
    /// it outside an `await`/Task boundary. Deferring the read into the Task's
    /// body would reintroduce exactly the race the property was designed to
    /// avoid — the syncEngine.syncNow() call this method's caller kicks off
    /// right after `attachStore` returns is a second, independently-scheduled
    /// Task with no ordering guarantee relative to this one, so a subscriber
    /// registered lazily inside the Task's body could miss `syncNow`'s very
    /// first `setState(.catchingUp)` (or even the terminal state, if the fake
    /// local dev server responds fast enough) before it ever starts consuming.
    private func observeSyncState(_ engine: SyncEngine) {
        syncStateTask?.cancel()
        let stream = engine.stateStream
        syncStateTask = Task { [weak self] in
            for await newState in stream {
                guard let self else { return }
                self.syncState = newState
                self.suppressSuggestions = newState != .caughtUp
                self.refreshPendingCount()
            }
        }
    }

    /// Internal, not private: `BackgroundUploader` refreshes the badge the
    /// moment an upload lands, the same way edit-driven callers do through
    /// `syncSoon()`. (Task 8 folds `pendingUploadCount` into this figure.)
    func refreshPendingCount() {
        guard let store else {
            pendingCount = 0
            return
        }
        pendingCount = (try? store.pendingCount()) ?? 0
    }

    /// Debounced `syncNow` for edit-driven callers (Tasks 10-14's views,
    /// after every local write): coalesces bursts of edits into one sync
    /// instead of a round trip per save, while still refreshing
    /// `pendingCount` immediately so the chip/badge never lags an edit
    /// that's already visible to local reads.
    /// Where captured pages come from. UITEST substitutes a generated
    /// fixture for the camera the simulator does not have -- the same
    /// environment flag `AppModel.init` already consults to wipe the
    /// Keychain and store on launch. Without this substitution the Phase 3a
    /// acceptance walk could not run at all.
    var pageSource: any ScannedPageSource {
        if ProcessInfo.processInfo.environment["UITEST"] == "1",
           let fixture = FixtureInvoicePage.make() {
            return FixturePageSource(images: [fixture])
        }
        return DocumentScannerSource()
    }

    func syncSoon() {
        refreshPendingCount()
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.syncEngine?.syncNow()
            // Bytes ride behind the rows they belong to: pump uploads only
            // after the op push has had its turn at the connection.
            await self?.uploader.pump()
        }
    }

    /// Wraps `LocalStore.deleteOp` so views never write the store directly
    /// — `PendingQueueView`'s discard action used to call `store?.deleteOp`
    /// straight through a bare `try?`, silently swallowing any failure (a
    /// 2a review follow-up). Refreshes `pendingCount` on success, same as
    /// `syncSoon()`'s own refresh, so the chip/badge reflect the discard
    /// immediately even for a caller that doesn't also call `syncSoon()`
    /// right after. Throws `AppModelError.noStore` if called before a store
    /// is attached — `PendingQueueView` can only reach this with a real op
    /// in hand, which itself only ever came from a `store.pendingOps` read,
    /// so that guard is defensive, not an expected path.
    func discardOp(_ opId: String) throws {
        guard let store else { throw AppModelError.noStore }
        try store.deleteOp(opId: opId)
        refreshPendingCount()
    }

    /// `scenePhase == .active`: refresh the session (if near expiry), kick
    /// a sync, and re-fetch `locations()` so `currentLocation` (locations
    /// don't sync through the pull loop) stays current while online.
    func refreshOnlineData() async {
        guard case .active(let authSession) = session.state else { return }
        await session.refreshIfNeeded(gotrue: gotrue)
        tokenBox.set(currentAccessToken)
        await syncEngine?.syncNow()
        guard let boundOrgId, let boundLocationId else { return }
        if let locations = try? await api.locations(orgId: boundOrgId),
           let match = locations.first(where: { $0.id == boundLocationId }) {
            currentLocation = match
            Self.saveLocationSnapshot(match, userId: authSession.userId, orgId: boundOrgId)
        }
        // Last, never first: a failed pump sleeps out its backoff before
        // returning, and nothing above should wait behind that.
        await uploader.pump()
    }

    /// Task 13's `SettingsView` calls this after its own `patchLocation`
    /// succeeds -- `currentLocation` has no other external setter
    /// (`private(set)`), and a manual Save needs to land everywhere
    /// `currentLocation` is read (the dashboard's drift threshold in
    /// particular) immediately, not just on the next `refreshOnlineData()`
    /// poll.
    func applyLocationUpdate(_ location: LocationOut) {
        currentLocation = location
        if let currentUserId, let boundOrgId {
            Self.saveLocationSnapshot(location, userId: currentUserId, orgId: boundOrgId)
        }
    }

    private var currentAccessToken: String? {
        if case .active(let activeSession) = session.state {
            return activeSession.accessToken
        }
        return nil
    }

    private var currentUserId: String? {
        if case .active(let activeSession) = session.state {
            return activeSession.userId
        }
        return nil
    }
}

/// Thread-safe mirror of the current access token. `ApiClient`'s
/// `accessToken` closure is synchronous, `@Sendable`, and can run on any
/// thread (background sync work included), while `SessionController` is
/// `@MainActor` — so the closure can't just read `session.state` directly.
/// Same "class + one `NSLock`" shape `ApiClient.onUnauthorized` and
/// `SyncEngine`'s stream subscribers already use in the Kit.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func set(_ newToken: String?) {
        lock.lock()
        token = newToken
        lock.unlock()
    }
}
