// The CostSauce API client — wire-format DTOs.
//
// Every response is decoded with `ApiClient`'s single shared `JSONDecoder`
// (`.keyDecodingStrategy = .convertFromSnakeCase`), and every request body
// with its matching shared `JSONEncoder` (`.convertToSnakeCase`). Both
// strategies round-trip a snake_case wire key into/out of the Swift
// property name automatically -- e.g. `org_id` <-> `orgId`, `max_members`
// <-> `maxMembers` -- for every property below EXCEPT `AppConfig.
// supabaseURL`. Foundation's converter turns `supabase_url` into
// `supabaseUrl` (a single capital U: it splits on `_` and title-cases each
// component, with no notion of "acronym"), which does not match the Swift
// API-guidelines spelling `supabaseURL` (all-caps acronym) this file
// freezes -- confirmed empirically (a plain `Codable` synthesis silently
// decodes it as `nil`, no error, since the property is `Optional`). That
// one property gets an explicit `CodingKeys` entry pinned to the
// POST-conversion string `"supabaseUrl"` (not the raw JSON key
// `"supabase_url"`, which the shared decoder's container is no longer
// keyed by once the strategy has run). No other property in this file
// carries an all-caps acronym, so nothing else needs an override.
//
// Server truth for these shapes: api/models.py:16-58 (EntitlementOut /
// MembershipOut / MeResponse), api/routes/locations.py (LocationOut wire
// dict), api/routes/members.py:160-191 (MemberOut wire dict), api/main.py:
// 162-167 (/config), api/services/sync.py:134-224 (SyncOpIn / pull page).

import Foundation

// MARK: - session

/// An authenticated session, however it was obtained (GoTrue magic-link/OTP
/// or the reviewer fixed-credential flow). `refreshToken` is `nil` for a
/// reviewer session (a 1h JWT with no refresh, api/routes/identity.py:
/// 283-287) -- `SessionController.refreshIfNeeded` treats that as a
/// standing no-op rather than an error. `Codable` for `KeychainStore`'s
/// own JSON round-trip through the keychain, not for any server wire
/// shape (the server never returns a `Session`-shaped body verbatim; both
/// `ApiClient.reviewerLogin` and `GoTrueClient`'s calls build one from
/// pieces of their own response bodies).
public struct Session: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let userId: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, userId: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userId = userId
        self.expiresAt = expiresAt
    }
}

// MARK: - /config

public struct AppConfig: Codable, Sendable {
    public let supabaseURL: String?
    public let supabaseAnonKey: String?

    enum CodingKeys: String, CodingKey {
        case supabaseURL = "supabaseUrl"
        case supabaseAnonKey
    }

    public init(supabaseURL: String?, supabaseAnonKey: String?) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }
}

// MARK: - /me

public struct Entitlement: Codable, Equatable, Sendable {
    public let plan: String
    public let maxLocations: Int
    public let maxInvoicesPerMonth: Int?
    public let maxRecipes: Int?
    public let maxMembers: Int

    public init(
        plan: String, maxLocations: Int, maxInvoicesPerMonth: Int?,
        maxRecipes: Int?, maxMembers: Int
    ) {
        self.plan = plan
        self.maxLocations = maxLocations
        self.maxInvoicesPerMonth = maxInvoicesPerMonth
        self.maxRecipes = maxRecipes
        self.maxMembers = maxMembers
    }
}

public struct Membership: Codable, Equatable, Sendable {
    public let orgId: String
    public let orgName: String
    public let role: String
    public let entitlement: Entitlement

    public init(orgId: String, orgName: String, role: String, entitlement: Entitlement) {
        self.orgId = orgId
        self.orgName = orgName
        self.role = role
        self.entitlement = entitlement
    }
}

public struct MeResponse: Codable, Sendable {
    public let userId: String
    public let contactEmail: String?
    public let contactEmailVerified: Bool
    public let appleLinked: Bool
    public let memberships: [Membership]

    public init(
        userId: String, contactEmail: String?, contactEmailVerified: Bool,
        appleLinked: Bool, memberships: [Membership]
    ) {
        self.userId = userId
        self.contactEmail = contactEmail
        self.contactEmailVerified = contactEmailVerified
        self.appleLinked = appleLinked
        self.memberships = memberships
    }
}

/// Exactly one membership is the only case resolvable without asking the
/// user; zero (not provisioned yet) and several (ambiguous) both mean
/// `nil`. Mirrors web/js/lib.mjs's `pickDefaultMembership`.
public func pickDefaultMembership(_ m: [Membership]) -> Membership? {
    m.count == 1 ? m[0] : nil
}

// MARK: - locations

public struct LocationOut: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let targetFcPct: String
    public let driftThresholdPct: String

    public init(id: String, name: String, targetFcPct: String, driftThresholdPct: String) {
        self.id = id
        self.name = name
        self.targetFcPct = targetFcPct
        self.driftThresholdPct = driftThresholdPct
    }
}

