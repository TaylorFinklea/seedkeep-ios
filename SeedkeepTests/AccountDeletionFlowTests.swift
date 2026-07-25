import Testing
import Foundation
import CloudKit
import CryptoKit
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// End-to-end tests for account deletion over the REAL production seam:
/// `AccountDeletionCoordinator` → `LiveAccountDeletionServer` →
/// `SeedkeepClient` → HTTP, with a real `AuthController` and a real
/// `SyncEngine` eraser wired exactly as `AppEnvironment.live()` wires them.
///
/// These tests used to call `client.deleteAccount` and `auth.signOut()`
/// themselves and describe that as "the YouView sequence". It no longer is
/// — `YouView` calls `appEnv.accountDeletion.start()` — so the suite was
/// asserting a hand-rolled copy of a path that does not exist, and every
/// invariant the coordinator adds (mint and persist the receipt BEFORE the
/// destructive call, sign out only on server confirmation, recover a lost
/// response through the unauthenticated receipt lookup) was invisible to
/// it.
///
/// Only the CloudKit seam is substituted: a live one needs an iCloud
/// entitlement the test host does not have. Identity is supplied directly
/// for the same reason — production reads it from `auth.state`, which is
/// not what these tests are about.
@MainActor
@Suite("Account deletion flow (M5)", .serialized)
struct AccountDeletionFlowTests {

    private static let householdID = "hh_del"
    /// Fixed so the wire body can be checked against the exact value the
    /// coordinator persisted.
    private static let receiptNonce = "flow-receipt-nonce"

    static func hash(of nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A CloudKit seam that reports no iCloud garden. Every other method
    /// traps: reaching one would mean the coordinator picked a flow this
    /// account cannot be in.
    @MainActor
    private final class NoGardenCloudKit: AccountDeletionCloudKitOperating {
        func currentRole() async throws -> AccountDeletionCloudKitRole { .noGarden }
        func leaveSharedGarden(zoneID: CKRecordZone.ID) async throws {
            Issue.record("no CloudKit work is expected for an account with no garden")
        }
        func sharedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool { true }
        func deleteOwnedZone(zoneID: CKRecordZone.ID) async throws {
            Issue.record("no CloudKit work is expected for an account with no garden")
        }
        func ownedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool { true }
        func fetchRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] { [] }
        func saveRecords(_ records: [CKRecord],
                         policy: CKModifyRecordsOperation.RecordSavePolicy,
                         in zoneID: CKRecordZone.ID) async throws {}
        func acceptShare(at url: URL) async throws -> CKRecordZone.ID {
            CKRecordZone.default().zoneID
        }
        func createDestination(householdID: String, title: String) async throws
            -> AccountDeletionDestination {
            throw CancellationError()
        }
    }

    @MainActor
    private struct Harness {
        let coordinator: AccountDeletionCoordinator
        let auth: AuthController
        let store: AccountDeletionCheckpointStore
        let userID: String
        var storedCheckpoint: AccountDeletionCheckpoint? {
            try? store.load(userID: userID)?.checkpoint
        }
    }

    /// Wires the coordinator the way `AppEnvironment` does: real client,
    /// real auth, real eraser, real checkpoint store.
    @MainActor
    private static func makeHarness(
        client: SeedkeepClient,
        container: ModelContainer,
        tokenStore: InMemoryTokenStore,
        defaults: UserDefaults,
        userID: String = "u_del"
    ) -> Harness {
        let sync = SyncEngine(client: client, container: container)
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)
        auth.wireLocalDataEraser { [sync] in
            try? sync.eraseAllLocalData()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountDeletionFlowTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AccountDeletionCheckpointStore(directory: directory)
        let coordinator = AccountDeletionCoordinator(
            store: store,
            cloudKit: NoGardenCloudKit(),
            server: LiveAccountDeletionServer(client: client),
            session: AccountDeletionSession(
                identity: { .init(userID: userID, householdID: householdID) },
                localStoreOwnerID: { userID },
                signOut: { [weak auth] in await auth?.signOut() },
                adoptTransferredGarden: { _ in }
            ),
            now: { 1_700_000_000_000 },
            newReceipt: { receiptNonce }
        )
        return Harness(coordinator: coordinator, auth: auth, store: store, userID: userID)
    }

