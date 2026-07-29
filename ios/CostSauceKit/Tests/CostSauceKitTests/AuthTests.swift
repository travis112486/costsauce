import Testing
import Foundation
@testable import CostSauceKit

@Suite(.serialized)
struct AuthTests {
    let supabaseURL = URL(string: "https://proj.supabase.co")!

    private func expectApiError(_ body: () async throws -> Void) async -> ApiError? {
        do {
            try await body()
            Issue.record("expected to throw ApiError")
            return nil
        } catch let error as ApiError {
            return error
        } catch {
            Issue.record("expected ApiError, got \(error)")
            return nil
        }
    }

    /// A fresh, uniquely-named `UserDefaults` suite name per test -- never
    /// `.standard` -- so `SessionController`'s first-run flag can't leak
    /// between test runs (or between this process and a real device's
    /// actual defaults). Returns the suite NAME rather than a `UserDefaults`
    /// instance: `SessionController.init` is `@MainActor`, and re-using the
    /// SAME `UserDefaults` binding both before and after a call that sends
    /// it across that isolation boundary trips Swift 6's region-based
    /// "sending" diagnostic (`#SendingRisksDataRace`) even though
    /// `UserDefaults` itself is thread-safe -- fetching a fresh handle to
    /// the same suite via `defaultsHandle(_:)` at each call site sidesteps
    /// it, since each occurrence is an independent expression rather than
    /// a reused binding.
    private func freshSuiteName() -> String {
        let suiteName = "AuthTests-\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        return suiteName
    }

    private func defaultsHandle(_ suiteName: String) -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    /// Convenience for the (common) case of a test that only needs ONE
    /// `UserDefaults` reference, used a single time.
    private func freshDefaults() -> UserDefaults {
        defaultsHandle(freshSuiteName())
    }

    // MARK: - GoTrueClient

    @Test func verifyOtpHappyPath() async throws {
        let client = GoTrueClient(supabaseURL: supabaseURL, anonKey: "anon-key", session: StubTransport.makeSession())
        let capturedRequest = Captured<URLRequest?>(nil)
        let capturedBody = Captured<Data?>(nil)

        let session = try await StubTransport.withStub({ request, body in
            capturedRequest.value = request
            capturedBody.value = body
            return StubTransport.json(
                200,
                [
                    "access_token": "access-1", "refresh_token": "refresh-1",
                    "expires_in": 3600, "user": ["id": "user-1"],
                ])
        }) {
            try await client.verifyOtp(email: "alice@example.test", code: "123456")
        }

        #expect(session.accessToken == "access-1")
        #expect(session.refreshToken == "refresh-1")
        #expect(session.userId == "user-1")
        let secondsUntilExpiry = session.expiresAt.timeIntervalSinceNow
        #expect(secondsUntilExpiry > 3500 && secondsUntilExpiry <= 3600)

        #expect(capturedRequest.value?.url?.path == "/auth/v1/verify")
        #expect(capturedRequest.value?.value(forHTTPHeaderField: "apikey") == "anon-key")
        let raw = try #require(capturedBody.value)
        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(object["type"] as? String == "email")
        #expect(object["email"] as? String == "alice@example.test")
        #expect(object["token"] as? String == "123456")
    }

    @Test func gotrueErrorDescriptionSurfacesAsMessage() async throws {
        let client = GoTrueClient(supabaseURL: supabaseURL, anonKey: "anon-key", session: StubTransport.makeSession())
        let error = await expectApiError {
            _ = try await StubTransport.withStub({ _, _ in
                StubTransport.json(400, ["error_description": "otp_expired"])
            }) {
                try await client.verifyOtp(email: "alice@example.test", code: "000000")
            }
        }
        #expect(error?.status == 400)
        #expect(error?.detail == .text("otp_expired"))
        #expect(error?.message == "otp_expired")
    }

    /// The OAuth2-style field GoTrue's refresh-grant errors use (no
    /// `msg`/`error_description` at all) -- web/js/auth.mjs's
    /// `gotrueErrorDetail` still has an `error` branch below `msg`/
    /// `error_description`, which is exactly what makes this body
    /// resolvable instead of falling to the "HTTP <status>" fallback.
    @Test func gotrueErrorOnlyBodySurfacesAsMessage() async throws {
        let client = GoTrueClient(supabaseURL: supabaseURL, anonKey: "anon-key", session: StubTransport.makeSession())
        let error = await expectApiError {
            _ = try await StubTransport.withStub({ _, _ in
                StubTransport.json(400, ["error": "invalid_grant"])
            }) {
                try await client.refresh(refreshToken: "stale-refresh")
            }
        }
        #expect(error?.status == 400)
        #expect(error?.detail == .text("invalid_grant"))
        #expect(error?.message == "invalid_grant")
    }

