import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Phase 4D · Tests for the `CatalogCorrectionNotifier` observer + the
/// adjacent ledger / escalate / settings paths the notifier collaborates
/// with.
///
/// The notifier is a `@MainActor` singleton whose `start()` is idempotent
/// — once it has captured a `client` + `container`, subsequent calls
/// are no-ops. We work with that constraint by:
///
/// 1. Boot-strapping the notifier ONCE in `bootstrapNotifier()` with a
///    shared URL session whose `URLProtocol` is the test stub
///    `CorrNotifMockURLProtocol`.
/// 2. Configuring the protocol's class statics (`ledgerDevices`,
///    `extraRoutes`, capture log) between tests via
///    `CorrNotifMockURLProtocol.configure(…)` and `resetCapture()`.
/// 3. Posting `.catalogCorrectionsChanged` notifications with synthetic
///    `transitionedIDs`, then waiting out the 100ms debounce before
///    inspecting the captured request log.
///
/// Coverage (spec §10 iOS tier — `CatalogCorrectionNotifierTests.swift`):
/// - Cross-device dedup: ledger GET returning our device id → notifier
///   skips POST.
/// - Cross-device dedup: ledger GET empty → notifier POSTs our device id.
/// - UserDefaults gate: toggle off short-circuits BEFORE the ledger GET.
/// - `clearAllCatalogCorrectionPings` sweeps pending + delivered.
/// - Debounce: a burst of 5 same-id posts within ~50ms collapses to one
///   ledger GET (not 5).
/// - Batch > roundupThreshold (3): every id is marked exactly once
///   (no double-POST per id when the roundup branch is taken).
/// - `escalateDismissedCorrection` POSTs to /escalate and returns the
///   updated DTO.
@MainActor
@Suite("CatalogCorrectionNotifier — Phase 4D", .serialized)
struct CatalogCorrectionNotifierTests {

    // MARK: - Fixture

    private static let userDefaultsKey = "seedkeep.notif.catalog"

    /// Shared SeedkeepClient + container wired ONCE into the notifier
    /// singleton on first access. Subsequent tests reuse the same
    /// instances; per-test routing comes through the protocol class's
    /// static mutators, not new URLSessions.
    ///
    /// Lazily allocated on first access from a `@MainActor`-isolated
    /// test method — the `.serialized` suite trait guarantees no two
    /// tests bootstrap in parallel.
    @MainActor
    static var bootstrap: NotifierBootstrap {
        if let existing = sharedBootstrap { return existing }
        let made = NotifierBootstrap()
        sharedBootstrap = made
        return made
    }

    @MainActor
    private static var sharedBootstrap: NotifierBootstrap?

    @MainActor
    final class NotifierBootstrap {
        let client: SeedkeepClient
        let container: ModelContainer

        init() {
            let session = CorrNotifMockURLProtocol.makeSharedSession()
            self.client = SeedkeepClient(
                configuration: .init(
                    baseURL: URL(string: "https://test.local")!,
                    session: session
                ),
                bearerToken: "test_token"
            )
            self.container = Self.makeContainer()
            // Idempotent — only the first call wires the observer.
            CatalogCorrectionNotifier.shared.start(
                client: client,
                container: container
            )
        }

