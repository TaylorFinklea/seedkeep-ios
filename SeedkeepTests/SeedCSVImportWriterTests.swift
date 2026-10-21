import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

/// CSV import writes over the in-memory store and `SyncEngine`: only changed fields are sent, `type` is
/// written after a create, dependencies are created once, stale state refuses or forces a new preview,
/// partial failures are reported and retried without duplicates, and an export round-trips as a no-op.
@MainActor
@Suite("Seeds CSV import — writes over SyncEngine", .serialized)
struct SeedCSVImportWriterTests {
    static let household = "hh_csv_import"

    enum InjectedFailure: Error, LocalizedError {
        case boom
        var errorDescription: String? { "injected failure" }
    }

    /// Forwards to `SyncEngine`, failing the chosen call.
    final class FailingStore: SeedCSVImportStore {
        let engine: SyncEngine
        var failCreateSeedAt: Int?
        var failUpdateSeedAt: Int?
        var failTypeAt: Int?
        private(set) var createSeedCalls = 0
        private(set) var updateSeedCalls = 0
        private(set) var typeCalls = 0
        /// When the first write of any kind happened.
        private(set) var firstWriteAt: ContinuousClock.Instant?

        private func noteWrite() {
            if firstWriteAt == nil { firstWriteAt = ContinuousClock().now }
        }

        init(engine: SyncEngine) {
            self.engine = engine
        }

        func enqueueCreateLocation(name: String, sortOrder: Int, householdID: String) throws -> LocalLocation {
            noteWrite()
            return try engine.enqueueCreateLocation(name: name, sortOrder: sortOrder, householdID: householdID)
        }

        func enqueueCreateTag(name: String, color: String?, householdID: String) throws -> LocalTag {
            noteWrite()
            return try engine.enqueueCreateTag(name: name, color: color, householdID: householdID)
        }

        func enqueueCreateSeed(_ input: SeedkeepClient.CreateSeedInput, householdID: String) throws -> LocalSeed {
            noteWrite()
            createSeedCalls += 1
            if createSeedCalls == failCreateSeedAt { throw InjectedFailure.boom }
            return try engine.enqueueCreateSeed(input, householdID: householdID)
        }

        func enqueueUpdateSeed(id: String, _ patch: SeedkeepClient.UpdateSeedInput) throws {
            noteWrite()
            updateSeedCalls += 1
            if updateSeedCalls == failUpdateSeedAt { throw InjectedFailure.boom }
            try engine.enqueueUpdateSeed(id: id, patch)
        }

        func setLocalCustomType(seedID: String, type: String?) throws {
            typeCalls += 1
            if typeCalls == failTypeAt { throw InjectedFailure.boom }
            try engine.setLocalCustomType(seedID: seedID, type: type)
        }
    }

    @MainActor
    final class Harness {
        let container: ModelContainer
        let engine: SyncEngine
        let store: FailingStore
        var household: String? = SeedCSVImportWriterTests.household
        var nudges = 0

        init() {
            container = makeTestContainer(name: "seedCSVImportWriterTests")
            let client = SeedkeepClient(configuration: .init(baseURL: URL(string: "https://test.invalid")!))
            engine = SyncEngine(client: client, container: container)
            store = FailingStore(engine: engine)
        }

        func writer(batchSize: Int = .max, pause: @escaping @MainActor () async -> Void = {}) -> SeedCSVImportWriter {
            SeedCSVImportWriter(
                store: store,
                container: container,
                householdID: SeedCSVImportWriterTests.household,
                currentHouseholdID: { [unowned self] in self.household },
                batchSize: batchSize,
                pause: pause,
                nudgeSync: { [unowned self] in self.nudges += 1 }
            )
        }

        func insert(_ models: [any PersistentModel]) throws {
            let context = ModelContext(container)
            for model in models { context.insert(model) }
            try context.save()
        }

        func seeds() throws -> [LocalSeed] {
            let household = SeedCSVImportWriterTests.household
            return try ModelContext(container).fetch(FetchDescriptor<LocalSeed>(
                predicate: #Predicate { $0.householdID == household && $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            ))
        }

        func seed(_ id: String) throws -> LocalSeed? {
            try ModelContext(container).fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id })).first
        }

