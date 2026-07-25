import Testing
import Foundation
@testable import SeedkeepKit

/// Request-contract tests for the account-deletion transfer routes
/// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md`
/// § "Coordination API", implemented server-side in
/// `seedkeep-server/src/routes/account-deletion-transfers.ts`, mounted at
/// `/api/account-deletion`).
///
/// These routes coordinate an IRREVERSIBLE zone deletion across two
/// devices, so the client half is pinned harder than the usual CRUD
/// surface: every test asserts the exact method, the exact path, and the
/// exact JSON body keys. A body key the server's `.strict()` Zod schema
/// does not know is a 400 at the worst possible moment (mid-transfer,
/// after the successor already built a destination), and a missing key is
/// a phase that never advances.
///
/// The suite is `.serialized` because the stub keeps global static state.
@Suite("Account-deletion transfer client contract", .serialized)
struct AccountDeletionTransferClientTests {

    // MARK: - Fixtures

    private static let baseURL = URL(string: "https://api.test.local")!

    /// A fully populated transfer row as `ok()` in the server route
    /// serializes it — every nullable column carries a value so decoding
    /// the optional fields is actually exercised.
    private static let fullTransferJSON = #"""
    {"ok":true,"data":{"transfer":{
      "id":"tr_abc123",
      "source_household_id":"hh_1",
      "owner_user_id":"u_owner",
      "successor_user_id":"u_succ",
      "phase":"verified",
      "handoff_expires_at":1900000000000,
      "handoff_consumed_at":1800000000000,
      "destination_zone_name":"household-hh_1",
      "destination_zone_owner_name":"_succ_owner",
      "destination_share_record_name":"share_dest",
      "destination_share_url":"https://www.icloud.com/share/0abc",
      "owner_digest":{"digest":"aa11","record_counts":{"Seed":3,"Bed":1},"submitted_at":1700000000000},
      "successor_digest":{"digest":"aa11","record_counts":{"Seed":3,"Bed":1},"submitted_at":1700000000001},
      "created_at":1600000000000,
      "updated_at":1700000000002,
      "cancelled_at":1700000000003
    },"handoff_token":null}}
    """#

    /// The same envelope with every nullable column null — the shape a
    /// freshly created transfer actually comes back as, plus the raw
    /// handoff token that only `POST /transfers` ever returns.
    private static let freshTransferJSON = #"""
    {"ok":true,"data":{"transfer":{
      "id":"tr_new",
      "source_household_id":"hh_1",
      "owner_user_id":"u_owner",
      "successor_user_id":null,
      "phase":"pending_successor",
      "handoff_expires_at":1900000000000,
      "handoff_consumed_at":null,
      "destination_zone_name":null,
      "destination_zone_owner_name":null,
      "destination_share_record_name":null,
      "destination_share_url":null,
      "owner_digest":null,
      "successor_digest":null,
      "created_at":1600000000000,
      "updated_at":1600000000000,
      "cancelled_at":null
    },"handoff_token":"raw-handoff-token-value"}}
    """#

    private func makeClient(responseBody: String, status: Int = 200) -> SeedkeepClient {
        let session = TransferStub.makeSession(responseBody: Data(responseBody.utf8), status: status)
        return SeedkeepClient(
            configuration: .init(baseURL: Self.baseURL, session: session),
            bearerToken: "tok_test"
        )
    }

    /// Asserts method + path (no query leakage, no percent-encoded `?`)
    /// and that the call carried the bearer token. Every route in this
    /// family is authenticated (`requireAuth()` server-side).
    private func assertRequest(
        method: String,
        path expectedPath: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> URLRequest {
        let req = try #require(TransferStub.lastRequest(), "no request captured", sourceLocation: sourceLocation)
        #expect(req.httpMethod == method,
                "expected \(method), got \(req.httpMethod ?? "nil")",
                sourceLocation: sourceLocation)
        let path = req.url?.path ?? ""
        #expect(path == expectedPath, "expected path \(expectedPath), got \(path)", sourceLocation: sourceLocation)
        #expect(!path.contains("%3F"), "percent-encoded '?' in path: \(path)", sourceLocation: sourceLocation)
        #expect(!path.contains("?"), "raw '?' in path: \(path)", sourceLocation: sourceLocation)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok_test",
                "transfer routes are authenticated; bearer token missing",
                sourceLocation: sourceLocation)
        return req
    }

    /// Decoded JSON body of the captured request, so key-for-key
    /// assertions read like the server's Zod schema.
    private func capturedBody(sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let data = try #require(TransferStub.lastBody(), "no request body captured", sourceLocation: sourceLocation)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any], "body was not a JSON object", sourceLocation: sourceLocation)
    }

    // MARK: - POST /transfers

    @Test("create: POST /api/account-deletion/transfers, returns transfer + raw handoff token")
    func createTransfer() async throws {
        let client = makeClient(responseBody: Self.freshTransferJSON)
        let result = try await client.createAccountDeletionTransfer()

        _ = try assertRequest(method: "POST", path: "/api/account-deletion/transfers")
        #expect(result.transfer.id == "tr_new")
        #expect(result.transfer.phase == .pendingSuccessor)
        #expect(result.transfer.successor_user_id == nil)
        #expect(result.transfer.handoff_expires_at == 1_900_000_000_000)
        #expect(result.handoff_token == "raw-handoff-token-value")
    }

    @Test("create on resume: handoff_token null decodes as nil, transfer still readable")
    func createTransferResume() async throws {
        let client = makeClient(responseBody: Self.fullTransferJSON)
        let result = try await client.createAccountDeletionTransfer()
        #expect(result.handoff_token == nil)
        #expect(result.transfer.phase == .verified)
    }

    // MARK: - POST /transfers/:id/accept

    @Test("accept: POST .../accept with {token}, token never on the URL")
    func acceptTransfer() async throws {
        let client = makeClient(responseBody: Self.fullTransferJSON)
        _ = try await client.acceptAccountDeletionTransfer(id: "tr_abc123", token: "raw-handoff-token-value")

        let req = try assertRequest(method: "POST", path: "/api/account-deletion/transfers/tr_abc123/accept")
        let body = try capturedBody()
        #expect(Set(body.keys) == ["token"], "accept body is strict: only `token`; got \(Set(body.keys))")
        #expect(body["token"] as? String == "raw-handoff-token-value")

        // A single-use credential in a URL ends up in proxy logs and
        // crash reports. It travels in the body or not at all.
        let url = req.url?.absoluteString ?? ""
        #expect(!url.contains("raw-handoff-token-value"), "handoff token leaked into the URL: \(url)")
    }

    // MARK: - PUT /transfers/:id/destination

    @Test("destination: PUT .../destination with all four identifiers")
    func putDestination() async throws {
        let client = makeClient(responseBody: Self.fullTransferJSON)
        _ = try await client.putAccountDeletionTransferDestination(
            id: "tr_abc123",
            zoneName: "household-hh_1",
            zoneOwnerName: "_succ_owner",
            shareRecordName: "share_dest",
            shareURL: "https://www.icloud.com/share/0abc"
        )

        _ = try assertRequest(method: "PUT", path: "/api/account-deletion/transfers/tr_abc123/destination")
        let body = try capturedBody()
        #expect(Set(body.keys) == [
            "destination_zone_name",
            "destination_zone_owner_name",
            "destination_share_record_name",
            "destination_share_url",
        ], "unexpected destination body keys: \(Set(body.keys))")
        #expect(body["destination_zone_name"] as? String == "household-hh_1")
        #expect(body["destination_zone_owner_name"] as? String == "_succ_owner")
        #expect(body["destination_share_record_name"] as? String == "share_dest")
        #expect(body["destination_share_url"] as? String == "https://www.icloud.com/share/0abc")
    }

    @Test("destination without a share URL: the key is OMITTED, never null")
    func putDestinationOmitsNilShareURL() async throws {
        // `destination_share_url` is `z.string().optional()` inside a
        // `.strict()` object: an explicit null is a 400, absence is fine.
        let client = makeClient(responseBody: Self.fullTransferJSON)
        _ = try await client.putAccountDeletionTransferDestination(
            id: "tr_abc123",
            zoneName: "household-hh_1",
            zoneOwnerName: "_succ_owner",
            shareRecordName: "share_dest",
            shareURL: nil
        )
        let body = try capturedBody()
        #expect(body["destination_share_url"] == nil,
                "nil share URL must be omitted, not encoded as null")
        #expect(Set(body.keys) == [
            "destination_zone_name",
            "destination_zone_owner_name",
            "destination_share_record_name",
        ])
    }

    // MARK: - PUT /transfers/:id/owner-verification

    @Test("owner verification: PUT .../owner-verification with {digest, record_counts}")
    func putOwnerVerification() async throws {
        let client = makeClient(responseBody: Self.fullTransferJSON)
        _ = try await client.putAccountDeletionTransferOwnerVerification(
            id: "tr_abc123",
            digest: String(repeating: "a", count: 64),
            recordCounts: ["Seed": 3, "Bed": 1]
        )

        _ = try assertRequest(method: "PUT", path: "/api/account-deletion/transfers/tr_abc123/owner-verification")
        let body = try capturedBody()
        #expect(Set(body.keys) == ["digest", "record_counts"],
                "owner-verification body is strict; got \(Set(body.keys))")
        #expect(body["digest"] as? String == String(repeating: "a", count: 64))
        #expect(body["record_counts"] as? [String: Int] == ["Seed": 3, "Bed": 1])
    }

    // MARK: - PUT /transfers/:id/successor-verification

    @Test("successor verification: PUT .../successor-verification adds the zone ownership proof")
    func putSuccessorVerification() async throws {
        let client = makeClient(responseBody: Self.fullTransferJSON)
        _ = try await client.putAccountDeletionTransferSuccessorVerification(
            id: "tr_abc123",
            digest: String(repeating: "b", count: 64),
            recordCounts: ["Seed": 3],
            destinationZoneName: "household-hh_1",
            destinationZoneOwnerName: "_succ_owner"
        )

        _ = try assertRequest(method: "PUT", path: "/api/account-deletion/transfers/tr_abc123/successor-verification")
        let body = try capturedBody()
        #expect(Set(body.keys) == [
            "digest",
            "record_counts",
            "destination_zone_name",
            "destination_zone_owner_name",
        ], "unexpected successor-verification body keys: \(Set(body.keys))")
        #expect(body["digest"] as? String == String(repeating: "b", count: 64))
        #expect(body["record_counts"] as? [String: Int] == ["Seed": 3])
        #expect(body["destination_zone_name"] as? String == "household-hh_1")
        #expect(body["destination_zone_owner_name"] as? String == "_succ_owner")
    }

    // MARK: - POST /transfers/:id/source-deleted

    @Test("source deleted: POST .../source-deleted")
    func markSourceDeleted() async throws {
        let client = makeClient(responseBody: Self.fullTransferJSON)
        let transfer = try await client.markAccountDeletionTransferSourceDeleted(id: "tr_abc123")
        _ = try assertRequest(method: "POST", path: "/api/account-deletion/transfers/tr_abc123/source-deleted")
        #expect(transfer.id == "tr_abc123")
    }

    // MARK: - GET /transfers/:id

    @Test("resume: GET .../:id decodes every optional field")
    func fetchTransfer() async throws {
        let client = makeClient(responseBody: Self.fullTransferJSON)
        let transfer = try await client.accountDeletionTransfer(id: "tr_abc123")

        _ = try assertRequest(method: "GET", path: "/api/account-deletion/transfers/tr_abc123")
        #expect(transfer.successor_user_id == "u_succ")
        #expect(transfer.handoff_consumed_at == 1_800_000_000_000)
        #expect(transfer.destination_zone_name == "household-hh_1")
        #expect(transfer.destination_zone_owner_name == "_succ_owner")
        #expect(transfer.destination_share_record_name == "share_dest")
        #expect(transfer.destination_share_url == "https://www.icloud.com/share/0abc")
        #expect(transfer.owner_digest?.digest == "aa11")
        #expect(transfer.owner_digest?.record_counts == ["Seed": 3, "Bed": 1])
        #expect(transfer.owner_digest?.submitted_at == 1_700_000_000_000)
        #expect(transfer.successor_digest?.submitted_at == 1_700_000_000_001)
        #expect(transfer.created_at == 1_600_000_000_000)
        #expect(transfer.updated_at == 1_700_000_000_002)
        #expect(transfer.cancelled_at == 1_700_000_000_003)
    }

    @Test("fresh transfer: every nullable column decodes to nil")
    func fetchFreshTransfer() async throws {
        let client = makeClient(responseBody: Self.freshTransferJSON)
        let transfer = try await client.accountDeletionTransfer(id: "tr_new")
        #expect(transfer.successor_user_id == nil)
        #expect(transfer.handoff_consumed_at == nil)
        #expect(transfer.destination_zone_name == nil)
        #expect(transfer.destination_zone_owner_name == nil)
        #expect(transfer.destination_share_record_name == nil)
        #expect(transfer.destination_share_url == nil)
        #expect(transfer.owner_digest == nil)
        #expect(transfer.successor_digest == nil)
        #expect(transfer.cancelled_at == nil)
    }

    // MARK: - DELETE /transfers/:id

    @Test("cancel: DELETE .../:id")
    func cancelTransfer() async throws {
        let client = makeClient(responseBody: Self.fullTransferJSON)
        _ = try await client.cancelAccountDeletionTransfer(id: "tr_abc123")
        _ = try assertRequest(method: "DELETE", path: "/api/account-deletion/transfers/tr_abc123")
    }

    // MARK: - DELETE /api/me — CloudKit disposition

    /// The server's `deleteAccountBody` is a strict Zod object requiring
    /// `cloudkit_disposition`; there is no default, and an absent or
    /// unrecognized value is a 400 (`cloudkit_disposition_required`).
    /// A bodyless DELETE therefore fails AFTER the CloudKit garden may
    /// already have been irreversibly deleted — which is why the exact
    /// bytes are pinned here, not just the method and path.
    @Test(
        "deleteAccount sends the exact disposition body; transfer_id only for the transfer case",
        arguments: [
            (AccountDeletionDisposition.noCloudKitGarden, "no_cloudkit_garden", String?.none),
            (.participantLeftShare, "participant_left_share", nil),
            (.ownerZoneDeleted, "owner_zone_deleted", nil),
            (.transferSourceDeleted(transferID: "tr_abc123"), "transfer_source_deleted", "tr_abc123"),
        ]
    )
    func deleteAccountDisposition(
        disposition: AccountDeletionDisposition,
        wire: String,
        transferID: String?
    ) async throws {
        let client = makeClient(responseBody: #"{"ok":true,"data":{"deleted":true}}"#)
        let deleted = try await client.deleteAccount(disposition: disposition)
        #expect(deleted)

        _ = try assertRequest(method: "DELETE", path: "/api/me")
        let body = try capturedBody()
        #expect(body["cloudkit_disposition"] as? String == wire)
        if let transferID {
            #expect(Set(body.keys) == ["cloudkit_disposition", "transfer_id"])
            #expect(body["transfer_id"] as? String == transferID)
        } else {
            #expect(Set(body.keys) == ["cloudkit_disposition"],
                    "transfer_id must be omitted, not null, for \(wire)")
        }
    }

    @Test("the transfer disposition cannot be expressed without a transfer id")
    func transferDispositionCarriesID() {
        // Type-level guarantee: the id is an associated value, so there is
        // no way to claim a completed handoff without naming the transfer
        // the server must check.
        #expect(AccountDeletionDisposition.transferSourceDeleted(transferID: "tr_1").transferID == "tr_1")
        #expect(AccountDeletionDisposition.ownerZoneDeleted.transferID == nil)
        #expect(AccountDeletionDisposition.participantLeftShare.transferID == nil)
        #expect(AccountDeletionDisposition.noCloudKitGarden.transferID == nil)
    }

    @Test("400 cloudkit_disposition_required surfaces as a typed error, not a silent success")
    func deleteAccountRejected() async throws {
        let refusal = #"""
        {"ok":false,"error":{"code":"cloudkit_disposition_required","message":"Finish the iCloud garden step first, then send cloudkit_disposition with the deletion request."}}
        """#
        let client = makeClient(responseBody: refusal, status: 400)
        do {
            _ = try await client.deleteAccount(disposition: .ownerZoneDeleted)
            Issue.record("a refused deletion must throw")
        } catch let error as SeedkeepError {
            #expect(error.code == "cloudkit_disposition_required")
            #expect(error.httpStatus == 400)
        }
    }

    @Test("409 cloudkit_transfer_required surfaces as a typed error")
    func deleteAccountBlockedByTransfer() async throws {
        let refusal = #"""
        {"ok":false,"error":{"code":"cloudkit_transfer_required","message":"A shared-garden transfer is in progress. Finish or cancel it before deleting this account."}}
        """#
        let client = makeClient(responseBody: refusal, status: 409)
        do {
            _ = try await client.deleteAccount(disposition: .ownerZoneDeleted)
            Issue.record("a blocked deletion must throw")
        } catch let error as SeedkeepError {
            #expect(error.code == "cloudkit_transfer_required")
            #expect(error.httpStatus == 409)
        }
    }

    // MARK: - Phase enum

    @Test("phase enum covers the server's phase list, raw values verbatim")
    func phaseRawValues() throws {
        // Mirrors `TRANSFER_PHASES` in account-deletion-transfers.ts. A
        // phase the client cannot name is a phase it cannot resume from.
        let expected = [
            "pending_successor",
            "successor_bound",
            "destination_ready",
            "owner_verified",
            "verified",
            "source_deleted",
            "cancelled",
        ]
        #expect(AccountDeletionTransferPhase.allCases.map(\.rawValue) == expected)
        for raw in expected {
            let phase = try #require(AccountDeletionTransferPhase(rawValue: raw))
            #expect(phase.rawValue == raw)
        }
    }

    @Test("unknown phase fails decoding instead of silently becoming a known one")
    func unknownPhaseFailsClosed() async throws {
        // A newer server phase must surface as an error the coordinator
        // can stop on — never be coerced into a phase that would let it
        // advance toward deleting the source zone.
        let body = Self.freshTransferJSON.replacingOccurrences(
            of: #""phase":"pending_successor""#,
            with: #""phase":"teleported""#
        )
        let client = makeClient(responseBody: body)
        await #expect(throws: SeedkeepError.self) {
            _ = try await client.accountDeletionTransfer(id: "tr_new")
        }
    }

    // MARK: - Error envelope

    @Test("409 phase conflict: code, message and durable phase all survive")
    func phaseConflictError() async throws {
        let conflict = #"""
        {"ok":false,"error":{"code":"phase_conflict","message":"Transfer is in phase 'verified'. Reload and continue from there.","phase":"verified"}}
        """#
        let client = makeClient(responseBody: conflict, status: 409)
        do {
            _ = try await client.markAccountDeletionTransferSourceDeleted(id: "tr_abc123")
            Issue.record("expected the conflict envelope to throw")
        } catch let error as SeedkeepError {
            #expect(error.code == "phase_conflict")
            #expect(error.httpStatus == 409)
            #expect(error.conflictPhase == "verified",
                    "the server attaches the durable phase so the client resumes from it")
        }
    }

    @Test("403 without a phase: conflictPhase stays nil")
    func forbiddenErrorHasNoPhase() async throws {
        let forbidden = #"""
        {"ok":false,"error":{"code":"forbidden","message":"You are not a party to this transfer with that role."}}
        """#
        let client = makeClient(responseBody: forbidden, status: 403)
        do {
            _ = try await client.cancelAccountDeletionTransfer(id: "tr_abc123")
            Issue.record("expected the forbidden envelope to throw")
        } catch let error as SeedkeepError {
            #expect(error.code == "forbidden")
            #expect(error.httpStatus == 403)
            #expect(error.conflictPhase == nil)
        }
    }
}

// MARK: - Body-capturing URLProtocol stub

/// Captures method, URL and BODY of the most recent request. URLSession
/// hands request bodies to protocols via `httpBodyStream`, so
/// `request.httpBody` alone comes back nil — this drains the stream
/// (`BodyCaptureMockURLProtocol` in the app tests set the precedent).
/// Must be top-level so URLSession can register it.
final class TransferStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var captured: URLRequest?
    nonisolated(unsafe) private static var capturedBody: Data?
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var status = 200
    private static let lock = NSLock()

    static func makeSession(responseBody: Data, status: Int = 200) -> URLSession {
        lock.lock()
        captured = nil
        capturedBody = nil
        Self.responseBody = responseBody
        Self.status = status
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransferStub.self]
        return URLSession(configuration: config)
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func lastBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody
    }

    private static func drainBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured = request
        Self.capturedBody = Self.drainBody(request)
        let body = Self.responseBody
        let status = Self.status
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://test.local")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