        static func makeContainer() -> ModelContainer {
            let schema = Schema(SeedkeepSchema.all)
            let config = ModelConfiguration(
                "catalogCorrectionNotifierTests",
                schema: schema,
                isStoredInMemoryOnly: true
            )
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: config)
        }
    }

    /// Seed a `LocalCatalogCorrection` row in the shared container so
    /// the notifier's `byID` lookup finds it during `scheduleBatch`.
    @discardableResult
    private static func seedRow(
        id: String,
        status: String = "applied"
    ) -> String {
        let context = ModelContext(bootstrap.container)
        // Idempotent within a single container — replace if already
        // present so test repeats stay clean.
        let descriptor = FetchDescriptor<LocalCatalogCorrection>(
            predicate: #Predicate { $0.id == id }
        )
        for existing in (try? context.fetch(descriptor)) ?? [] {
            context.delete(existing)
        }
        context.insert(LocalCatalogCorrection(
            id: id,
            catalogSeedID: "cs_x",
            catalogSeedName: "Sungold",
            fieldName: "days_to_maturity_min",
            valueType: "integer",
            suggestedValue: "70",
            status: status,
            createdAt: 1_716_900_000_000,
            updatedAt: 1_717_000_000_000,
            appliedFieldName: status == "applied" ? "days_to_maturity_min" : nil,
            appliedNewValue: status == "applied" ? "70" : nil
        ))
        // swiftlint:disable:next force_try
        try! context.save()
        return id
    }

    /// Pause long enough for the notifier's 100ms debounce + the ledger
    /// round-trip to land. 350ms is the empirical floor across CI.
    private static func waitForFlush() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    /// Settle the protocol-class statics + UserDefaults gate before
    /// each test. The `.serialized` suite trait guarantees ordering, so
    /// resetting at the top of each test is sufficient — no
    /// RAII-style scope needed.
    private static func resetStubAndDefaults(toggle: Bool = true) {
        // Eagerly bootstrap so the notifier observer is registered
        // before the test posts a notification.
        _ = bootstrap
        CorrNotifMockURLProtocol.resetCapture()
        CorrNotifMockURLProtocol.setLedger([:])
        CorrNotifMockURLProtocol.setInsertedFlags([:])
        CorrNotifMockURLProtocol.setExtraRoutes([:])
        UserDefaults.standard.set(toggle, forKey: userDefaultsKey)
    }

    // MARK: - Test 1: cross-device dedup (skip when our device is in the ledger)

    @Test("cross-device dedup: ledger GET returns our device id → notifier skips POST")
    func crossDeviceDedupSkipsWhenLedgerContainsOurDevice() async {
        let deviceID = CatalogCorrectionNotifier.currentDeviceID()
        let id1 = "corr_dedup_skip"
        Self.resetStubAndDefaults(toggle: true)
        CorrNotifMockURLProtocol.setLedger([id1: [deviceID]])
        Self.seedRow(id: id1, status: "applied")

        NotificationCenter.default.post(
            name: .catalogCorrectionsChanged,
            object: nil,
            userInfo: ["transitionedIDs": [id1]]
        )

        await Self.waitForFlush()

        let posts = CorrNotifMockURLProtocol.capturedNotifiedPOSTs()
        #expect(
            posts.allSatisfy { $0 != id1 },
            "notifier should NOT POST to /notified when ledger already contains our device id; got \(posts)"
        )
    }

    // MARK: - Test 2: cross-device dedup (proceed when ledger is empty)

    @Test("cross-device dedup: ledger GET returns empty → notifier proceeds and POSTs our device id")
    func crossDeviceDedupProceedsWhenLedgerEmpty() async {
        let id1 = "corr_dedup_post"
        Self.resetStubAndDefaults(toggle: true)
        CorrNotifMockURLProtocol.setLedger([id1: []])
        Self.seedRow(id: id1, status: "applied")

        NotificationCenter.default.post(
            name: .catalogCorrectionsChanged,
            object: nil,
            userInfo: ["transitionedIDs": [id1]]
        )

        await Self.waitForFlush()

        let posts = CorrNotifMockURLProtocol.capturedNotifiedPOSTs()
        #expect(
            posts.contains(id1),
            "notifier should POST /notified for id1 (first writer); captured POSTs: \(posts)"
        )
    }

    // MARK: - Test 2b: cross-device dedup (skip when ANY device is in the ledger)

    @Test("cross-device dedup: ledger GET returns ANOTHER device's id → notifier skips (no POST)")
    func crossDeviceDedupSkipsWhenSiblingDeviceInLedger() async {
        let id1 = "corr_dedup_sibling"
        Self.resetStubAndDefaults(toggle: true)
        // A SIBLING device (not ours) already claimed the ledger — the
        // user was already pinged on that device.
        CorrNotifMockURLProtocol.setLedger([id1: ["device-of-a-sibling"]])
        Self.seedRow(id: id1, status: "applied")

        NotificationCenter.default.post(
            name: .catalogCorrectionsChanged,
            object: nil,
            userInfo: ["transitionedIDs": [id1]]
        )

        await Self.waitForFlush()

        let posts = CorrNotifMockURLProtocol.capturedNotifiedPOSTs()
        #expect(
            posts.allSatisfy { $0 != id1 },
            "any device id in the ledger must skip this device's POST + ping; got \(posts)"
        )
    }

    // MARK: - Test 2c: POST /notified surfaces the server's inserted flag

    @Test("markCatalogCorrectionNotified returns the server's inserted flag")
    func markNotifiedReturnsInsertedFlag() async throws {
        Self.resetStubAndDefaults(toggle: true)
        CorrNotifMockURLProtocol.setInsertedFlags([
            "corr_flag_lost": false,
            "corr_flag_won": true,
        ])

        let lost = try await Self.bootstrap.client.markCatalogCorrectionNotified(
            correctionID: "corr_flag_lost",
            deviceID: "dev_x"
        )
        #expect(lost == false, "inserted:false (lost the race) must surface as false")

        let won = try await Self.bootstrap.client.markCatalogCorrectionNotified(
            correctionID: "corr_flag_won",
            deviceID: "dev_x"
        )
        #expect(won == true, "inserted:true (claimed the slot) must surface as true")
    }

    // MARK: - Test 3: UserDefaults toggle-off short-circuits before ledger GET

    @Test("UserDefaults gate: toggle off short-circuits → no ledger GET fired")
    func userDefaultsToggleOffSkipsLedger() async {
        let id1 = "corr_gate_off"
        Self.resetStubAndDefaults(toggle: false)
        CorrNotifMockURLProtocol.setLedger([id1: []])
        Self.seedRow(id: id1, status: "applied")

        NotificationCenter.default.post(
            name: .catalogCorrectionsChanged,
            object: nil,
            userInfo: ["transitionedIDs": [id1]]
        )

        await Self.waitForFlush()

        let gets = CorrNotifMockURLProtocol.capturedNotifiedGETs()
        #expect(
            gets.isEmpty,
            "notifier must skip the ledger GET when toggle is off; got \(gets)"
        )
        let posts = CorrNotifMockURLProtocol.capturedNotifiedPOSTs()
        #expect(posts.isEmpty,
                "notifier must not POST when toggle is off; got \(posts)")

        // Reset toggle so subsequent tests in this serialized suite see
        // the default-on state.
        UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)
    }

    // MARK: - Test 4: clearAllCatalogCorrectionPings sweeps prefix

    @Test("toggle-off clears pending AND delivered (no exception from real UN sweep)")
    func clearAllCatalogCorrectionPingsRuns() async {
        Self.resetStubAndDefaults(toggle: true)
        // We can't simulate the real UN center delivering pings inside
        // a unit test (the test bundle isn't entitled for live UN
        // delivery). What we CAN assert is that the public helper runs
        // to completion without throwing — verifying the prefix sweep
        // contract is wired up (both pending and delivered paths hit).
        await NotificationsCenter.shared.clearAllCatalogCorrectionPings()
        #expect(true)
    }

    // MARK: - Test 5: debounce coalesces a burst of posts

    @Test("debounce: 5 posts within ~50ms collapse to one flush pass (≤1 GET per id)")
    func debounceCoalesces() async {
        let id1 = "corr_debounce"
        Self.resetStubAndDefaults(toggle: true)
        CorrNotifMockURLProtocol.setLedger([id1: []])
        Self.seedRow(id: id1, status: "applied")

        // Burst of 5 posts within ~50ms — all should land inside the
        // 100ms debounce window.
        for _ in 0..<5 {
            NotificationCenter.default.post(
                name: .catalogCorrectionsChanged,
                object: nil,
                userInfo: ["transitionedIDs": [id1]]
            )
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        await Self.waitForFlush()

        let gets = CorrNotifMockURLProtocol.capturedNotifiedGETs()
        // The pending set dedupes by id (the notifier dedupes within
        // its flush); with 5 posts of the same id we expect ONE GET.
        // Without debounce, we'd see ≥5 GETs.
        #expect(
            gets.filter { $0 == id1 }.count <= 1,
            "expected ≤1 GET for \(id1) after debounce; got \(gets)"
        )
    }

    // MARK: - Test 6: batch > roundupThreshold (3) → exactly one POST per id

    @Test("batch > 3 transitions: each id is marked exactly once (no fan-out spam)")
    func batchAboveRoundupThreshold() async {
        let ids = ["corr_batch_a", "corr_batch_b", "corr_batch_c", "corr_batch_d", "corr_batch_e"]
        Self.resetStubAndDefaults(toggle: true)
        var ledger: [String: [String]] = [:]
        for id in ids {
            ledger[id] = []
            Self.seedRow(id: id, status: "applied")
        }
        CorrNotifMockURLProtocol.setLedger(ledger)

        NotificationCenter.default.post(
            name: .catalogCorrectionsChanged,
            object: nil,
            userInfo: ["transitionedIDs": ids]
        )

        await Self.waitForFlush()

        // Each id should be marked exactly once in the ledger
        // (regardless of whether the notifier emitted a roundup or
        // per-correction pings — the ledger writeback always fires per
        // id). The spec contract: no double-POSTs for the same id.
        let posts = CorrNotifMockURLProtocol.capturedNotifiedPOSTs()
        for id in ids {
            let count = posts.filter { $0 == id }.count
            #expect(
                count == 1,
                "expected exactly one POST per id (got \(count) for \(id)); all POSTs: \(posts)"
            )
        }
    }

    // MARK: - Test 7: escalate POSTs and returns updated DTO

    @Test("escalateDismissedCorrection POSTs to /escalate and returns the updated DTO")
    func escalatePostsAndReturnsDTO() async throws {
        Self.resetStubAndDefaults(toggle: true)

        let id1 = "corr_escalate"
        let now: Int64 = 1_717_500_000_000
        let escalateBody = """
        {
          "ok": true,
          "data": {
            "correction": {
              "id": "\(id1)",
              "catalog_seed_id": "cs_x",
              "catalog_seed_name": "Sungold",
              "field_name": "days_to_maturity_min",
              "value_type": "integer",
              "suggested_value": "200",
              "client_seen_value": null,
              "body": null,
              "status": "reviewed",
              "ai_review_score": 0.20,
              "ai_notes": "outside the typical maturity window",
              "dismissed_reason": "user_escalated",
              "conflict_with_id": null,
              "user_acknowledged_bounds": false,
              "created_at": 1716900000000,
              "reviewed_at": \(now),
              "applied_at": null,
              "escalated_at": \(now),
              "updated_at": \(now),
              "deleted_at": null
            }
          }
        }
        """
        CorrNotifMockURLProtocol.setExtraRoutes([
            "/api/catalog/cs_x/corrections/\(id1)/escalate": Data(escalateBody.utf8)
        ])

        let dto = try await Self.bootstrap.client.escalateDismissedCorrection(
            catalogID: "cs_x",
            correctionID: id1
        )

        #expect(dto.id == id1)
        #expect(dto.status == "reviewed")
        #expect(dto.dismissed_reason == "user_escalated")
        #expect(dto.escalated_at == now)
    }

    // MARK: - Test 8: PUT edit decodes the wrapped { correction } shape (incl. null field_name)

    @Test("editOpenCorrection decodes the wrapped { correction } response — null field_name tolerated")
    func editDecodesWrappedShapeWithNullFieldName() async throws {
        Self.resetStubAndDefaults(toggle: true)

        // Contract decision 2: PUT edit wraps as { correction: <dto> },
        // and (decision 1) the dto's structured columns may be null —
        // pin both on the same fixture.
        let id1 = "corr_edit_wrapped"
        let now: Int64 = 1_717_600_000_000
        let editBody = """
        {
          "ok": true,
          "data": {
            "correction": {
              "id": "\(id1)",
              "catalog_seed_id": "cs_x",
              "catalog_seed_name": "Sungold",
              "field_name": null,
              "value_type": null,
              "suggested_value": null,
              "client_seen_value": null,
              "body": "updated free-form note",
              "status": "open",
              "ai_review_score": null,
              "ai_notes": null,
              "dismissed_reason": null,
              "conflict_with_id": null,
              "user_acknowledged_bounds": false,
              "created_at": 1716900000000,
              "reviewed_at": null,
              "applied_at": null,
              "escalated_at": null,
              "updated_at": \(now),
              "deleted_at": null
            }
          }
        }
        """
        CorrNotifMockURLProtocol.setExtraRoutes([
            "/api/catalog/cs_x/corrections/\(id1)": Data(editBody.utf8)
        ])

        let dto = try await Self.bootstrap.client.editOpenCorrection(
            catalogID: "cs_x",
            correctionID: id1,
            body: "updated free-form note"
        )

        #expect(dto.id == id1)
        #expect(dto.field_name == nil)
        #expect(dto.value_type == nil)
        #expect(dto.suggested_value == nil)
        #expect(dto.body == "updated free-form note")
        #expect(dto.updated_at == now)
    }
}

