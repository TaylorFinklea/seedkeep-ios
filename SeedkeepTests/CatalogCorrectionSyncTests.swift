import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Phase 4D · Sync engine tests for `pullCatalogCorrections` +
/// `upsertCatalogCorrections`. Modeled on `PetDeparturesSyncTests` —
/// uses the same `RouterMockURLProtocol` to stub `/api/catalog/corrections/mine`
/// with route-specific JSON while leaving every other delta endpoint
/// returning the standard empty page envelope.
///
/// Coverage (spec §10 iOS tier — `CatalogCorrectionSyncTests.swift`):
///
/// 1. `open → applied` transition posts `.catalogCorrectionsChanged`
///    exactly once with the row id in `userInfo["transitionedIDs"]`.
/// 2. Idempotent re-sync (same DTO twice) posts no second notification.
/// 3. Tombstone (`deleted_at` non-NULL) hard-deletes the local row.
/// 4. `applied_patch` field is captured onto the local row
///    (`appliedFieldName` / `appliedNewValue`) so SeedDetail can patch
///    its cached `CatalogSeedDTO` without an extra round-trip.
/// 5. Cursor advances across pages — repeat `pullCatalogCorrections`
///    walks `has_more: true` pages until the server returns `has_more:
///    false`.
@MainActor
@Suite("SyncEngine — pullCatalogCorrections (Phase 4D)", .serialized)
struct CatalogCorrectionSyncTests {

    // MARK: - Fixture

    private static let householdID = "hh_catalog_sync"
    private static let correctionsPath = "/api/catalog/corrections/mine"

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([
            LocalPlantingEvent.self,
            LocalPetMoodSnapshot.self,
            LocalPetDeparture.self,
            LocalJournalEntry.self,
            LocalJournalChecklistItem.self,
            LocalJournalEntryPhoto.self,
            LocalSeed.self,
            LocalBed.self,
            LocalLocation.self,
            LocalTag.self,
            LocalSeedPhoto.self,
            LocalPendingWrite.self,
            LocalSyncCursor.self,
            LocalRecommendation.self,
            LocalAssistantThread.self,
            LocalAssistantMessage.self,
            LocalAssistantToolCall.self,
            LocalAssistantKeyStatus.self,
            LocalCatalogCorrection.self,
        ])
        let config = ModelConfiguration(
            "catalogCorrectionSyncTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: config)
    }