/// Same "exactly one -> it, else nil" rule as `pickDefaultMembership`.
public func pickDefaultLocation(_ l: [LocationOut]) -> LocationOut? {
    l.count == 1 ? l[0] : nil
}

// MARK: - members

public struct MemberOut: Codable, Equatable, Identifiable, Sendable {
    public let userId: String
    public let role: String
    public let contactEmail: String?
    public var id: String { userId }

    public init(userId: String, role: String, contactEmail: String?) {
        self.userId = userId
        self.role = role
        self.contactEmail = contactEmail
    }
}

// MARK: - sync push wire types

/// Built 1:1 from a `PendingOp` (Task 5's `Store/Records.swift`) for
/// `ApiClient.syncPush`. `fields` mirrors `PendingOp.fields` exactly,
/// explicit `nil`s included -- a `Dictionary<String, String?>`'s own
/// `Encodable` conformance already preserves `nil` as JSON `null` (verified
/// empirically: it does NOT use `encodeIfPresent` under the hood the way a
/// hand-rolled loop easily could by mistake), so no custom `encode(to:)`
/// is needed here to keep tombstone/clear-field ops honest.
public struct SyncOp: Encodable, Sendable {
    public let opId: String
    public let table: String
    public let rowId: String
    public let locationId: String
    public let clientMutatedAt: String
    public let fields: [String: String?]

    public init(
        opId: String, table: String, rowId: String, locationId: String,
        clientMutatedAt: String, fields: [String: String?]
    ) {
        self.opId = opId
        self.table = table
        self.rowId = rowId
        self.locationId = locationId
        self.clientMutatedAt = clientMutatedAt
        self.fields = fields
    }
}

public struct OpResult: Decodable, Equatable, Sendable {
    public let status: String
    public let rowId: String?
    public let reason: String?
    public let replayed: Bool?

    public init(status: String, rowId: String?, reason: String?, replayed: Bool?) {
        self.status = status
        self.rowId = rowId
        self.reason = reason
        self.replayed = replayed
    }
}

public struct SyncPushResponse: Decodable, Sendable {
    public let results: [OpResult]
    public let cursor: Int64

    public init(results: [OpResult], cursor: Int64) {
        self.results = results
        self.cursor = cursor
    }
}

// MARK: - sync pull wire types

/// Custom `Decodable`: the payload's `changes[].row` shape is an untyped
/// wire dict (`_PULL`'s per-table `jsonb_build_object` keys, api/services/
/// sync.py:154-195), not a fixed set of Swift properties, so it decodes
/// through `PullChange`/`SyncValue` (Task 5's `Store/Records.swift` --
/// NOT redefined here, only given a `Decodable` conformance below).
public struct SyncPullResponse: Sendable {
    public let changes: [PullChange]
    public let cursor: Int64
    public let hasMore: Bool

    public init(changes: [PullChange], cursor: Int64, hasMore: Bool) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

extension SyncPullResponse: Decodable {
    private enum RootKeys: String, CodingKey {
        case changes, cursor, hasMore
    }
    private enum ChangeKeys: String, CodingKey {
        case table, row
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        cursor = try root.decode(Int64.self, forKey: .cursor)
        hasMore = try root.decode(Bool.self, forKey: .hasMore)

        var changesContainer = try root.nestedUnkeyedContainer(forKey: .changes)
        var built: [PullChange] = []
        while !changesContainer.isAtEnd {
            let changeContainer = try changesContainer.nestedContainer(keyedBy: ChangeKeys.self)
            let table = try changeContainer.decode(String.self, forKey: .table)
            let row = try changeContainer.decode([String: SyncValue].self, forKey: .row)
            built.append(PullChange(table: table, row: row))
        }
        changes = built
    }
}

/// `server_seq` is the only integer field across all four `_PULL` tables;
/// everything else is a wire string or SQL NULL (Records.swift's own
/// `SyncValue` doc comment). Tries `Int64` before `String` so an integer
/// wire value never round-trips as a numeric-looking string by accident.
extension SyncValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let i = try? container.decode(Int64.self) {
            self = .int(i)
            return
        }
        self = .string(try container.decode(String.self))
    }
}

// MARK: - invoice page uploads (Phase 3a)

/// `POST /invoices/{id}/pages/{n}/upload-url` (api/routes/invoices.py's
/// `mint_upload_url`). `url` is pre-signed and scoped to the one object
/// path it was minted for; `expiresAt` is informational only -- the
/// uploader mints a fresh URL per attempt rather than checking it.
public struct SignedUpload: Codable, Sendable {
    public let url: String
    public let storagePath: String
    public let expiresAt: String

    public init(url: String, storagePath: String, expiresAt: String) {
        self.url = url
        self.storagePath = storagePath
        self.expiresAt = expiresAt
    }
}
