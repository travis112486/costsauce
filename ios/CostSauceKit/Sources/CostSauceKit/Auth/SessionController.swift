// The CostSauce session controller — the app's one source of truth for
// "are we signed in," including the §13 first-run wipe.

import Foundation
import Observation

@Observable
@MainActor
public final class SessionController {
    public enum State: Equatable, Sendable {
        case signedOut
        case active(Session)
        case needsReauth
    }

    public private(set) var state: State

    private let keychain: KeychainStore

    /// §13: a delete-and-reinstall destroys the app's container (and its
    /// pending-op queue) but the device Keychain SURVIVES uninstall, so a
    /// fresh install would otherwise relaunch "signed in" with a token
    /// whose local data is gone. The very first launch of a fresh
    /// container wipes any leftover Keychain item before ever reading it,
    /// then marks itself done so every later launch trusts the Keychain
    /// normally.
    public init(keychain: KeychainStore, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        let firstRunKey = "didCompleteFirstRun"
        if !defaults.bool(forKey: firstRunKey) {
            keychain.wipe()
            defaults.set(true, forKey: firstRunKey)
            state = .signedOut
        } else if let existing = keychain.load() {
            state = .active(existing)
        } else {
            state = .signedOut
        }
    }

    public func adopt(_ s: Session) {
        try? keychain.save(s)
        state = .active(s)
    }

    /// The Keychain item is left untouched (§13's contract is "wipe only
    /// once, on the very first launch of a fresh install" — a normal
    /// sign-out is not that event, and leaving the item behind is what
    /// lets a stray relaunch of a currently-installed app still see
    /// whatever pre-first-run state applies next time `init` runs).
    public func signOut() {
        keychain.wipe()
        state = .signedOut
    }

    /// Local data stays readable and the pending-op queue stays held —
    /// this method only flips the published state; it doesn't touch the
    /// Keychain or the local store, both of which remain exactly as they
    /// were until a fresh sign-in calls `adopt`.
    public func tokenExpiredOrUnauthorized() {
        state = .needsReauth
    }

    /// Refreshes the active session when it's within 5 minutes of expiry
    /// AND has a refresh token — a reviewer session (`refreshToken == nil`)
    /// is a standing no-op here by design, not a failure: its 1h JWT is
    /// simply not refreshable, so the caller runs out the clock and
    /// re-authenticates via `reviewerLogin` again.
    public func refreshIfNeeded(gotrue: GoTrueClient?) async {
        guard case .active(let session) = state else { return }
        guard let refreshToken = session.refreshToken else { return }
        guard let gotrue else { return }
        guard session.expiresAt.timeIntervalSinceNow < 300 else { return }
        if let refreshed = try? await gotrue.refresh(refreshToken: refreshToken) {
            adopt(refreshed)
        }
    }
}
