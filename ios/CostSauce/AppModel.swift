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

    /// True unless the latest `SyncEngine.stateStream` value is
    /// `.caughtUp` (§5.5) — dashboards/etc. read this to decide whether a
    /// suggested price is safe to show yet.
    private(set) var suppressSuggestions: Bool = true

    // MARK: - private wiring

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
    /// all — it only flips `phase` to the same `.identityMismatch`
    /// placeholder destination (Task 14 owns the real screen — export /
    /// typed-ERASE switch / cancel — and whatever re-adoption of this
    /// session that flow ends up needing). Not adopting the session here
    /// also matters beyond just this one call: an adopted-but-mismatched
    /// session would still be sitting in `tokenBox`, available to any OTHER
    /// automatic sync trigger (`refreshOnlineData` on `scenePhase == .active`,
    /// a future `syncSoon()` call) to flush the same wrong-identity queue
    /// behind this guard's back.
    func completeReauth(session newSession: Session) {
        if let store, let boundUserId = (try? store.meta())?.user_id, boundUserId != newSession.userId {
            phase = .identityMismatch
            return
        }
        session.adopt(newSession)
        tokenBox.set(newSession.accessToken)
        Task { [weak self] in
            await self?.syncEngine?.syncNow()
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

    private func proceedWithMembership(_ membership: Membership, userId: String) async {
        self.membership = membership
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
    /// resolved to — routed to `.identityMismatch` (Task 14 builds the real
    /// screen; see this task's report for the placeholder standing in for
    /// it here).
    private func bindAndEnterMain(userId: String, orgId: String, location: LocationOut) {
        do {
            let newStore = try LocalStore(path: Self.storePath(userId: userId, orgId: orgId))
            try newStore.bind(userId: userId, orgId: orgId, locationId: location.id)
            attachStore(newStore, orgId: orgId, locationId: location.id)
            currentLocation = location
            phase = .main
            Task { [weak self] in
                await self?.syncEngine?.syncNow()
            }
        } catch let storeError as StoreError where storeError.kind == .identityMismatch {
            phase = .identityMismatch
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    /// On later launches, a local store already bound to this session's
    /// `userId` skips the membership/location picker flow entirely.
    private func tryFastPathToMain() async -> Bool {
        guard case .active(let authSession) = session.state else { return false }
        guard let existingPath = Self.findExistingStorePath(userId: authSession.userId) else { return false }
        guard let existingStore = try? LocalStore(path: existingPath) else { return false }
        guard let meta = try? existingStore.meta(), meta.user_id == authSession.userId else { return false }

        attachStore(existingStore, orgId: meta.org_id, locationId: meta.location_id)
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

    private func refreshPendingCount() {
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
    func syncSoon() {
        refreshPendingCount()
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.syncEngine?.syncNow()
        }
    }

    /// `scenePhase == .active`: refresh the session (if near expiry), kick
    /// a sync, and re-fetch `locations()` so `currentLocation` (locations
    /// don't sync through the pull loop) stays current while online.
    func refreshOnlineData() async {
        guard case .active = session.state else { return }
        await session.refreshIfNeeded(gotrue: gotrue)
        tokenBox.set(currentAccessToken)
        await syncEngine?.syncNow()
        guard let boundOrgId, let boundLocationId else { return }
        guard let locations = try? await api.locations(orgId: boundOrgId) else { return }
        if let match = locations.first(where: { $0.id == boundLocationId }) {
            currentLocation = match
        }
    }

    /// Task 13's `SettingsView` calls this after its own `patchLocation`
    /// succeeds -- `currentLocation` has no other external setter
    /// (`private(set)`), and a manual Save needs to land everywhere
    /// `currentLocation` is read (the dashboard's drift threshold in
    /// particular) immediately, not just on the next `refreshOnlineData()`
    /// poll.
    func applyLocationUpdate(_ location: LocationOut) {
        currentLocation = location
    }

    private var currentAccessToken: String? {
        if case .active(let activeSession) = session.state {
            return activeSession.accessToken
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