    /// `msg` wins over `error_description` when both are present --
    /// web/js/auth.mjs's `gotrueErrorDetail` precedence, checked first.
    @Test func gotrueMsgTakesPrecedenceOverErrorDescription() async throws {
        let client = GoTrueClient(supabaseURL: supabaseURL, anonKey: "anon-key", session: StubTransport.makeSession())
        let error = await expectApiError {
            _ = try await StubTransport.withStub({ _, _ in
                StubTransport.json(400, ["msg": "A", "error_description": "B"])
            }) {
                try await client.verifyOtp(email: "alice@example.test", code: "000000")
            }
        }
        #expect(error?.status == 400)
        #expect(error?.detail == .text("A"))
        #expect(error?.message == "A")
    }

    @Test func refreshRoundTripReplacesBothTokens() async throws {
        let client = GoTrueClient(supabaseURL: supabaseURL, anonKey: "anon-key", session: StubTransport.makeSession())
        let capturedRequest = Captured<URLRequest?>(nil)

        let refreshed = try await StubTransport.withStub({ request, _ in
            capturedRequest.value = request
            return StubTransport.json(
                200,
                [
                    "access_token": "access-2", "refresh_token": "refresh-2",
                    "expires_in": 3600, "user": ["id": "user-1"],
                ])
        }) {
            try await client.refresh(refreshToken: "refresh-1")
        }

        #expect(refreshed.accessToken == "access-2")
        #expect(refreshed.refreshToken == "refresh-2")
        #expect(capturedRequest.value?.url?.path == "/auth/v1/token")
        #expect(capturedRequest.value?.url?.query?.contains("grant_type=refresh_token") == true)
    }

    // MARK: - SessionController: first-run wipe

    @Test func firstRunWipesPreSeededKeychainSecondLaunchDoesNot() async throws {
        let backing = InMemoryBacking()
        let keychain = KeychainStore(backing: backing)
        let preSeeded = Session(
            accessToken: "stale-token", refreshToken: "stale-refresh", userId: "user-1",
            expiresAt: Date().addingTimeInterval(3600))
        try keychain.save(preSeeded)
        #expect(backing.get() != nil)

        let suiteName = freshSuiteName()
        #expect(defaultsHandle(suiteName).bool(forKey: "didCompleteFirstRun") == false)

        // First launch of a fresh container: the pre-seeded (leftover, from
        // before a delete-and-reinstall) Keychain item is wiped, and the
        // controller starts signed out.
        let firstLaunch = await SessionController(keychain: keychain, defaults: defaultsHandle(suiteName))
        let firstLaunchState = await firstLaunch.state
        #expect(firstLaunchState == .signedOut)
        #expect(backing.get() == nil)
        #expect(defaultsHandle(suiteName).bool(forKey: "didCompleteFirstRun") == true)

        // Second launch, same (now-flagged) defaults: a session saved
        // since the first launch is trusted and loaded normally, NOT wiped.
        let afterAdopt = Session(
            accessToken: "fresh-token", refreshToken: "fresh-refresh", userId: "user-2",
            expiresAt: Date().addingTimeInterval(3600))
        try keychain.save(afterAdopt)
        let secondLaunch = await SessionController(keychain: keychain, defaults: defaultsHandle(suiteName))
        let secondLaunchState = await secondLaunch.state
        #expect(secondLaunchState == .active(afterAdopt))
        #expect(backing.get() != nil)
    }

    // MARK: - SessionController: state transitions

    @Test func adoptSignOutAndNeedsReauthTransitions() async throws {
        let backing = InMemoryBacking()
        let keychain = KeychainStore(backing: backing)
        let defaults = freshDefaults()
        defaults.set(true, forKey: "didCompleteFirstRun")  // skip first-run wipe for this test

        let controller = await SessionController(keychain: keychain, defaults: defaults)
        let initialState = await controller.state
        #expect(initialState == .signedOut)

        let session = Session(
            accessToken: "tok", refreshToken: "refresh", userId: "user-1",
            expiresAt: Date().addingTimeInterval(3600))
        await controller.adopt(session)
        let activeState = await controller.state
        #expect(activeState == .active(session))
        #expect(keychain.load() == session)

        await controller.tokenExpiredOrUnauthorized()
        let needsReauthState = await controller.state
        #expect(needsReauthState == .needsReauth)
        // Local data / queue policy is out of scope for this class; the
        // Keychain item is untouched by this transition.
        #expect(keychain.load() == session)

        await controller.signOut()
        let signedOutState = await controller.state
        #expect(signedOutState == .signedOut)
        #expect(keychain.load() == nil)
    }