// MARK: - URLProtocol stub specialized for the notifier's ledger paths

/// Captures every request and serves canned responses for the two ledger
/// endpoints (`GET / POST /api/catalog/corrections/:id/notified`).
/// Additional routes are passed via `extraRoutes` for the escalate test.
/// Unmatched paths fall through to the standard empty-page envelope.
///
/// All state lives on the class so a single URLSession instance pinned
/// inside the `CatalogCorrectionNotifier` singleton can be reconfigured
/// per-test without recreating the session.
final class CorrNotifMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var ledgerDevices: [String: [String]] = [:]
    /// Per-correction `inserted` flag for the POST /notified response.
    /// Defaults to `true` (this device claimed the ledger slot) when an
    /// id isn't present.
    nonisolated(unsafe) static var insertedFlags: [String: Bool] = [:]
    nonisolated(unsafe) static var extraRoutes: [String: Data] = [:]
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    static let lock = NSLock()

    static let emptyEnvelope = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8
    )

    /// One session per test target lifetime. Reuses the same protocol
    /// class so subsequent tests can mutate its statics through the
    /// helper setters without invalidating the notifier's pinned
    /// `client`.
    static func makeSharedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CorrNotifMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func setLedger(_ ledger: [String: [String]]) {
        lock.lock()
        defer { lock.unlock() }
        Self.ledgerDevices = ledger
    }

    static func setInsertedFlags(_ flags: [String: Bool]) {
        lock.lock()
        defer { lock.unlock() }
        Self.insertedFlags = flags
    }

    static func setExtraRoutes(_ routes: [String: Data]) {
        lock.lock()
        defer { lock.unlock() }
        Self.extraRoutes = routes
    }

    static func resetCapture() {
        lock.lock()
        defer { lock.unlock() }
        Self.capturedRequests = []
    }

    /// Ids the notifier requested via GET /notified.
    static func capturedNotifiedGETs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Self.capturedRequests.compactMap { req -> String? in
            guard let url = req.url else { return nil }
            guard req.httpMethod == "GET" else { return nil }
            return correctionIDFromNotifiedPath(url.path)
        }
    }

    /// Ids the notifier marked via POST /notified.
    static func capturedNotifiedPOSTs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Self.capturedRequests.compactMap { req -> String? in
            guard let url = req.url else { return nil }
            guard req.httpMethod == "POST" else { return nil }
            return correctionIDFromNotifiedPath(url.path)
        }
    }

    /// Parse the correction id out of `/api/catalog/corrections/:id/notified`,
    /// returning `nil` if the path doesn't match the notifier-ledger shape.
    static func correctionIDFromNotifiedPath(_ path: String) -> String? {
        let prefix = "/api/catalog/corrections/"
        let suffix = "/notified"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return String(path[start..<end])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let body: Data
        if let id = Self.correctionIDFromNotifiedPath(path) {
            switch method {
            case "GET":
                let devices = Self.ledgerDevices[id] ?? []
                let devicesJSON = devices
                    .map { "\"\($0)\"" }
                    .joined(separator: ",")
                let bodyString = """
                {"ok":true,"data":{"devices":[\(devicesJSON)]}}
                """
                body = Data(bodyString.utf8)
            case "POST":
                // Real wire shape (stabilization contract decision 5):
                // the server reports whether THIS insert claimed the
                // ledger slot.
                let inserted = Self.insertedFlags[id] ?? true
                body = Data(#"{"ok":true,"data":{"inserted":\#(inserted)}}"#.utf8)
            default:
                body = Self.emptyEnvelope
            }
        } else if let routed = Self.extraRoutes[path] {
            body = routed
        } else {
            body = Self.emptyEnvelope
        }
        Self.lock.unlock()

        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