    private static func makeContainer(_ name: String) -> ModelContainer {
        makeTestContainer(name: name)
    }

    private static func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "AccountDeletionFlowTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Seeds several model types into the container so we can assert generic wipe.
    private static func seedContainer(_ container: ModelContainer) throws {
        let ctx = ModelContext(container)
        ctx.insert(LocalSeed(
            id: "seed_del_1",
            householdID: householdID,
            state: .active,
            packetCount: 2,
            source: .store,
            createdAt: 1, updatedAt: 1
        ))
        ctx.insert(LocalBed(
            id: "bed_del_1",
            householdID: householdID,
            name: "Raised bed",
            createdAt: 1, updatedAt: 1
        ))
        ctx.insert(LocalJournalEntry(
            id: "je_del_1",
            householdID: householdID,
            occurredOn: "2026-01-01",
            body: "first entry",
            seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: 1, updatedAt: 1, deletedAt: nil
        ))
        ctx.insert(LocalPendingWrite(
            id: "pw_del_1",
            entityType: "seed", entityID: "seed_del_1",
            operation: "update", payloadJSON: "{}",
            createdAt: 1
        ))
        ctx.insert(LocalSyncCursor(
            householdID: householdID,
            kind: "seeds",
            cursor: 999,
            lastSyncedAt: 1
        ))
        try ctx.save()
    }

    private static func cacheIdentity(
        _ defaults: UserDefaults, userID: String, householdID: String
    ) throws {
        let json = """
        {"user":{"id":"\(userID)","name":"Gardener","email":"g@example.com"},"household":{"id":"\(householdID)","name":"My household","created_at":1,"updated_at":1}}
        """
        _ = try JSONDecoder().decode(AuthController.CachedIdentity.self, from: Data(json.utf8))
        defaults.set(Data(json.utf8), forKey: AuthController.identityCacheKey)
    }

    // MARK: - Happy-path: deleteAccount succeeds → signOut wipes everything

    @Test("deleteAccount success: token cleared, identity cleared, all SwiftData rows wiped")
    func deleteAccountFullFlow() async throws {
        let container = Self.makeContainer("deleteAccountFull")
        let defaults = Self.makeDefaults("deleteAccountFull")
        let tokenStore = InMemoryTokenStore("tok_del")
        try Self.seedContainer(container)
        try Self.cacheIdentity(defaults, userID: "u_del", householdID: Self.householdID)

        // Stub DELETE /api/me → {ok:true,data:{deleted:true}}
        let session = AccountDeletionMockURLProtocol.makeSession(
            routes: [
                "DELETE /api/me": Data(
                    #"{"ok":true,"data":{"deleted":true}}"#.utf8
                )
            ]
        )
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "tok_del"
        )
        let harness = Self.makeHarness(client: client, container: container,
                                       tokenStore: tokenStore, defaults: defaults)

        let outcome = try await harness.coordinator.start()

        #expect(outcome == .deleted)
        let requestBody = try #require(AccountDeletionMockURLProtocol.body(for: "DELETE /api/me"))
        let body = try #require(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        #expect(Set(body.keys) == ["cloudkit_disposition", "deletion_receipt_hash"])
        #expect(body["cloudkit_disposition"] as? String == "no_cloudkit_garden")
        // The hash on the wire is the one the coordinator minted and wrote
        // down, not a value the test handed it — that is what makes the
        // deletion recoverable if this response never comes back.
        #expect(body["deletion_receipt_hash"] as? String == Self.hash(of: Self.receiptNonce))
        #expect(harness.storedCheckpoint == nil, "a completed deletion leaves no checkpoint")
        #expect(tokenStore.load() == nil, "signOut must clear the keychain token")
        #expect(harness.auth.loadCachedIdentity() == nil, "signOut must clear the cached identity")
        guard case .signedOut = harness.auth.state else {
            Issue.record("expected signedOut, got \(harness.auth.state)")
            return
        }

