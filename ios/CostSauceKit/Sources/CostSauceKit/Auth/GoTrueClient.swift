// The CostSauce GoTrue client — hand-rolled REST against Supabase Auth's
// `/auth/v1/*` endpoints (no SDK). web/js/auth.mjs is the browser-side
// reference for the same request bodies and error-detail extraction; this
// port additionally computes `Session.expiresAt` from GoTrue's
// `expires_in` (a duration, not a timestamp), which the browser client
// never needed since it only ever stores the bare access token string.

import Foundation

public final class GoTrueClient: Sendable {
    private let supabaseURL: URL
    private let anonKey: String
    private let session: URLSession

    public init(supabaseURL: URL, anonKey: String, session: URLSession = .shared) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.session = session
    }

    /// POST /auth/v1/otp. `create_user: false` matters: without it GoTrue
    /// silently provisions a brand-new account for any typed-in email
    /// (web/js/auth.mjs's `magicLinkBody` doc comment). Reviewer/App
    /// Review sign-in is a separate flow (`ApiClient.reviewerLogin`) that
    /// doesn't go through GoTrue at all.
    public func requestOtp(email: String) async throws {
        struct Body: Encodable {
            let email: String
            let createUser: Bool
            enum CodingKeys: String, CodingKey {
                case email
                case createUser = "create_user"
            }
        }
        let body = try JSONEncoder().encode(Body(email: email, createUser: false))
        _ = try await send(path: "otp", body: body)
    }

    /// POST /auth/v1/verify — exchanges an emailed OTP code for a session.
    public func verifyOtp(email: String, code: String) async throws -> Session {
        struct Body: Encodable {
            let type: String
            let email: String
            let token: String
        }
        let body = try JSONEncoder().encode(Body(type: "email", email: email, token: code))
        let data = try await send(path: "verify", body: body)
        return try Self.parseSession(data)
    }

    /// POST /auth/v1/token?grant_type=refresh_token — trades a refresh
    /// token for a fresh access+refresh pair.
    public func refresh(refreshToken: String) async throws -> Session {
        struct Body: Encodable {
            let refreshToken: String
            enum CodingKeys: String, CodingKey {
                case refreshToken = "refresh_token"
            }
        }
        let body = try JSONEncoder().encode(Body(refreshToken: refreshToken))
        let data = try await send(
            path: "token", body: body,
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        return try Self.parseSession(data)
    }

    // MARK: - transport

    private func send(path: String, body: Data, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("auth/v1/\(path)"),
            resolvingAgainstBaseURL: true)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiError(status: 0, detail: .none)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ApiError(status: http.statusCode, detail: .text(Self.gotrueErrorDetail(data, http.statusCode)))
        }
        return data
    }

    /// GoTrue error bodies aren't consistent across endpoints/versions;
    /// tried in this order per the task brief: `error_description`,
    /// `msg`, `message`. Always resolves to a usable string, never the raw
    /// response object (web/js/auth.mjs's `gotrueErrorDetail` parity).
    private static func gotrueErrorDetail(_ data: Data, _ status: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "HTTP \(status)"
        }
        if let s = object["error_description"] as? String { return s }
        if let s = object["msg"] as? String { return s }
        if let s = object["message"] as? String { return s }
        return "HTTP \(status)"
    }

    /// `{access_token, refresh_token?, expires_in, user:{id}}`. `expires_in`
    /// is a duration in seconds from the moment of THIS response, so
    /// `expiresAt` is computed relative to "now", not decoded verbatim.
    private static func parseSession(_ data: Data) throws -> Session {
        struct Resp: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: TimeInterval
            let user: User
            struct User: Decodable { let id: String }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resp = try decoder.decode(Resp.self, from: data)
        return Session(
            accessToken: resp.accessToken, refreshToken: resp.refreshToken,
            userId: resp.user.id, expiresAt: Date().addingTimeInterval(resp.expiresIn))
    }
}
