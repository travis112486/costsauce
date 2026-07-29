// The CostSauce API client — Bearer-auth REST calls against the FastAPI
// backend. web/js/api.mjs is the browser-side reference for the same
// conventions (Bearer header, `{"detail": ...}` error envelope, 401
// handling); this is a from-scratch port, not a transliteration, since the
// browser client leans on `fetch`/`localStorage`/`window` globals that
// don't exist here.

import Foundation

/// Thrown by `ApiClient.reviewerLogin` when the server's own access token
/// isn't a well-formed three-segment JWT, or its payload has no string
/// `sub`. Distinct from `ApiError` (which always carries a real HTTP
/// status): this is a local decode failure, not a server-reported one.
struct JWTDecodeError: Error, Equatable {
    let reason: String
}

public final class ApiClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let accessTokenProvider: @Sendable () -> String?

    // `onUnauthorized` is the one piece of mutable state this class has,
    // so it's the one thing that keeps `ApiClient` from being a plain
    // (compiler-checked) `Sendable` class the way `LocalStore` is --
    // hence `@unchecked` plus this lock guarding every read/write of it.
    private let lock = NSLock()
    private var _onUnauthorized: (@Sendable () -> Void)?

    public var onUnauthorized: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onUnauthorized
        }
        set {
            lock.lock()
            _onUnauthorized = newValue
            lock.unlock()
        }
    }

    public init(
        baseURL: URL, session: URLSession = .shared,
        accessToken: @Sendable @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.session = session
        self.accessTokenProvider = accessToken
    }

    // MARK: - shared codec

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    // MARK: - low-level request plumbing

    private func makeURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        // A leading-"/" relative reference REPLACES `baseURL`'s path
        // entirely (RFC 3986 relative resolution), which is exactly what
        // every path literal below assumes ("/me", "/orgs/{id}/locations", …).
        let resolved = URL(string: path, relativeTo: baseURL)!.absoluteURL
        guard !query.isEmpty else { return resolved }
        var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true)!
        components.queryItems = query
        return components.url!
    }

    /// Executes one request; returns the raw response body on any 2xx
    /// status, otherwise throws `ApiError`. Fires `onUnauthorized` exactly
    /// once, before throwing, on a 401 -- never on any other status.
    private func execute(_ url: URL, method: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = accessTokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiError(status: 0, detail: .none)
        }

        if http.statusCode == 401 {
            onUnauthorized?()
            throw ApiError(status: 401, detail: ApiError.parseDetail(from: data))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ApiError(status: http.statusCode, detail: ApiError.parseDetail(from: data))
        }
        return data
    }

    private func decode<T: Decodable>(
        _ type: T.Type, _ url: URL, method: String = "GET", body: Data? = nil
    ) async throws -> T {
        let data = try await execute(url, method: method, body: body)
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: - config / identity

    public func config() async throws -> AppConfig {
        try await decode(AppConfig.self, makeURL("/config"))
    }

    public func me() async throws -> MeResponse {
        try await decode(MeResponse.self, makeURL("/me"))
    }

    // MARK: - locations

    public func locations(orgId: String) async throws -> [LocationOut] {
        try await decode([LocationOut].self, makeURL("/orgs/\(orgId)/locations"))
    }

    /// `nil` params are OMITTED from the body entirely, not sent as an
    /// explicit JSON `null` — the server's `LocationPatch` model validator
    /// rejects an explicit null with a 422 (api/models.py:97-113), since
    /// `model_dump(exclude_unset=True)` treats "explicitly null" the same
    /// as "explicitly set" and would otherwise try to write a `NOT NULL`
    /// column to NULL. Building a plain `[String: String]` (non-Optional
    /// values) rather than encoding `LocationPatch`-shaped Optionals is
    /// what guarantees an absent key can never become a present null.
    public func patchLocation(
        id: String, name: String?, targetFcPct: String?, driftThresholdPct: String?
    ) async throws -> LocationOut {
        var fields: [String: String] = [:]
        if let name { fields["name"] = name }
        if let targetFcPct { fields["target_fc_pct"] = targetFcPct }
        if let driftThresholdPct { fields["drift_threshold_pct"] = driftThresholdPct }
        let body = try JSONEncoder().encode(fields)
        return try await decode(LocationOut.self, makeURL("/locations/\(id)"), method: "PATCH", body: body)
    }

    // MARK: - members / invites

    public func members(orgId: String) async throws -> [MemberOut] {
        try await decode([MemberOut].self, makeURL("/orgs/\(orgId)/members"))
    }

    public func invite(orgId: String, email: String, role: String) async throws -> (inviteId: String, token: String?) {
        struct Body: Encodable { let email: String; let role: String }
        struct Resp: Decodable { let inviteId: String; let token: String? }
        let body = try Self.encoder.encode(Body(email: email, role: role))
        let resp: Resp = try await decode(Resp.self, makeURL("/orgs/\(orgId)/invites"), method: "POST", body: body)
        return (resp.inviteId, resp.token)
    }

    public func acceptInvite(token: String) async throws -> (orgId: String, role: String) {
        struct Body: Encodable { let token: String }
        struct Resp: Decodable { let orgId: String; let role: String }
        let body = try Self.encoder.encode(Body(token: token))
        let resp: Resp = try await decode(Resp.self, makeURL("/invites/accept"), method: "POST", body: body)
        return (resp.orgId, resp.role)
    }

    public func setRole(orgId: String, userId: String, role: String) async throws -> String {
        struct Body: Encodable { let role: String }
        struct Resp: Decodable { let role: String }
        let body = try Self.encoder.encode(Body(role: role))
        let resp: Resp = try await decode(
            Resp.self, makeURL("/orgs/\(orgId)/members/\(userId)"), method: "PATCH", body: body)
        return resp.role
    }

    public func removeMember(orgId: String, userId: String) async throws {
        _ = try await execute(makeURL("/orgs/\(orgId)/members/\(userId)"), method: "DELETE", body: nil)
    }

    // MARK: - sync

    /// `since`/`org_id` are both query params (api/routes/sync.py:104-112 —
    /// the route path is a bare "/sync"; FastAPI infers both scalar
    /// arguments as query params since neither is in the path template).
    public func syncPull(orgId: String, since: Int64) async throws -> SyncPullResponse {
        let url = makeURL("/sync", query: [
            URLQueryItem(name: "org_id", value: orgId),
            URLQueryItem(name: "since", value: String(since)),
        ])
        return try await decode(SyncPullResponse.self, url)
    }

    public func syncPush(orgId: String, batchId: String, ops: [SyncOp]) async throws -> SyncPushResponse {
        struct Body: Encodable { let orgId: String; let batchId: String; let ops: [SyncOp] }
        let body = try Self.encoder.encode(Body(orgId: orgId, batchId: batchId, ops: ops))
        return try await decode(SyncPushResponse.self, makeURL("/sync"), method: "POST", body: body)
    }

    // MARK: - export

    /// Raw ZIP bytes, returned untouched (api/routes/deletion.py:538-569 —
    /// `media_type: application/zip`); there is no JSON to decode.
    public func exportOrg(orgId: String) async throws -> Data {
        try await execute(makeURL("/orgs/\(orgId)/export"), method: "GET", body: nil)
    }

    // MARK: - reviewer sign-in

    /// Fixed-credential sign-in for App Review (api/routes/identity.py:
    /// 252-288). The server's response is `{"access_token": <1h HS256 JWT>}`
    /// ONLY -- no refresh token, no user object -- so `userId` comes from
    /// the token's own `sub` claim, read WITHOUT verifying the signature
    /// (this device has no way to verify an HS256 token signed with a
    /// server-side secret; the token's authenticity is established by TLS
    /// + the fact the server itself just handed it back, not by a local
    /// signature check).
    public func reviewerLogin(email: String, code: String) async throws -> Session {
        struct Body: Encodable { let email: String; let code: String }
        struct Resp: Decodable { let accessToken: String }
        let body = try Self.encoder.encode(Body(email: email, code: code))
        let resp: Resp = try await decode(Resp.self, makeURL("/auth/reviewer-otp"), method: "POST", body: body)
        let userId = try Self.decodeJWTSubject(resp.accessToken)
        return Session(
            accessToken: resp.accessToken, refreshToken: nil, userId: userId,
            expiresAt: Date().addingTimeInterval(3600))
    }

    /// Decodes segment 2 (the payload) of a `header.payload.signature` JWT
    /// as base64url JSON and reads its `sub` claim. No signature check —
    /// see `reviewerLogin`'s doc comment for why that's the intended
    /// contract here, not an oversight.
    private static func decodeJWTSubject(_ token: String) throws -> String {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2, let payloadData = base64URLDecode(String(segments[1])) else {
            throw JWTDecodeError(reason: "malformed JWT")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
            let sub = object["sub"] as? String
        else {
            throw JWTDecodeError(reason: "JWT payload missing string \"sub\"")
        }
        return sub
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        return Data(base64Encoded: base64)
    }
}
