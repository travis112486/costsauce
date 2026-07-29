// Shared URLProtocol-based network stub for ApiClientTests/AuthTests.
//
// `URLProtocol` registration (`canInit`/`canonicalRequest`) is a CLASS-level
// mechanism -- there is no per-`URLSession` hook to hand it instance state
// -- so every test using this shares ONE process-wide responder slot.
// `withStub` makes that safe under Swift Testing's default parallel test
// execution: it's gated by `Gate`, a tiny actor-based async mutex (NOT a
// raw `NSLock`/`os_unfair_lock`, which on Darwin must be unlocked by the
// SAME THREAD that locked it -- an async body can hop threads across an
// `await`, which would make a raw lock's cross-await hold undefined
// behavior). Only one `withStub` body runs at a time, process-wide,
// regardless of which test/suite it's called from.
//
// `URLProtocol.startLoading()` receives a POST/PATCH body ONLY via
// `request.httpBodyStream` -- `request.httpBody` is reliably `nil` by the
// time the protocol sees it (verified empirically against this SDK's
// `URLSession`, not assumed) -- so `bodyData(for:)` below always drains
// the stream, never reads `.httpBody` as the primary path.

import Foundation

enum StubTransport {
    typealias Responder = @Sendable (URLRequest, Data?) -> (status: Int, headers: [String: String], body: Data)

    private actor Gate {
        private var locked = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !locked {
                locked = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                locked = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private static let gate = Gate()
    private static let stateLock = NSLock()
    private static nonisolated(unsafe) var currentResponder: Responder?
    private static nonisolated(unsafe) var captured: [(request: URLRequest, body: Data?)] = []

    /// Installs `responder` as the sole handler for any request made
    /// through a `makeSession()`-vended session while `body` runs, then
    /// tears it down again -- exclusively, even across concurrently
    /// running test functions/suites.
    static func withStub<T: Sendable>(
        _ responder: @escaping Responder,
        _ body: () async throws -> T
    ) async throws -> T {
        await gate.acquire()
        installResponder(responder)
        do {
            let result = try await body()
            installResponder(nil)
            await gate.release()
            return result
        } catch {
            installResponder(nil)
            await gate.release()
            throw error
        }
    }

    /// `NSLock.lock()`/`.unlock()` are unavailable directly inside an
    /// `async` function body (the compiler steers you toward exactly this
    /// pattern: a plain, non-async, scoped-locking helper) -- an `await`
    /// inside `withStub` can resume on a different thread, and a raw lock
    /// held across that hop would be unsound on Darwin (`os_unfair_lock`
    /// requires same-thread unlock). This helper is never itself `async`,
    /// so its lock/unlock pair is always acquired and released on one
    /// synchronous call stack.
    private static func installResponder(_ responder: Responder?) {
        stateLock.lock()
        currentResponder = responder
        if responder != nil {
            captured = []
        }
        stateLock.unlock()
    }

    /// Every request observed by the protocol during the current (or most
    /// recent) `withStub` call, oldest first, paired with its decoded body.
    static var recordedRequests: [(request: URLRequest, body: Data?)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captured
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Proto.self]
        return URLSession(configuration: config)
    }

    /// Convenience for building a canned JSON response.
    static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> (Int, [String: String], Data) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        var h = headers
        h["Content-Type"] = "application/json"
        return (status, h, data)
    }

    private static func record(_ request: URLRequest, body: Data?) {
        stateLock.lock()
        captured.append((request, body))
        stateLock.unlock()
    }

    private static func responder() -> Responder? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentResponder
    }

    private static func bodyData(for request: URLRequest) -> Data? {
        if let d = request.httpBody { return d }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: bufferSize)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private final class Proto: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = StubTransport.bodyData(for: request)
            StubTransport.record(request, body: body)
            guard let responder = StubTransport.responder() else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let (status, headers, responseBody) = responder(request, body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}

/// A tiny thread-safe box for test closures that need to capture a result
/// out of a `@Sendable` responder (which can't capture a plain `var` from
/// its enclosing test function under strict concurrency checking).
/// Takes its initial value directly (rather than defaulting to `nil` for
/// an implicit `T?`) so `Captured<String?>` stores a single-level
/// `String?`, not a confusing `String??`.
final class Captured<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        storage = initial
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
