// The CostSauce session store — Keychain-backed `Session` persistence.
//
// `KeychainBacking` is the seam that keeps `swift test` from ever touching
// a real device keychain: tests inject `InMemoryBacking`, production code
// gets the default `SecItemBacking`. Both implementations live in this
// file so `KeychainStore`'s default `init` never has to reach outside it.

import Foundation
import Security

public protocol KeychainBacking: Sendable {
    func set(_ d: Data)
    func get() -> Data?
    func remove()
}

/// Thread-safe in-memory stand-in for a real keychain, for tests (and any
/// other host, e.g. a macOS unit-test run, that shouldn't touch the
/// device's actual Keychain).
public final class InMemoryBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?

    public init() {}

    public func set(_ d: Data) {
        lock.lock()
        storage = d
        lock.unlock()
    }

    public func get() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func remove() {
        lock.lock()
        storage = nil
        lock.unlock()
    }
}

/// `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` against a single
/// generic-password item keyed by `service`. Compiles and runs on macOS
/// too (the Security framework's SecItem API is cross-platform), but
/// `KeychainStore`'s default `init` is the only production caller —
/// `swift test` always supplies `InMemoryBacking` instead (see
/// `AuthTests`), so this code path is never exercised by the test suite.
struct SecItemBacking: KeychainBacking {
    let service: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    func set(_ d: Data) {
        // Overwrite semantics: delete-then-add rather than SecItemUpdate,
        // so `set` never has to reconcile the item's OTHER attributes
        // (Accessible/Synchronizable) with whatever a prior `add` used —
        // there is exactly one writer of this item's shape (this type).
        remove()
        var query = baseQuery
        query[kSecValueData as String] = d
        // §13 (REQUIRED): survives an unlock-then-relock but never leaves
        // the device, and isn't readable before first unlock after boot.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        SecItemAdd(query as CFDictionary, nil)
    }

    func get() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

public struct KeychainStore: Sendable {
    private let backing: KeychainBacking

    public init(service: String = "com.costsauce.session", backing: KeychainBacking? = nil) {
        self.backing = backing ?? SecItemBacking(service: service)
    }

    public func save(_ s: Session) throws {
        let data = try JSONEncoder().encode(s)
        backing.set(data)
    }

    public func load() -> Session? {
        guard let data = backing.get() else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func wipe() {
        backing.remove()
    }
}