    /// Empty-page envelope reused for every endpoint the test doesn't
    /// explicitly exercise.
    private static let emptyEnvelope = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8
    )

    private static func makeRoutedClient(
        routes: [String: Data] = [:],
        sequences: [String: [Data]] = [:]
    ) -> SeedkeepClient {
        let session = CatalogRouterMockURLProtocol.makeSession(
            routes: routes,
            sequences: sequences,
            fallbackBody: emptyEnvelope,
            fallbackStatus: 200
        )
        return SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
    }

    /// Observe `.catalogCorrectionsChanged` posts and capture the
    /// `transitionedIDs` payload, filtered to a set of expected ids so
    /// cross-suite contamination (the global `NotificationCenter.default`
    /// is shared with `CatalogCorrectionNotifierTests` and any other
    /// suite that posts on this channel in parallel) doesn't leak into
    /// this test's assertions.
    private static func captureNextNotification(
        expectedIDs: Set<String>,
        timeoutMs: UInt64 = 500
    ) -> NotificationCapture {
        NotificationCapture(expectedIDs: expectedIDs, timeoutMs: timeoutMs)
    }

    final class NotificationCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _posted: [[String]] = []
        private var token: NSObjectProtocol?
        private let expectedIDs: Set<String>

        var posted: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return _posted
        }

        init(expectedIDs: Set<String>, timeoutMs: UInt64) {
            self.expectedIDs = expectedIDs
            token = NotificationCenter.default.addObserver(
                forName: .catalogCorrectionsChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                let ids = (note.userInfo?["transitionedIDs"] as? [String]) ?? []
                // Filter to ids this test cares about. Posts from other
                // suites (e.g. CatalogCorrectionNotifierTests) carry
                // their own ids and would otherwise contaminate the
                // observed counts on the global default center.
                let filtered = ids.filter { self.expectedIDs.contains($0) }
                guard !filtered.isEmpty else { return }
                self.lock.lock()
                self._posted.append(filtered)
                self.lock.unlock()
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }

        /// Yield enough runloop ticks for the MainActor `Task` inside
        /// `upsertCatalogCorrections` to fire its post.
        func drain() async {
            // The post hops to MainActor via `Task { @MainActor in … }`.
            // A short sleep gives the scheduled Task time to land before
            // we read `posted`.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func makeCorrectionJSON(
        id: String,
        catalogSeedID: String? = "cs_x",
        catalogSeedName: String? = "Sungold",
        fieldName: String = "days_to_maturity_min",
        valueType: String = "integer",
        suggestedValue: String = "70",
        status: String = "open",
        appliedAt: Int64? = nil,
        reviewedAt: Int64? = nil,
        updatedAt: Int64 = 1_717_000_000_000,
        createdAt: Int64 = 1_716_900_000_000,
        deletedAt: Int64? = nil,
        appliedPatchField: String? = nil,
        appliedPatchValue: String? = nil
    ) -> String {
        let appliedPatchBlock: String
        if let pf = appliedPatchField, let pv = appliedPatchValue {
            appliedPatchBlock =
                ",\"applied_patch\":{\"field_name\":\"\(pf)\",\"new_value\":\"\(pv)\"}"
        } else {
            appliedPatchBlock = ""
        }
        let catalogSeedIDField = catalogSeedID.map { "\"\($0)\"" } ?? "null"
        let catalogSeedNameField = catalogSeedName.map { "\"\($0)\"" } ?? "null"
        let appliedAtField = appliedAt.map(String.init) ?? "null"
        let reviewedAtField = reviewedAt.map(String.init) ?? "null"
        let deletedAtField = deletedAt.map(String.init) ?? "null"
        return """
        {
          "id":"\(id)",
          "catalog_seed_id":\(catalogSeedIDField),
          "catalog_seed_name":\(catalogSeedNameField),
          "field_name":"\(fieldName)",
          "value_type":"\(valueType)",
          "suggested_value":"\(suggestedValue)",
          "client_seen_value":null,
          "body":null,
          "status":"\(status)",
          "ai_review_score":null,
          "ai_notes":null,
          "dismissed_reason":null,
          "conflict_with_id":null,
          "user_acknowledged_bounds":false,
          "created_at":\(createdAt),
          "reviewed_at":\(reviewedAtField),
          "applied_at":\(appliedAtField),
          "escalated_at":null,
          "updated_at":\(updatedAt),
          "deleted_at":\(deletedAtField)\(appliedPatchBlock)
        }
        """
    }

    private static func envelope(items: [String], cursor: Int64, hasMore: Bool) -> Data {
        let itemsJSON = items.joined(separator: ",")
        let body = """
        {"ok":true,"data":{"items":[\(itemsJSON)],"cursor":\(cursor),"has_more":\(hasMore)}}
        """
        return Data(body.utf8)
    }

    // MARK: - Test 1: open → applied transition posts notification once

    @Test("open → applied transition posts .catalogCorrectionsChanged exactly once with id in userInfo")
    func openToAppliedPostsExactlyOnce() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)

        // Pre-seed an open row.
        let id = "corr_apply"
        context.insert(LocalCatalogCorrection(
            id: id,
            catalogSeedID: "cs_x",
            catalogSeedName: "Sungold",
            fieldName: "days_to_maturity_min",
            valueType: "integer",
            suggestedValue: "70",
            status: "open",
            createdAt: 1_716_900_000_000,
            updatedAt: 1_716_900_000_000
        ))
        try? context.save()

        // Server responds with the same row, now in `applied` state +
        // an `applied_patch` payload.
        let now: Int64 = 1_717_000_000_000
        let body = Self.envelope(
            items: [Self.makeCorrectionJSON(
                id: id,
                status: "applied",
                appliedAt: now,
                reviewedAt: now,
                updatedAt: now,
                appliedPatchField: "days_to_maturity_min",
                appliedPatchValue: "70"
            )],
            cursor: now,
            hasMore: false
        )
        let client = Self.makeRoutedClient(routes: [Self.correctionsPath: body])
        let engine = SyncEngine(client: client, container: container)

        let capture = Self.captureNextNotification(expectedIDs: [id])

        await engine.syncAll(householdID: Self.householdID)
        await capture.drain()

        // Exactly one notification fired.
        #expect(capture.posted.count == 1,
                "expected 1 .catalogCorrectionsChanged, got \(capture.posted.count)")
        #expect(capture.posted.first?.contains(id) == true,
                "expected transitioned id \(id) in userInfo, got \(capture.posted)")

        // Local row reflects the new status.
        let descriptor = FetchDescriptor<LocalCatalogCorrection>(
            predicate: #Predicate { $0.id == id }
        )
        let row = try? context.fetch(descriptor).first
        #expect(row?.status == "applied")
        #expect(row?.appliedAt == now)
    }

    // MARK: - Test 2: idempotent re-sync posts no second notification

    @Test("idempotent re-sync of the same applied DTO posts no second notification")
    func idempotentResyncSilent() async {
        let container = Self.makeContainer()

        // Server delivers the row in applied state on every sync.
        let id = "corr_idem"
        let now: Int64 = 1_717_000_000_000
        let appliedBody = Self.envelope(
            items: [Self.makeCorrectionJSON(
                id: id,
                status: "applied",
                appliedAt: now,
                reviewedAt: now,
                updatedAt: now
            )],
            cursor: now,
            hasMore: false
        )
        let client = Self.makeRoutedClient(routes: [Self.correctionsPath: appliedBody])
        let engine = SyncEngine(client: client, container: container)

        // First sync: row lands fresh → notification fires (first-sight
        // terminal-state rule in `upsertCatalogCorrections`).
        let firstCapture = Self.captureNextNotification(expectedIDs: [id])
        await engine.syncAll(householdID: Self.householdID)
        await firstCapture.drain()
        #expect(firstCapture.posted.count == 1, "first sync should fire one notification")

        // Second sync: server returns the same DTO; status is already
        // `applied` locally → no transition → no notification.
        let secondCapture = Self.captureNextNotification(expectedIDs: [id])
        await engine.syncAll(householdID: Self.householdID)
        await secondCapture.drain()
        #expect(secondCapture.posted.isEmpty,
                "second sync should not re-fire — already terminal, got \(secondCapture.posted)")
    }

    // MARK: - Test 3: tombstone hard-deletes the local row

    @Test("tombstone (deleted_at non-NULL) hard-deletes the local row")
    func tombstoneHardDeletes() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)

        let id = "corr_tomb"
        let createdAt: Int64 = 1_716_900_000_000
        context.insert(LocalCatalogCorrection(
            id: id,
            catalogSeedID: "cs_x",
            catalogSeedName: "Sungold",
            fieldName: "days_to_maturity_min",
            valueType: "integer",
            suggestedValue: "70",
            status: "open",
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        try? context.save()

        let tombstoneAt: Int64 = createdAt + 1
        let body = Self.envelope(
            items: [Self.makeCorrectionJSON(
                id: id,
                status: "dismissed",
                updatedAt: tombstoneAt,
                createdAt: createdAt,
                deletedAt: tombstoneAt
            )],
            cursor: tombstoneAt,
            hasMore: false
        )
        let client = Self.makeRoutedClient(routes: [Self.correctionsPath: body])
        let engine = SyncEngine(client: client, container: container)

        await engine.syncAll(householdID: Self.householdID)

        let descriptor = FetchDescriptor<LocalCatalogCorrection>(
            predicate: #Predicate { $0.id == id }
        )
        let post = (try? context.fetch(descriptor)) ?? []
        #expect(post.isEmpty, "tombstone should hard-delete the local row")
    }

    // MARK: - Test 4: applied_patch captured onto local row

    @Test("applied_patch field patches local row's appliedFieldName/Value (cached CatalogSeedDTO hop)")
    func appliedPatchCaptured() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)

        let id = "corr_patch"
        let now: Int64 = 1_717_000_000_000
        // Body simulates the transition: open → applied with applied_patch.
        let body = Self.envelope(
            items: [Self.makeCorrectionJSON(
                id: id,
                fieldName: "days_to_maturity_min",
                suggestedValue: "70",
                status: "applied",
                appliedAt: now,
                reviewedAt: now,
                updatedAt: now,
                appliedPatchField: "days_to_maturity_min",
                appliedPatchValue: "70"
            )],
            cursor: now,
            hasMore: false
        )
        let client = Self.makeRoutedClient(routes: [Self.correctionsPath: body])
        let engine = SyncEngine(client: client, container: container)

        await engine.syncAll(householdID: Self.householdID)

        let descriptor = FetchDescriptor<LocalCatalogCorrection>(
            predicate: #Predicate { $0.id == id }
        )
        let row = try? context.fetch(descriptor).first
        #expect(row?.appliedFieldName == "days_to_maturity_min")
        #expect(row?.appliedNewValue == "70")
        #expect(row?.status == "applied")
    }

    // MARK: - Test 5: cursor advances across pages

    @Test("cursor advances across pages — has_more=true → next page consumed; has_more=false → stop")
    func cursorAdvancesAcrossPages() async {
        let container = Self.makeContainer()

        let firstID = "corr_p1"
        let secondID = "corr_p2"
        let firstUpdatedAt: Int64 = 1_717_000_000_000
        let secondUpdatedAt: Int64 = 1_717_100_000_000

        // Page 1: one item, has_more=true, cursor=firstUpdatedAt.
        let firstPage = Self.envelope(
            items: [Self.makeCorrectionJSON(
                id: firstID,
                status: "applied",
                appliedAt: firstUpdatedAt,
                reviewedAt: firstUpdatedAt,
                updatedAt: firstUpdatedAt
            )],
            cursor: firstUpdatedAt,
            hasMore: true
        )
        // Page 2: another item, has_more=false, cursor=secondUpdatedAt.
        let secondPage = Self.envelope(
            items: [Self.makeCorrectionJSON(
                id: secondID,
                status: "dismissed",
                reviewedAt: secondUpdatedAt,
                updatedAt: secondUpdatedAt
            )],
            cursor: secondUpdatedAt,
            hasMore: false
        )
        // Sequenced — first call to /api/catalog/corrections/mine gets
        // page 1, second gets page 2.
        let client = Self.makeRoutedClient(
            sequences: [Self.correctionsPath: [firstPage, secondPage]]
        )
        let engine = SyncEngine(client: client, container: container)

        await engine.syncAll(householdID: Self.householdID)

        // Both rows landed.
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalCatalogCorrection>()
        let rows = (try? context.fetch(descriptor)) ?? []
        let ids = Set(rows.map(\.id))
        #expect(ids.contains(firstID), "page 1 row missing — \(ids)")
        #expect(ids.contains(secondID), "page 2 row missing — \(ids)")

        // Cursor row reflects the last page's cursor.
        let cursorKey = LocalSyncCursor.key(
            householdID: Self.householdID,
            kind: "catalog_corrections"
        )
        let cursorDescriptor = FetchDescriptor<LocalSyncCursor>(
            predicate: #Predicate { $0.id == cursorKey }
        )
        let cursorRow = try? context.fetch(cursorDescriptor).first
        #expect(cursorRow?.cursor == secondUpdatedAt,
                "cursor should advance to the final page's cursor; got \(String(describing: cursorRow?.cursor))")
    }
}