        // Verify every schema model's row count == 0.
        let fresh = ModelContext(container)
        let rowCounts = try rowCountsAllModels(context: fresh)
        for (name, count) in rowCounts {
            #expect(count == 0, "model \(name) must be empty after deletion but had \(count) row(s)")
        }
    }

    // MARK: - You ▸ Delete account presents a flow; it does not delete

    @Test("opening the deletion flow sends nothing; only confirming reaches DELETE /api/me")
    func openingTheFlowSendsNothing() async throws {
        // The button used to call the coordinator's one-shot delete
        // directly, which meant the destructive request left the device on
        // the same tap that opened the sheet. It now opens a progress flow
        // that asks first — so the wire must stay silent until the user
        // says yes, and then carry exactly one deletion.
        let container = Self.makeContainer("deleteAccountPresent")
        let defaults = Self.makeDefaults("deleteAccountPresent")
        let tokenStore = InMemoryTokenStore("tok_present")
        try Self.seedContainer(container)
        try Self.cacheIdentity(defaults, userID: "u_del", householdID: Self.householdID)

        let session = AccountDeletionMockURLProtocol.makeSession(
            routes: ["DELETE /api/me": Data(#"{"ok":true,"data":{"deleted":true}}"#.utf8)]
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "tok_present"
        )
        let harness = Self.makeHarness(client: client, container: container,
                                       tokenStore: tokenStore, defaults: defaults)
        let model = AccountDeletionFlowModel(coordinator: harness.coordinator)

        await model.prepare()

        #expect(model.stage == .confirming)
        #expect(AccountDeletionMockURLProtocol.requests().isEmpty,
                "presenting the flow must not send a single request")
        #expect(tokenStore.load() == "tok_present")

        await model.confirm()

        #expect(model.stage == .deleted)
        #expect(AccountDeletionMockURLProtocol.requests() == ["DELETE /api/me"])
        #expect(tokenStore.load() == nil)
    }

    // MARK: - Failure path: deleteAccount throws → signOut NOT reached

    @Test("deleteAccount RPC failure: token, identity, and SwiftData rows all intact")
    func deleteAccountRPCFailure() async throws {
        let container = Self.makeContainer("deleteAccountFail")
        let defaults = Self.makeDefaults("deleteAccountFail")
        let tokenStore = InMemoryTokenStore("tok_alive")
        try Self.seedContainer(container)
        try Self.cacheIdentity(defaults, userID: "u_alive", householdID: Self.householdID)

        // Stub DELETE /api/me → ok:false error (client decodes envelope; non-ok throws)
        let session = AccountDeletionMockURLProtocol.makeSession(
            routes: [
                "DELETE /api/me": Data(
                    #"{"ok":false,"error":{"code":"internal_error","message":"account deletion failed"}}"#.utf8
                )
            ],
            fallbackStatus: 500
        )
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "tok_alive"
        )
        let harness = Self.makeHarness(client: client, container: container,
                                       tokenStore: tokenStore, defaults: defaults)

        var threwError = false
        do {
            _ = try await harness.coordinator.start()
        } catch {
            threwError = true
        }

        #expect(threwError, "a non-ok response must surface, never be treated as deletion")
        #expect(tokenStore.load() == "tok_alive",
                "the token must survive a failed deletion")
        #expect(harness.auth.loadCachedIdentity() != nil,
                "cached identity must survive a failed deletion")
        // The receipt was minted and persisted BEFORE the destructive call,
        // so a retry — or a relaunch — can still find out what happened.
        let checkpoint = try #require(harness.storedCheckpoint)
        #expect(checkpoint.phase == .deletingAccount)
        #expect(checkpoint.deletionReceipt == Self.receiptNonce)
        // Auth state is still .signedOut (default) because adoptBearerToken was not called;
        // the key assertion is that rows are still present.

        let ctx = ModelContext(container)
        let seeds = try ctx.fetch(FetchDescriptor<LocalSeed>())
        let journals = try ctx.fetch(FetchDescriptor<LocalJournalEntry>())
        let pending = try ctx.fetch(FetchDescriptor<LocalPendingWrite>())
        let cursors = try ctx.fetch(FetchDescriptor<LocalSyncCursor>())
        #expect(!seeds.isEmpty, "seed rows must survive when deleteAccount() throws")
        #expect(!journals.isEmpty, "journal rows must survive when deleteAccount() throws")
        #expect(!pending.isEmpty, "pending writes must survive when deleteAccount() throws")
        #expect(!cursors.isEmpty, "sync cursors must survive when deleteAccount() throws")
    }

    // MARK: - Response loss: the deletion committed, the answer did not

    @Test("a deletion whose response was lost is finished through the receipt lookup")
    func lostResponseRecoveredOverHTTP() async throws {
        let container = Self.makeContainer("deleteAccountLost")
        let defaults = Self.makeDefaults("deleteAccountLost")
        let tokenStore = InMemoryTokenStore("tok_lost")
        try Self.seedContainer(container)
        try Self.cacheIdentity(defaults, userID: "u_del", householdID: Self.householdID)

        // The server committed the deletion and then the session it
        // cascaded made the response come back 401 — indistinguishable,
        // from the client's side, from an ordinary expired token. Only the
        // receipt route can tell them apart, and it is unauthenticated
        // precisely because there is no session left to present.
        let session = AccountDeletionMockURLProtocol.makeSession(
            routes: [
                "DELETE /api/me": Data(
                    #"{"ok":false,"error":{"code":"unauthorized","message":"no session"}}"#.utf8
                ),
                "POST /api/account-deletion/receipts/lookup": Data(
                    #"{"ok":true,"data":{"deleted":true,"deleted_at":1700000000100}}"#.utf8
                ),
            ]
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "tok_lost"
        )
        let harness = Self.makeHarness(client: client, container: container,
                                       tokenStore: tokenStore, defaults: defaults)

        let outcome = try await harness.coordinator.start()

        #expect(outcome == .deleted)
        #expect(AccountDeletionMockURLProtocol.requests()
            .contains("POST /api/account-deletion/receipts/lookup"))
        let lookup = try #require(AccountDeletionMockURLProtocol
            .body(for: "POST /api/account-deletion/receipts/lookup"))
        let lookupBody = try #require(JSONSerialization.jsonObject(with: lookup) as? [String: Any])
        // The RAW nonce goes up; the server hashes it. The hash went out
        // with the deletion request.
        #expect(lookupBody["receipt_token"] as? String == Self.receiptNonce)
        #expect(tokenStore.load() == nil, "a confirmed deletion must still sign the user out")
        #expect(harness.storedCheckpoint == nil)

        let fresh = ModelContext(container)
        for (name, count) in try rowCountsAllModels(context: fresh) {
            #expect(count == 0, "model \(name) must be empty after a confirmed deletion")
        }
    }

    @Test("an unauthorized response with no receipt on file is not a deletion")
    func unauthorizedWithoutReceiptKeepsEverything() async throws {
        let container = Self.makeContainer("deleteAccountUnauthorized")
        let defaults = Self.makeDefaults("deleteAccountUnauthorized")
        let tokenStore = InMemoryTokenStore("tok_stale")
        try Self.seedContainer(container)
        try Self.cacheIdentity(defaults, userID: "u_del", householdID: Self.householdID)

        // Same 401, but the receipt route says there is no such receipt —
        // so the account is alive and the token is merely stale.
        let session = AccountDeletionMockURLProtocol.makeSession(
            routes: [
                "DELETE /api/me": Data(
                    #"{"ok":false,"error":{"code":"unauthorized","message":"no session"}}"#.utf8
                )
            ],
            fallbackStatus: 404
        )
        AccountDeletionMockURLProtocol.fallbackBody = Data(
            #"{"ok":false,"error":{"code":"receipt_not_found","message":"none"}}"#.utf8
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "tok_stale"
        )
        let harness = Self.makeHarness(client: client, container: container,
                                       tokenStore: tokenStore, defaults: defaults)

        await #expect(throws: (any Error).self) { try await harness.coordinator.start() }

        #expect(tokenStore.load() == "tok_stale", "a 401 alone must never sign the user out")
        #expect(harness.storedCheckpoint?.phase == .deletingAccount)
        let ctx = ModelContext(container)
        #expect(!(try ctx.fetch(FetchDescriptor<LocalSeed>())).isEmpty)
    }

    @Test("account A's stale deletion never signs out or wipes account B")
    func staleForeignDeletionLeavesCurrentAccountAlone() async throws {
        // The launch sweep has to enumerate every checkpoint, because before
        // sign-in it cannot know which one matters. That makes it the one
        // place where "some account was deleted" could be mistaken for
        // "this device's account was deleted" — and acting on that mistake
        // erases a live user's garden and token on behalf of a dead
        // account's leftover file.
        let container = Self.makeContainer("deleteAccountForeign")
        let defaults = Self.makeDefaults("deleteAccountForeign")
        let tokenStore = InMemoryTokenStore("tok_b_live")
        try Self.seedContainer(container)
        try Self.cacheIdentity(defaults, userID: "u_b", householdID: Self.householdID)

        let session = AccountDeletionMockURLProtocol.makeSession(
            routes: [
                "POST /api/account-deletion/receipts/lookup": Data(
                    #"{"ok":true,"data":{"deleted":true,"deleted_at":1700000000100}}"#.utf8
                )
            ]
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "tok_b_live"
        )
        let harness = Self.makeHarness(client: client, container: container,
                                       tokenStore: tokenStore, defaults: defaults,
                                       userID: "u_b")
        // Account A finished deleting on this device and left its record
        // behind; B has signed in since.
        try harness.store.save(AccountDeletionCheckpoint(
            userID: "u_a_deleted", role: .soloOwner, phase: .deletingAccount,
            deletionReceipt: "a-receipt-nonce", updatedAt: 1))

        let outcome = try await harness.coordinator.recoverCommittedDeletions()

        #expect(outcome == .idle)
        #expect(tokenStore.load() == "tok_b_live", "B's session must survive A's leftover record")
        #expect(harness.auth.loadCachedIdentity() != nil, "B's identity must survive")
        // A's dead record may go; B's garden may not.
        #expect(try harness.store.load(userID: "u_a_deleted") == nil)
        let ctx = ModelContext(container)
        #expect(!(try ctx.fetch(FetchDescriptor<LocalSeed>())).isEmpty,
                "B's garden must be untouched")
        #expect(!(try ctx.fetch(FetchDescriptor<LocalJournalEntry>())).isEmpty)
    }
}

