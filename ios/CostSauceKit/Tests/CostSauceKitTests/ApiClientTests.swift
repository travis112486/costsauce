import Testing
import Foundation
@testable import CostSauceKit

@Suite(.serialized)
struct ApiClientTests {
    let baseURL = URL(string: "https://api.test")!

    /// Asserts `body` throws an `ApiError`, returning it for further
    /// inspection (same "typed do/catch helper" shape as
    /// LocalEditsTests.expectEditError / StoreTests.expectStoreError,
    /// adapted for an `async throws` body).
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

    private func unsignedJWT(sub: String, expiresInSeconds: Int = 3600) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = segment(["alg": "HS256", "typ": "JWT"])
        let payload = segment([
            "sub": sub, "aud": "authenticated", "iss": "costsauce",
            "exp": Int(Date().timeIntervalSince1970) + expiresInSeconds,
        ])
        return "\(header).\(payload).unsigned-test-signature"
    }

    // MARK: - Bearer header

    @Test func bearerHeaderPresentWithTokenAbsentWithout() async throws {
        let seenWithToken = Captured<String?>(nil)
        let clientWithToken = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok-123" }
        _ = try await StubTransport.withStub({ request, _ in
            seenWithToken.value = request.value(forHTTPHeaderField: "Authorization")
            return StubTransport.json(200, ["supabase_url": "https://x.example", "supabase_anon_key": "anon"])
        }) {
            try await clientWithToken.config()
        }
        #expect(seenWithToken.value == "Bearer tok-123")

        let seenWithoutToken = Captured<String?>(nil)
        let clientNoToken = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { nil }
        _ = try await StubTransport.withStub({ request, _ in
            seenWithoutToken.value = request.value(forHTTPHeaderField: "Authorization")
            return StubTransport.json(200, ["supabase_url": NSNull(), "supabase_anon_key": NSNull()])
        }) {
            try await clientNoToken.config()
        }
        #expect(seenWithoutToken.value == nil)
    }

    // MARK: - AppConfig's acronym-casing regression coverage

    @Test func configDecodesSupabaseURLDespiteAcronymCasing() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { nil }
        let config = try await StubTransport.withStub({ _, _ in
            StubTransport.json(200, ["supabase_url": "https://proj.supabase.co", "supabase_anon_key": "anon-key"])
        }) {
            try await client.config()
        }
        #expect(config.supabaseURL == "https://proj.supabase.co")
        #expect(config.supabaseAnonKey == "anon-key")
    }

    // MARK: - error message selection

    @Test func the422ListBodySelectsFirstMessage() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let error = await expectApiError {
            _ = try await StubTransport.withStub({ _, _ in
                StubTransport.json(422, [
                    "detail": [
                        ["loc": ["body", "email"], "msg": "field required", "type": "missing"],
                        ["loc": ["body", "role"], "msg": "should not appear", "type": "missing"],
                    ]
                ])
            }) {
                try await client.me()
            }
        }
        #expect(error?.status == 422)
        #expect(error?.message == "field required")
        #expect(error?.detail == .validationList(["field required", "should not appear"]))
    }

    @Test func nested409DuplicateBodyDecodesToObjectDetail() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let error = await expectApiError {
            _ = try await StubTransport.withStub({ _, _ in
                StubTransport.json(409, [
                    "detail": ["detail": "duplicate", "matches": [["id": "ing-1", "name": "Flour"]]]
                ])
            }) {
                try await client.me()
            }
        }
        #expect(error?.status == 409)
        #expect(error?.message == "duplicate")
        #expect(error?.detail == .object(["detail": "duplicate"]))
    }

    @Test func nested409LastOwnerBodyDecodesToObjectDetail() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let error = await expectApiError {
            _ = try await StubTransport.withStub({ _, _ in
                StubTransport.json(409, [
                    "detail": [
                        "detail": "You are the last owner of an organization. Delete the organization, or transfer ownership first.",
                        "orgs_requiring_deletion": ["org-1"],
                    ]
                ])
            }) {
                try await client.me()
            }
        }
        #expect(error?.status == 409)
        #expect(
            error?.message
                == "You are the last owner of an organization. Delete the organization, or transfer ownership first.")
    }

    @Test func plainTextDetailIsVerbatim() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let error = await expectApiError {
            _ = try await StubTransport.withStub({ _, _ in
                StubTransport.json(404, ["detail": "organization not found"])
            }) {
                try await client.me()
            }
        }
        #expect(error?.status == 404)
        #expect(error?.detail == .text("organization not found"))
        #expect(error?.message == "organization not found")
    }

    // MARK: - patchLocation

    @Test func patchLocationOmitsNilFieldsFromBody() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let capturedBody = Captured<Data?>(nil)
        let result = try await StubTransport.withStub({ _, body in
            capturedBody.value = body
            return StubTransport.json(
                200,
                ["id": "loc-1", "name": "Main", "target_fc_pct": "31.00", "drift_threshold_pct": "3.00"])
        }) {
            try await client.patchLocation(id: "loc-1", name: nil, targetFcPct: "31.00", driftThresholdPct: nil)
        }
        #expect(result.targetFcPct == "31.00")

        let raw = try #require(capturedBody.value)
        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(object.count == 1)
        #expect(object["target_fc_pct"] as? String == "31.00")
        #expect(object["name"] == nil)
        #expect(object["drift_threshold_pct"] == nil)
    }

    // MARK: - syncPull

    @Test func syncPullDecodesTwoTablePageFixture() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        // Shapes copied from tests/test_sync_pull.py / api/services/sync.py's
        // _PULL key lists for ingredients + purchases.
        let fixture: [String: Any] = [
            "changes": [
                [
                    "table": "ingredients",
                    "row": [
                        "id": "ing-1", "location_id": "loc-1", "name": "Flour", "base_unit": "lb",
                        "vendor": NSNull(), "category": NSNull(), "source": NSNull(),
                        "client_mutated_at": "2026-07-01 10:00:00+00", "server_seq": 1,
                        "updated_at": "2026-07-01 10:00:00+00", "deleted_at": NSNull(),
                        "created_at": "2026-07-01 10:00:00+00",
                    ],
                ],
                [
                    "table": "purchases",
                    "row": [
                        "id": "pur-1", "location_id": "loc-1", "ingredient_id": "ing-1",
                        "purchased_on": "2026-07-01", "recorded_at": "2026-07-01 10:05:00+00",
                        "qty": "5", "unit": "lb", "qty_in_case": NSNull(), "qty_base_units": "5.0000",
                        "total_price": "20.00", "unit_price": "4.000000", "source": NSNull(),
                        "client_mutated_at": "2026-07-01 10:05:00+00", "server_seq": 2,
                        "updated_at": "2026-07-01 10:05:00+00", "deleted_at": NSNull(),
                        "created_at": "2026-07-01 10:05:00+00",
                    ],
                ],
            ],
            "cursor": 2,
            "has_more": false,
        ]
        // `[String: Any]` isn't Sendable, so the fixture is turned into
        // `Data` (which is) BEFORE the `@Sendable` responder closure
        // captures anything -- the closure below only ever closes over
        // Sendable values.
        let canned = StubTransport.json(200, fixture)
        let response = try await StubTransport.withStub({ _, _ in
            canned
        }) {
            try await client.syncPull(orgId: "org-1", since: 0)
        }
        #expect(response.cursor == 2)
        #expect(response.hasMore == false)
        #expect(response.changes.count == 2)

        #expect(response.changes[0].table == "ingredients")
        let ingredientRow = response.changes[0].row
        #expect(ingredientRow["id"] == .string("ing-1"))
        #expect(ingredientRow["location_id"] == .string("loc-1"))
        #expect(ingredientRow["server_seq"] == .int(1))
        #expect(ingredientRow["vendor"] == .null)

        #expect(response.changes[1].table == "purchases")
        let purchaseRow = response.changes[1].row
        #expect(purchaseRow["total_price"] == .string("20.00"))
        #expect(purchaseRow["qty_base_units"] == .string("5.0000"))
        #expect(purchaseRow["server_seq"] == .int(2))
        #expect(purchaseRow["source"] == .null)
    }

    @Test func syncPullExhaustedCursorReturnsEmptyWithHasMoreFalse() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let response = try await StubTransport.withStub({ _, _ in
            StubTransport.json(200, ["changes": [], "cursor": 5, "has_more": false])
        }) {
            try await client.syncPull(orgId: "org-1", since: 5)
        }
        #expect(response.changes.isEmpty)
        #expect(response.cursor == 5)
        #expect(response.hasMore == false)
    }

    // MARK: - syncPush

    @Test func syncPushBodyPreservesExplicitNullFieldValue() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let capturedBody = Captured<Data?>(nil)
        let op = SyncOp(
            opId: "op-1", table: "purchases", rowId: "row-1", locationId: "loc-1",
            clientMutatedAt: "2026-07-01T10:00:00Z", fields: ["deleted_at": nil, "qty": "5"])

        let response = try await StubTransport.withStub({ _, body in
            capturedBody.value = body
            return StubTransport.json(
                200,
                ["results": [["status": "applied", "row_id": "row-1", "reason": NSNull(), "replayed": false]],
                 "cursor": 3])
        }) {
            try await client.syncPush(orgId: "org-1", batchId: "batch-1", ops: [op])
        }
        #expect(response.cursor == 3)
        #expect(response.results.first?.status == "applied")

        let raw = try #require(capturedBody.value)
        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let ops = try #require(object["ops"] as? [[String: Any]])
        let fields = try #require(ops.first?["fields"] as? [String: Any])
        #expect(fields["qty"] as? String == "5")
        // An explicit JSON `null` decodes to `NSNull`, not a missing key --
        // a dropped-dictionary-nil bug would make this subscript `nil`
        // instead.
        #expect(fields["deleted_at"] is NSNull)
        #expect(fields.count == 2)
    }

    // MARK: - onUnauthorized

    @Test func onUnauthorizedFiresExactlyOnceOn401ThenThrows() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let callCount = Captured<Int>(0)
        client.onUnauthorized = {
            callCount.value += 1
        }

        let error = await expectApiError {
            _ = try await StubTransport.withStub({ _, _ in
                StubTransport.json(401, ["detail": "invalid token"])
            }) {
                try await client.me()
            }
        }
        #expect(callCount.value == 1)
        #expect(error?.status == 401)
        #expect(error?.message == "invalid token")
    }

    @Test func onUnauthorizedDoesNotFireOnA200() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let callCount = Captured<Int>(0)
        client.onUnauthorized = {
            callCount.value += 1
        }
        _ = try await StubTransport.withStub({ _, _ in
            StubTransport.json(200, ["supabase_url": NSNull(), "supabase_anon_key": NSNull()])
        }) {
            try await client.config()
        }
        #expect(callCount.value == 0)
    }

    // MARK: - reviewerLogin

    @Test func reviewerLoginDecodesSubFromUnsignedCheckedJWTAndSetsHourExpiry() async throws {
        let sub = "3a9b6c9e-8f2d-4c39-9c39-1f6a9c9b7e11"
        let jwt = unsignedJWT(sub: sub)
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { nil }

        let session = try await StubTransport.withStub({ _, _ in
            StubTransport.json(200, ["access_token": jwt])
        }) {
            try await client.reviewerLogin(email: "reviewer@example.test", code: "123456")
        }

        #expect(session.accessToken == jwt)
        #expect(session.refreshToken == nil)
        #expect(session.userId == sub)
        let secondsUntilExpiry = session.expiresAt.timeIntervalSinceNow
        #expect(secondsUntilExpiry > 3500 && secondsUntilExpiry <= 3600)
    }

    // MARK: - exportOrg

    @Test func exportOrgReturnsRawBytesUntouched() async throws {
        let client = ApiClient(baseURL: baseURL, session: StubTransport.makeSession()) { "tok" }
        let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01, 0x02, 0xFF])
        let result = try await StubTransport.withStub({ _, _ in
            (200, ["Content-Type": "application/zip"], payload)
        }) {
            try await client.exportOrg(orgId: "org-1")
        }
        #expect(result == payload)
    }
}