// MARK: - Router URL protocol with sequence support
//
// Extends the test-local `RouterMockURLProtocol` pattern from
// `PetDeparturesSyncTests` with a second mode: `sequences[path]` returns
// the next Data in the array on each request and falls back to the last
// element when the array is exhausted. Lets us model multi-page delta
// feeds without rewriting the protocol class for every test file.

final class CatalogRouterMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var sequences: [String: [Data]] = [:]
    nonisolated(unsafe) static var sequenceCursors: [String: Int] = [:]
    nonisolated(unsafe) static var fallbackBody: Data = Data()
    nonisolated(unsafe) static var fallbackStatus: Int = 200
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    static let lock = NSLock()

    static func makeSession(
        routes: [String: Data],
        sequences: [String: [Data]] = [:],
        fallbackBody: Data,
        fallbackStatus: Int
    ) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes
        Self.sequences = sequences
        Self.sequenceCursors = [:]
        Self.fallbackBody = fallbackBody
        Self.fallbackStatus = fallbackStatus
        Self.capturedRequests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogRouterMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func resetCapture() {
        lock.lock()
        defer { lock.unlock() }
        Self.capturedRequests = []
    }

    static func capturedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Self.capturedRequests.compactMap { $0.url?.path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let path = request.url?.path ?? ""
        let body: Data
        if let seq = Self.sequences[path], !seq.isEmpty {
            let cursor = Self.sequenceCursors[path] ?? 0
            let idx = min(cursor, seq.count - 1)
            body = seq[idx]
            Self.sequenceCursors[path] = cursor + 1
        } else if let routed = Self.routes[path] {
            body = routed
        } else {
            body = Self.fallbackBody
        }
        let status = Self.fallbackStatus
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