        func locations() throws -> [LocalLocation] {
            try ModelContext(container).fetch(FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.deletedAt == nil }))
        }

        func tags() throws -> [LocalTag] {
            try ModelContext(container).fetch(FetchDescriptor<LocalTag>(predicate: #Predicate { $0.deletedAt == nil }))
        }

        func pending() throws -> [(type: String, op: String, id: String, payload: [String: Any])] {
            let rows = try ModelContext(container).fetch(FetchDescriptor<LocalPendingWrite>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            return rows.map { row in
                let object = (try? JSONSerialization.jsonObject(with: Data(row.payloadJSON.utf8))) as? [String: Any]
                return (row.entityType, row.operation, row.entityID, object ?? [:])
            }
        }

        func file(_ csv: String) throws -> SeedCSVImport.ParsedFile {
            try SeedCSVImport.parse(csv)
        }

        /// The preview's plan, from the store now.
        func preview(_ file: SeedCSVImport.ParsedFile, writer: SeedCSVImportWriter) async throws -> SeedCSVImport.Plan {
            try await writer.freshPlan(for: file)
        }

        /// The export of the household's seeds, as the Seeds table builds it.
        func export() throws -> Data {
            let household = SeedCSVImportWriterTests.household
            let context = ModelContext(container)
            let seeds = try context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.householdID == household }))
            let locations = try context.fetch(FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.householdID == household }))
            let tags = try context.fetch(FetchDescriptor<LocalTag>(predicate: #Predicate { $0.householdID == household }))
            let rows = SeedTableRow.rows(seeds: seeds, locations: locations, tags: tags, recommendations: [:])
            return SeedCSV.data(for: rows.sorted { $0.id < $1.id })
        }
    }

    static func seed(
        _ id: String,
        name: String? = "Basil",
        variety: String? = nil,
        company: String? = nil,
        year: Int? = nil,
        packets: Int = 1,
        state: SeedState = .active,
        locationID: String? = nil,
        tagIDs: [String] = [],
        notes: String? = nil,
        type: String? = nil,
        catalogID: String? = nil,
        source: SeedSource = .gift
    ) -> LocalSeed {
        LocalSeed(
            id: id, householdID: household, catalogID: catalogID, state: state, packetCount: packets,
            locationID: locationID, yearPacked: year, source: source, customName: name, customVariety: variety,
            customCompany: company, customType: type, notes: notes, tagIDs: tagIDs, createdAt: 1, updatedAt: 1
        )
    }

    static func location(_ id: String, _ name: String, deleted: Bool = false) -> LocalLocation {
        let location = LocalLocation(id: id, householdID: household, name: name, sortOrder: 0, createdAt: 1, updatedAt: 1)
        if deleted { location.deletedAt = 2 }
        return location
    }

    static func tag(_ id: String, _ name: String, deleted: Bool = false) -> LocalTag {
        let tag = LocalTag(id: id, householdID: household, name: name, color: nil, createdAt: 1, updatedAt: 1)
        if deleted { tag.deletedAt = 2 }
        return tag
    }

    static let identity = "name,variety,company,year"

    // MARK: - Only changed fields

    @Test("an update sends only the changed fields, and a create sends the file's values with defaults")
    func onlyChangedFields() async throws {
        let harness = Harness()
        try harness.insert([Self.seed("s1", packets: 1, notes: "Old", catalogID: "cat_1")])
        let writer = harness.writer()
        let file = try harness.file("\(Self.identity),packets,notes\nBasil,,,,5,Old\nDill,Bouquet,,2024,,Feathery\n")
        let plan = try await harness.preview(file, writer: writer)

        let result = await writer.run(plan: plan, file: file)

        #expect(result.ending == .completed)
        #expect(result.report.seedsCreated == 1)
        #expect(result.report.seedsUpdated == 1)
        let pending = try harness.pending()
        let update = try #require(pending.first { $0.op == "update" })
        #expect(update.id == "s1")
        #expect(update.payload as NSDictionary == ["packet_count": 5] as NSDictionary)
        let create = try #require(pending.first { $0.op == "create" })
        #expect(create.payload["custom_name"] as? String == "Dill")
        #expect(create.payload["custom_variety"] as? String == "Bouquet")
        #expect(create.payload["year_packed"] as? Int == 2024)
        #expect(create.payload["packet_count"] as? Int == 1)
        #expect(create.payload["state"] as? String == "active")
        #expect(create.payload["source"] as? String == "store")
        #expect(create.payload["notes"] as? String == "Feathery")
        #expect(create.payload["catalog_id"] == nil)

        let updated = try #require(try harness.seed("s1"))
        #expect(updated.packetCount == 5)
        #expect(updated.catalogID == "cat_1", "values export doesn't carry are untouched")
        #expect(updated.source == .gift)
        #expect(harness.nudges == 1)
    }

    @Test("blanks clear with explicit nulls, and the patch never carries untouched fields")
    func clearsAreExplicitNulls() async throws {
        let harness = Harness()
        try harness.insert([Self.location("loc_shed", "Shed"), Self.seed("s1", locationID: "loc_shed", notes: "Old")])
        let writer = harness.writer()
        let file = try harness.file("\(Self.identity),stored_in,notes\nBasil,,,,,\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        #expect(result.ending == .completed)
        let update = try #require(try harness.pending().first { $0.op == "update" })
        #expect(Set(update.payload.keys) == ["location_id", "notes"])
        #expect(update.payload["location_id"] is NSNull)
        #expect(update.payload["notes"] is NSNull)
    }

    // MARK: - Type

    @Test("type is written with setLocalCustomType after a create, and a type-only change enqueues no patch")
    func typeAfterCreate() async throws {
        let harness = Harness()
        try harness.insert([Self.seed("s1", name: "Kale", type: "Green")])
        let writer = harness.writer()
        let file = try harness.file("\(Self.identity),type\nBasil,,,,Herb\nKale,,,,Brassica\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        #expect(result.ending == .completed)
        let basil = try #require(try harness.seeds().first { $0.customName == "Basil" })
        #expect(basil.customType == "Herb")
        #expect(try harness.seed("s1")?.customType == "Brassica")
        let pending = try harness.pending()
        #expect(pending.filter { $0.op == "update" }.isEmpty, "an empty patch is never enqueued")
        #expect(pending.filter { $0.op == "create" }.count == 1)
        #expect(result.report.seedsUpdated == 1)
    }

    // MARK: - Dependencies

    @Test("a new location or tag is created once, with the first spelling, and every row uses it")
    func dependenciesCreatedOnce() async throws {
        let harness = Harness()
        try harness.insert([Self.location("loc_old", "Fridge")])
        let writer = harness.writer(batchSize: 1)
        let file = try harness.file("name,stored_in,tags\nBasil,attic,Spicy; green\nDill,ATTIC,SPICY; Tall\nKale,Fridge,Green\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        #expect(result.ending == .completed, "this run's own new locations and tags don't stop it")
        #expect(result.report.locationsCreated == 1)
        #expect(result.report.tagsCreated == 3)
        let attic = try #require(try harness.locations().first { $0.name == "attic" })
        #expect(try harness.locations().count == 2)
        #expect(attic.sortOrder == 1, "new locations go after the live ones")
        let tags = try harness.tags()
        #expect(Set(tags.map(\.name)) == ["Spicy", "green", "Tall"])
        let spicy = try #require(tags.first { $0.name == "Spicy" })
        let seeds = try harness.seeds()
        #expect(seeds.filter { $0.locationID == attic.id }.count == 2)
        #expect(seeds.filter { $0.tagIDs.contains(spicy.id) }.count == 2)
        #expect(seeds.first { $0.customName == "Kale" }?.locationID == "loc_old")
    }

    // MARK: - Stale state

    @Test("a household change before writing refuses, and nothing is written")
    func householdChangeRefuses() async throws {
        let harness = Harness()
        let writer = harness.writer()
        let file = try harness.file("name\nBasil\n")
        let plan = try await harness.preview(file, writer: writer)
        harness.household = "hh_other"

        let result = await writer.run(plan: plan, file: file)

        #expect(result.ending == .householdChanged)
        #expect(try harness.pending().isEmpty)
        #expect(harness.nudges == 0)
    }

    @Test("a household change between batches stops the run")
    func householdChangeMidRun() async throws {
        let harness = Harness()
        var pauses = 0
        let writer = harness.writer(batchSize: 1) {
            pauses += 1
            if pauses == 1 { harness.household = "hh_other" }
        }
        let file = try harness.file("name\nBasil\nDill\nKale\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        #expect(result.ending == .householdChanged)
        #expect(result.report.seedsCreated == 1)
        #expect(try harness.seeds().count == 1)
        #expect(harness.nudges == 1, "sync is nudged after a partial run")
    }

    @Test("a target changed after the preview forces a new preview before anything is written")
    func changedTargetBeforeWriting() async throws {
        let harness = Harness()
        try harness.insert([Self.seed("s1", notes: "Old")])
        let writer = harness.writer()
        let file = try harness.file("\(Self.identity),notes\nBasil,,,,New\nDill,,,,\n")
        let plan = try await harness.preview(file, writer: writer)
        try harness.engine.enqueueUpdateSeed(id: "s1", .init(packet_count: 7))
        let before = try harness.pending().count

        let result = await writer.run(plan: plan, file: file)

        guard case .changed(let fresh) = result.ending else {
            Issue.record("expected a new preview, got \(result.ending)")
            return
        }
        #expect(fresh != plan)
        #expect(try harness.pending().count == before, "nothing was written")
        #expect(try harness.seeds().count == 1)

        // The new preview imports.
        let retry = await writer.run(plan: fresh, file: file)
        #expect(retry.ending == .completed)
        #expect(try harness.seed("s1")?.notes == "New")
        #expect(try harness.seed("s1")?.packetCount == 7)
    }

    @Test("a remaining target changed between batches stops the run and asks for a new preview")
    func changedTargetMidRun() async throws {
        let harness = Harness()
        try harness.insert([Self.seed("s1", name: "Basil"), Self.seed("s2", name: "Dill")])
        var pauses = 0
        let writer = harness.writer(batchSize: 1) {
            pauses += 1
            if pauses == 1 { try? harness.engine.enqueueUpdateSeed(id: "s2", .init(notes: .some("Remote"))) }
        }
        let file = try harness.file("\(Self.identity),packets\nBasil,,,,4\nDill,,,,6\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        guard case .changed = result.ending else {
            Issue.record("expected a new preview, got \(result.ending)")
            return
        }
        #expect(result.report.seedsUpdated == 1)
        #expect(try harness.seed("s1")?.packetCount == 4)
        #expect(try harness.seed("s2")?.packetCount == 1, "the changed target wasn't written")
    }

    @Test("a dependency changed between batches stops the run")
    func changedDependencyMidRun() async throws {
        let harness = Harness()
        try harness.insert([Self.location("loc_shed", "Shed")])
        var pauses = 0
        let writer = harness.writer(batchSize: 1) {
            pauses += 1
            if pauses == 1 { _ = try? harness.engine.enqueueCreateLocation(name: "shed", householdID: Self.household) }
        }
        let file = try harness.file("name,stored_in\nBasil,Shed\nDill,Shed\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        guard case .changed(let fresh) = result.ending else {
            Issue.record("expected a new preview, got \(result.ending)")
            return
        }
        #expect(result.report.seedsCreated == 1)
        #expect(fresh.rows.last?.action == .skipped(.ambiguousLocation("Shed")))
    }

    // MARK: - Partial failure

    @Test("a failure stops the run, reports what was saved, and a retry finishes without duplicates")
    func partialFailure() async throws {
        let harness = Harness()
        harness.store.failCreateSeedAt = 2
        let writer = harness.writer()
        // Matching is off (no year column), so only the ledger keeps the retry from duplicating.
        let file = try harness.file("name,stored_in,tags\nBasil,Attic,Spicy\nDill,Attic,\nKale,,\n")
        let plan = try await harness.preview(file, writer: writer)

        let result = await writer.run(plan: plan, file: file)

        #expect(result.ending == .failed(SeedCSVImportWriter.Failure(
            line: 3, name: "Dill", message: "Couldn't save it: injected failure"
        )))
        #expect(result.report == SeedCSVImportWriter.Report(locationsCreated: 1, tagsCreated: 1, seedsCreated: 1))
        #expect(try harness.seeds().map(\.customName) == ["Basil"])
        #expect(harness.nudges == 1)
        let text = SeedCSVImportText.failed(try #require({
            if case .failed(let failure) = result.ending { return failure } else { return nil }
        }()), totals: result.report)
        #expect(text.contains("line 3 (Dill)"))
        #expect(text.contains("Saved on this device: 1 new, 0 updated."))
        #expect(text.contains("Created 1 location and 1 tag."))

        let retryPlan = try await writer.freshPlan(for: file)
        #expect(retryPlan.unchangedCount == 1)
        #expect(retryPlan.newCount == 2)
        #expect(retryPlan.newLocations.isEmpty && retryPlan.newTags.isEmpty)
        let retry = await writer.run(plan: retryPlan, file: file)
        #expect(retry.ending == .completed)
        #expect(try harness.seeds().compactMap(\.customName).sorted() == ["Basil", "Dill", "Kale"])
        #expect(try harness.locations().count == 1)
    }

    @Test("a seed that saves but whose type fails is reported saved with its type not applied; a retry reuses it")
    func typeFailure() async throws {
        let harness = Harness()
        harness.store.failTypeAt = 1
        let writer = harness.writer()
        let file = try harness.file("name,type\nBasil,Herb\nDill,\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        let failure = SeedCSVImportWriter.Failure(
            line: 2, name: "Basil", message: "Saved, but its type wasn't applied: injected failure", typeOnly: true
        )
        #expect(result.ending == .failed(failure))
        #expect(result.report.seedsCreated == 1)
        #expect(result.report.typeNotApplied == [failure])
        #expect(SeedCSVImportText.saved(result.report).contains("Type not applied to: Basil (line 2)"))
        let failedText = SeedCSVImportText.failed(failure, totals: result.report)
        #expect(failedText.components(separatedBy: "type wasn't applied").count == 2, "said once: \(failedText)")
        #expect(!failedText.contains("Type not applied to"))
        let basil = try #require(try harness.seeds().first)
        #expect(basil.customType == nil)

        let retryPlan = try await writer.freshPlan(for: file)
        #expect(retryPlan.rows.first?.action == .update(
            seedID: basil.id, targetUpdatedAt: basil.updatedAt, changes: SeedCSVImport.Changes(type: .some("Herb"))
        ))
        let retry = await writer.run(plan: retryPlan, file: file)
        #expect(retry.ending == .completed)
        #expect(try harness.seeds().count == 2)
        #expect(try harness.seed(basil.id)?.customType == "Herb")
        let totals = result.report + retry.report
        #expect(totals.typeNotApplied.isEmpty, "the retry applied the type, so its warning is dropped")
        #expect(!SeedCSVImportText.saved(totals).contains("Type not applied"))
    }

    // MARK: - Round trip

    @Test("export, then import into the same store: nothing is written")
    func roundTripNoOp() async throws {
        let harness = Harness()
        try harness.insert([
            Self.location("loc_shed", "Shed"),
            Self.location("loc_gone", "Gone", deleted: true),
            Self.tag("tag_herb", "Herb"),
            Self.tag("tag_gone", "Gone", deleted: true),
            Self.tag("tag_semi", "a;b\\c"),
            Self.seed("s1", name: "Cherokee", variety: "Purple", company: "Baker", year: 2024, packets: 3,
                      state: .saved, locationID: "loc_shed", tagIDs: ["tag_herb", "tag_gone"],
                      notes: "Line one\nline two", type: "Tomato", catalogID: "cat_1"),
            Self.seed("s2", name: "=cmd", variety: "'quoted", locationID: "loc_gone", tagIDs: ["tag_semi"],
                      notes: "  padded "),
            Self.seed("s3", name: nil, catalogID: "cat_2"),
            Self.seed("s4", name: "Thyme", type: " Herb "),
        ])
        let writer = harness.writer()
        let file = try SeedCSVImport.parse(data: try harness.export())
        let plan = try await harness.preview(file, writer: writer)
        #expect(plan.unchangedCount == 4, "\(plan.rows)")
        #expect(plan.writeCount == 0)

        let result = await writer.run(plan: plan, file: file)

        #expect(result.ending == .completed)
        #expect(result.report == SeedCSVImportWriter.Report())
        #expect(try harness.pending().isEmpty)
        #expect(harness.nudges == 0)
    }

    @Test("export, edit one cell, import: only that field changes and hidden values stay")
    func roundTripOneEdit() async throws {
        let harness = Harness()
        try harness.insert([
            Self.location("loc_gone", "Gone", deleted: true),
            Self.tag("tag_herb", "Herb"),
            Self.tag("tag_gone", "Gone", deleted: true),
            Self.seed("s1", name: "Basil", locationID: "loc_gone", tagIDs: ["tag_herb", "tag_gone"],
                      notes: "Old", catalogID: "cat_1"),
            Self.seed("s2", name: "Dill"),
        ])
        let writer = harness.writer()
        let exported = String(decoding: try harness.export(), as: UTF8.self)
        let edited = exported.replacingOccurrences(of: ",Old,", with: ",New,")
        #expect(edited != exported)
        let file = try SeedCSVImport.parse(edited)
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        #expect(result.ending == .completed)
        #expect(result.report.seedsUpdated == 1)
        let pending = try harness.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.payload as NSDictionary? == ["notes": "New"] as NSDictionary)
        let basil = try #require(try harness.seed("s1"))
        #expect(basil.notes == "New")
        #expect(basil.catalogID == "cat_1")
        #expect(basil.locationID == "loc_gone", "a deleted location is left alone")
        #expect(basil.tagIDs == ["tag_herb", "tag_gone"], "unresolved tags are kept")
        #expect(basil.source == .gift)
    }

    // MARK: - Session

    private func session(_ harness: Harness) -> SeedCSVImportSession {
        SeedCSVImportSession(
            householdID: Self.household,
            store: harness.store,
            container: harness.container,
            currentHouseholdID: { [unowned harness] in harness.household },
            nudgeSync: { [unowned harness] in harness.nudges += 1 }
        )
    }

    private func waitForResult(_ session: SeedCSVImportSession) async throws {
        for _ in 0..<500 where session.isWriting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isWriting)
    }

    @Test("nothing is written before Import, and Import can't be pressed twice")
    func importOnce() async throws {
        let harness = Harness()
        let session = session(harness)
        await session.load(data: Data("name,stored_in\nBasil,Attic\nDill,Attic\n".utf8))
        #expect(session.phase == .preview)
        #expect(session.plan?.newCount == 2)
        #expect(try harness.pending().isEmpty, "the preview writes nothing")

        session.startImport()
        #expect(session.isWriting)
        #expect(!session.canImport)
        session.startImport()
        try await waitForResult(session)

        #expect(try harness.seeds().count == 2)
        #expect(try harness.locations().count == 1)
        #expect(session.phase == .result(message: "Saved on this device: 2 new, 0 updated. Created 1 location.", canReview: false))
        #expect(harness.nudges == 1)
    }

    @Test("a fatal file problem is refused with its message")
    func refusedFile() async {
        let harness = Harness()
        let session = session(harness)
        await session.load(data: Data([0xFF, 0xFE, 0x6E, 0x00]))
        #expect(session.phase == .refused(SeedCSVImport.FatalError.notUTF8.message))
        #expect(!session.canImport)
    }

    @Test("a garden change while the preview is open refuses the import")
    func sessionHouseholdChange() async throws {
        let harness = Harness()
        let session = session(harness)
        await session.load(data: Data("name\nBasil\n".utf8))
        harness.household = "hh_other"
        session.householdChanged()
        #expect(session.phase == .refused(SeedCSVImportWriter.householdChangedMessage))
        session.startImport()
        #expect(try harness.pending().isEmpty)
    }

    @Test("a change after the preview shows the new preview with a notice instead of writing")
    func sessionChangedPreview() async throws {
        let harness = Harness()
        try harness.insert([Self.seed("s1")])
        let session = session(harness)
        await session.load(data: Data("\(Self.identity),packets\nBasil,,,,3\n".utf8))
        try harness.engine.enqueueUpdateSeed(id: "s1", .init(notes: .some("Remote")))
        let before = try harness.pending().count

        session.startImport()
        try await waitForResult(session)

        #expect(session.phase == .preview)
        #expect(session.notice == SeedCSVImportSession.changedNotice)
        #expect(try harness.pending().count == before)
    }

    // MARK: - Retry after a created dependency changes

    @Test("a retry recreates a location or tag this import created that was since deleted or renamed")
    func retryRecreatesStaleDependencies() async throws {
        let harness = Harness()
        harness.store.failCreateSeedAt = 2
        let writer = harness.writer()
        let file = try harness.file("name,stored_in,tags\nBasil,Attic,Spicy\nDill,Attic,Spicy\n")
        let first = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)
        #expect(first.report.locationsCreated == 1 && first.report.tagsCreated == 1)
        let attic = try #require(try harness.locations().first)
        let spicy = try #require(try harness.tags().first)
        try harness.engine.enqueueDeleteLocation(id: attic.id)
        try harness.engine.enqueueUpdateTag(id: spicy.id, name: "Mild", color: nil)

        let retryPlan = try await harness.preview(file, writer: writer)
        #expect(retryPlan.newLocations.map(\.name) == ["Attic"])
        #expect(retryPlan.newTags.map(\.name) == ["Spicy"])
        #expect(writer.ledger.createdLocations.isEmpty && writer.ledger.createdTags.isEmpty)
        let retry = await writer.run(plan: retryPlan, file: file)

        #expect(retry.ending == .completed, "the retry doesn't loop back to the preview")
        #expect(retry.report.locationsCreated == 1 && retry.report.tagsCreated == 1)
        let newAttic = try #require(try harness.locations().first { $0.name == "Attic" })
        let newSpicy = try #require(try harness.tags().first { $0.name == "Spicy" })
        #expect(newAttic.id != attic.id && newAttic.deletedAt == nil, "seeds point at a live location, not the deleted one")
        #expect(newSpicy.id != spicy.id && newSpicy.deletedAt == nil)
        let seeds = try harness.seeds()
        #expect(seeds.count == 2)
        #expect(seeds.allSatisfy { $0.locationID == newAttic.id })
        #expect(seeds.first { $0.customName == "Dill" }?.tagIDs == [newSpicy.id])
    }

    // MARK: - Main-actor slices

    @Test("a 5,000-row run yields often: its longest main-actor slice stays within a generous bound")
    func longestSlice() async throws {
        let harness = Harness()
        var models: [any PersistentModel] = [Self.location("loc_shed", "Shed")]
        var lines = ["\(Self.identity),packets,stored_in,tags"]
        for index in 0..<5_000 {
            if index.isMultiple(of: 2) {
                models.append(Self.seed("s\(index)", name: "Seed \(index)", year: 2020))
            }
            // 1,000 new locations and 1,000 new tags, created in the same slices.
            lines.append("Seed \(index),,,2020,\(index % 7 + 2),Loc \(index % 1_000),Tag \(index % 1_000)")
        }
        try harness.insert(models)
        let clock = ContinuousClock()
        var resumed: ContinuousClock.Instant?
        var longest = Duration.zero
        var pauses = 0
        let writer = harness.writer {
            // Timing starts at the first write, so the first slice counts too.
            if let start = resumed ?? harness.store.firstWriteAt { longest = max(longest, clock.now - start) }
            pauses += 1
            await Task.yield()
            resumed = clock.now
        }
        let file = try harness.file(lines.joined(separator: "\n"))
        let plan = try await harness.preview(file, writer: writer)
        #expect(plan.newCount == 2_500 && plan.updatedCount == 2_500)
        #expect(plan.newLocations.count == 1_000 && plan.newTags.count == 1_000)

        var progressCalls = 0
        let result = await writer.run(plan: plan, file: file) { _, _ in progressCalls += 1 }
        if let resumed { longest = max(longest, clock.now - resumed) }

        #expect(result.ending == .completed)
        #expect(result.report.seedsCreated == 2_500 && result.report.seedsUpdated == 2_500)
        #expect(result.report.locationsCreated == 1_000 && result.report.tagsCreated == 1_000)
        #expect(pauses > 1, "the run yields between time slices")
        #expect(progressCalls >= pauses)
        #expect(longest < .seconds(1), "longest main-actor slice: \(longest)")
    }

    // MARK: - App-wide session

    private func makeSession(_ harness: Harness) -> SeedCSVImportSession {
        session(harness)
    }

    @Test("a second import is refused while one is writing, and the session outlives its screen")
    func centerRefusesSecondOpen() async throws {
        let harness = Harness()
        let center = SeedCSVImportCenter()
        let screen = UUID()
        let first = makeSession(harness)
        #expect(center.begin(first, presenter: screen))
        await first.load(data: Data("name\nBasil\nDill\n".utf8))
        #expect(!center.begin(makeSession(harness), presenter: screen), "previewing: refused")

        first.startImport()
        #expect(center.isWriting)
        let other = UUID()
        #expect(!center.begin(makeSession(harness), presenter: other), "writing: refused")
        #expect(center.session === first)

        // The screen goes away mid-run; closing is refused while writing.
        center.release(screen)
        center.close()
        #expect(center.session === first)
        #expect(!center.isPresented(by: screen))
        try await waitForResult(first)
        #expect(try harness.seeds().count == 2, "the run finished without its screen")

        // Showing Seeds again presents the finished import; a new one may then start.
        center.claim(other)
        #expect(center.isPresented(by: other))
        guard case .result = first.phase else { Issue.record("expected a result, got \(first.phase)"); return }
        let next = makeSession(harness)
        #expect(center.begin(next, presenter: other))
        #expect(center.session === next)
    }

    @Test("a garden change after the run keeps the result")
    func householdChangeAfterResult() async throws {
        let harness = Harness()
        let session = session(harness)
        await session.load(data: Data("name\nBasil\n".utf8))
        session.startImport()
        try await waitForResult(session)
        let finished = session.phase
        harness.household = "hh_other"
        session.householdChanged()
        #expect(session.phase == finished)
    }

    @Test("the off-main snapshot maps seeds exactly as SeedTableRow.rows does for export")
    func snapshotMatchesExportRows() throws {
        let harness = Harness()
        try harness.insert([
            Self.location("loc_shed", "Shed"),
            Self.location("loc_gone", "Gone", deleted: true),
            Self.tag("tag_herb", "Herb"),
            Self.tag("tag_gone", "Gone", deleted: true),
            Self.seed("s1", name: " Basil ", variety: " V ", company: "", year: 2024, locationID: "loc_shed",
                      tagIDs: ["tag_herb", "tag_gone"], notes: " n ", type: " Herb ", catalogID: "cat"),
            Self.seed("s2", name: nil, locationID: "loc_gone"),
        ])
        let household = Self.household
        let context = ModelContext(harness.container)
        let expected = SeedTableRow.rows(
            seeds: try context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.householdID == household })),
            locations: try context.fetch(FetchDescriptor<LocalLocation>()),
            tags: try context.fetch(FetchDescriptor<LocalTag>()),
            recommendations: [:]
        ).sorted { $0.id < $1.id }
        let snapshot = try SeedCSVImport.snapshot(householdID: household, container: harness.container)
        #expect(snapshot.seeds == expected)
        #expect(snapshot.locations.map(\.id) == ["loc_shed"])
        #expect(snapshot.tags.map(\.id) == ["tag_herb"])
    }

    @Test("the matching-off notice warns that an interrupted import adds rows again")
    func noMatchingNotice() {
        #expect(SeedCSVImportText.noMatchingNotice.hasSuffix("If an import is interrupted, importing this file again adds its rows again."))
    }

    // MARK: - Fingerprint and dependencies mid-run

    /// Rewrites a seed directly, as a sync apply would, keeping or setting its clock.
    private func apply(_ harness: Harness, seedID: String, _ change: (LocalSeed) -> Void) throws {
        let context = ModelContext(harness.container)
        let seed = try #require(try context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == seedID })).first)
        change(seed)
        try context.save()
    }

    @Test("an older-clock edit of a non-target seed is detected and forces a new preview before the next write")
    func olderClockEditDetected() async throws {
        let harness = Harness()
        try harness.insert([Self.seed("s1", name: "Basil"), Self.seed("s9", name: "Kale")])
        var pauses = 0
        let writer = harness.writer(batchSize: 1) {
            pauses += 1
            // A peer renames Kale to Dill, stamping a clock older than this run's own writes.
            if pauses == 1 { try? self.apply(harness, seedID: "s9") { $0.customName = "Dill"; $0.updatedAt = 2 } }
        }
        let file = try harness.file("\(Self.identity),packets\nBasil,,,,4\nDill,,,,2\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        guard case .changed(let fresh) = result.ending else {
            Issue.record("expected a new preview, got \(result.ending)")
            return
        }
        #expect(result.report.seedsUpdated == 1)
        #expect(result.report.seedsCreated == 0, "Dill wasn't created as a duplicate")
        #expect(fresh.rows.last?.action == .update(
            seedID: "s9", targetUpdatedAt: 2, changes: SeedCSVImport.Changes(packets: 2)
        ))
    }

    @Test("a delete plus a create that keep the count and newest change are detected")
    func deleteAndCreateDetected() async throws {
        let harness = Harness()
        try harness.insert([Self.seed("s1", name: "Basil"), Self.seed("s9", name: "Kale")])
        var pauses = 0
        let writer = harness.writer(batchSize: 1) {
            pauses += 1
            if pauses == 1 {
                let context = ModelContext(harness.container)
                if let kale = try? context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "s9" })).first {
                    context.delete(kale)
                }
                context.insert(Self.seed("s10", name: "Dill"))
                try? context.save()
            }
        }
        let file = try harness.file("\(Self.identity),packets\nBasil,,,,4\nDill,,,,2\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        guard case .changed = result.ending else {
            Issue.record("expected a new preview, got \(result.ending)")
            return
        }
        #expect(result.report.seedsCreated == 0)
        #expect(try harness.seeds().filter { $0.customName == "Dill" }.count == 1)
    }

    @Test("a location this run created, renamed mid-run, asks for a new preview instead of failing")
    func createdDependencyRenamedMidRun() async throws {
        let harness = Harness()
        var pauses = 0
        let writer = harness.writer(batchSize: 1) {
            pauses += 1
            if pauses == 1, let attic = try? harness.locations().first {
                try? harness.engine.enqueueUpdateLocation(id: attic.id, name: "Loft", sortOrder: nil)
            }
        }
        let file = try harness.file("name,stored_in\nBasil,Attic\nDill,Attic\n")
        let result = await writer.run(plan: try await harness.preview(file, writer: writer), file: file)

        guard case .changed(let fresh) = result.ending else {
            Issue.record("expected a new preview, got \(result.ending)")
            return
        }
        #expect(result.report.locationsCreated == 1)
        #expect(try harness.seeds().isEmpty)
        #expect(fresh.newLocations.map(\.name) == ["Attic"], "the new preview creates it again")
        let retry = await writer.run(plan: fresh, file: file)
        #expect(retry.ending == .completed)
        let attic = try #require(try harness.locations().first { $0.name == "Attic" })
        #expect(try harness.seeds().allSatisfy { $0.locationID == attic.id })
    }

    @Test("an import request from another window is told the import is open there")
    func requestFromAnotherWindow() async throws {
        let harness = Harness()
        let center = SeedCSVImportCenter()
        let windowA = UUID()
        let windowB = UUID()
        #expect(center.request(from: windowA) == .pickFile)
        let session = makeSession(harness)
        #expect(center.begin(session, presenter: windowA))
        await session.load(data: Data("name\nBasil\n".utf8))
        #expect(center.request(from: windowA) == .showHere)
        #expect(center.request(from: windowB) == .openElsewhere)
        // Window A closes: window B takes the import over.
        center.release(windowA)
        center.claim(windowB)
        #expect(center.isPresented(by: windowB))
        #expect(center.request(from: windowB) == .showHere)
        #expect(center.request(from: windowA) == .openElsewhere)
    }
}