// MARK: - Per-model row counter helper

/// Returns a dictionary of model-type-name → row count for every model in
/// SeedkeepSchema.all. Uses the same eraseAllRows-style generic walk the
/// production eraser uses, but for reads.
@MainActor
private func rowCountsAllModels(context: ModelContext) throws -> [String: Int] {
    var result: [String: Int] = [:]
    for modelType in SeedkeepSchema.all {
        let count = try countRows(of: modelType, in: context)
        result[String(describing: modelType)] = count
    }
    return result
}

@MainActor
private func countRows<T: PersistentModel>(of type: T.Type, in context: ModelContext) throws -> Int {
    try context.fetch(FetchDescriptor<T>()).count
}

// MARK: - Account-deletion URLProtocol

/// Suite-local URLProtocol for account-deletion tests. Supports
/// method-qualified keys ("DELETE /api/me") so the same path can be
/// stubbed with different methods independently.
final class AccountDeletionMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var capturedBody: Data?
    /// Bodies keyed by "METHOD /path", so a test can inspect each leg of a
    /// multi-request flow rather than only the last one.
    nonisolated(unsafe) static var capturedBodies: [String: Data] = [:]
    nonisolated(unsafe) static var requestLog: [String] = []
    nonisolated(unsafe) static var fallbackStatus: Int = 200
    nonisolated(unsafe) static var fallbackBody: Data = Data(
        #"{"ok":false,"error":{"code":"not_found","message":"unstubbed"}}"#.utf8
    )
    static let lock = NSLock()

    static func makeSession(
        routes: [String: Data] = [:],
        fallbackStatus: Int = 200
    ) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes
        Self.capturedBody = nil
        Self.capturedBodies = [:]
        Self.requestLog = []
        Self.fallbackStatus = fallbackStatus
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountDeletionMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func lastBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody
    }

    static func body(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies[key]
    }

    static func requests() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    private static func drainBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let key = "\(method) \(path)"
        Self.capturedBody = Self.drainBody(request)
        Self.capturedBodies[key] = Self.capturedBody
        Self.requestLog.append(key)
        let body = Self.routes[key] ?? Self.routes[path] ?? Self.fallbackBody
        let status = Self.routes[key] != nil || Self.routes[path] != nil ? 200 : Self.fallbackStatus
        Self.lock.unlock()

        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url,
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