    // MARK: - SessionController: refreshIfNeeded

    @Test func refreshIfNeededNoOpsForReviewerSessions() async throws {
        let backing = InMemoryBacking()
        let keychain = KeychainStore(backing: backing)
        let defaults = freshDefaults()
        defaults.set(true, forKey: "didCompleteFirstRun")

        let controller = await SessionController(keychain: keychain, defaults: defaults)
        // A reviewer session: no refresh token, and (deliberately, to prove
        // the no-op is keyed on `refreshToken == nil` and not merely "not
        // near expiry") already within the 5-minute refresh window.
        let reviewerSession = Session(
            accessToken: "reviewer-tok", refreshToken: nil, userId: "reviewer-1",
            expiresAt: Date().addingTimeInterval(60))
        await controller.adopt(reviewerSession)

        let gotrue = GoTrueClient(supabaseURL: supabaseURL, anonKey: "anon-key", session: StubTransport.makeSession())
        let refreshCalled = Captured<Bool>(false)
        try await StubTransport.withStub({ _, _ in
            refreshCalled.value = true
            return StubTransport.json(
                200,
                [
                    "access_token": "new-tok", "refresh_token": "new-refresh",
                    "expires_in": 3600, "user": ["id": "reviewer-1"],
                ])
        }) {
            await controller.refreshIfNeeded(gotrue: gotrue)
        }

        #expect(refreshCalled.value == false)
        let stateAfter = await controller.state
        #expect(stateAfter == .active(reviewerSession))
    }

    @Test func refreshIfNeededRefreshesWhenNearExpiryWithRefreshToken() async throws {
        let backing = InMemoryBacking()
        let keychain = KeychainStore(backing: backing)
        let defaults = freshDefaults()
        defaults.set(true, forKey: "didCompleteFirstRun")

        let controller = await SessionController(keychain: keychain, defaults: defaults)
        let nearExpiry = Session(
            accessToken: "old-tok", refreshToken: "old-refresh", userId: "user-1",
            expiresAt: Date().addingTimeInterval(60))  // < 5 minutes
        await controller.adopt(nearExpiry)

        let gotrue = GoTrueClient(supabaseURL: supabaseURL, anonKey: "anon-key", session: StubTransport.makeSession())
        try await StubTransport.withStub({ _, _ in
            StubTransport.json(
                200,
                [
                    "access_token": "new-tok", "refresh_token": "new-refresh",
                    "expires_in": 3600, "user": ["id": "user-1"],
                ])
        }) {
            await controller.refreshIfNeeded(gotrue: gotrue)
        }

        let state = await controller.state
        guard case .active(let refreshed) = state else {
            Issue.record("expected .active after refresh, got \(state)")
            return
        }
        #expect(refreshed.accessToken == "new-tok")
        #expect(refreshed.refreshToken == "new-refresh")
    }

    @Test func refreshIfNeededNoOpsWhenFarFromExpiry() async throws {
        let backing = InMemoryBacking()
        let keychain = KeychainStore(backing: backing)
        let defaults = freshDefaults()
        defaults.set(true, forKey: "didCompleteFirstRun")

        let controller = await SessionController(keychain: keychain, defaults: defaults)
        let farFromExpiry = Session(
            accessToken: "tok", refreshToken: "refresh", userId: "user-1",
            expiresAt: Date().addingTimeInterval(3600))
        await controller.adopt(farFromExpiry)

        let gotrue = GoTrueClient(supabaseURL: supabaseURL, anonKey: "anon-key", session: StubTransport.makeSession())
        let refreshCalled = Captured<Bool>(false)
        try await StubTransport.withStub({ _, _ in
            refreshCalled.value = true
            return StubTransport.json(200, ["access_token": "should-not-be-used", "expires_in": 3600, "user": ["id": "user-1"]])
        }) {
            await controller.refreshIfNeeded(gotrue: gotrue)
        }

        #expect(refreshCalled.value == false)
        let stateAfter = await controller.state
        #expect(stateAfter == .active(farFromExpiry))
    }
}
