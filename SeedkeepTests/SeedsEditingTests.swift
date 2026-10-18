import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Seeds table, slice B: drafts, validation, inline and bulk writes through `SyncEngine`, undo and
/// redo, partial failures, delete confirmation, and the household check on undo.
/// Records the reports a writer presents, so tests can check what the user would see.
@MainActor
private final class IssueLog {
    var reports: [SeedWriteReport] = []
}

@MainActor
@Suite("Seeds table — inline edits, bulk changes and undo", .serialized)
struct SeedsEditingTests {

    private static let household = "hh_edit"

    /// A household id the test can change after a write, to check the undo-time household check.
    private final class HouseholdBox {
        var id: String?
        init(_ id: String?) { self.id = id }
    }

    private static func makeContainer() -> ModelContainer {
        makeTestContainer(name: "seedsEditing-\(UUID().uuidString)")
    }

    private static func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private static func makeWriter(
        container: ModelContainer,
        undo: UndoManager,
        household: HouseholdBox,
        log: IssueLog = IssueLog()
    ) -> SeedWriter {
        let client = SeedkeepClient(configuration: .init(baseURL: URL(string: "https://test.invalid")!))
        let sync = SyncEngine(client: client, container: container)
        return SeedWriter(
            sync: sync,
            container: container,
            undoManager: undo,
            currentHouseholdID: { household.id },
            flush: {},
            presentIssues: { report in log.reports.append(report) }
        )
    }

    private static func seed(
        _ id: String,
        packets: Int = 2,
        year: Int? = 2020,
        state: SeedState = .active,
        locationID: String? = nil,
        tagIDs: [String] = []
    ) -> LocalSeed {
        LocalSeed(
            id: id,
            householdID: household,
            state: state,
            packetCount: packets,
            locationID: locationID,
            yearPacked: year,
            source: .store,
            customName: "Seed \(id)",
            tagIDs: tagIDs,
            createdAt: 1,
            updatedAt: 1
        )
    }

    private static func insert(_ seeds: [LocalSeed], into container: ModelContainer) throws {
        let context = ModelContext(container)
        for seed in seeds {
            context.insert(seed)
        }
        try context.save()
    }

    private static func fetchSeed(_ id: String, in container: ModelContainer) throws -> LocalSeed {
        let context = ModelContext(container)
        let target = id
        let descriptor = FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == target })
        return try #require(try context.fetch(descriptor).first)
    }

    /// The queued seed writes for one seed, oldest first, as their decoded JSON objects.
    private static func pendingPayloads(for id: String, in container: ModelContainer) throws -> [(operation: String, payload: [String: Any])] {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LocalPendingWrite>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
        return try rows
            .filter { $0.entityType == "seed" && $0.entityID == id }
            .map { row in
                let object = try #require(
                    JSONSerialization.jsonObject(with: Data(row.payloadJSON.utf8)) as? [String: Any]
                )
                return (operation: row.operation, payload: object)
            }
    }

    private static func key(_ id: String, _ field: SeedDraftField) -> SeedDraftKey {
        SeedDraftKey(seedID: id, field: field)
    }

    // MARK: - Validation

    @Test("packets must be a whole number of 0 or more")
    func packetValidation() {
        #expect(SeedInputValidation.packets("0") == .success(0))
        #expect(SeedInputValidation.packets(" 12 ") == .success(12))
        #expect(SeedInputValidation.packets("-1") == .failure(.packetsNotWholeNumber))
        #expect(SeedInputValidation.packets("2.5") == .failure(.packetsNotWholeNumber))
        #expect(SeedInputValidation.packets("") == .failure(.packetsNotWholeNumber))
        #expect(SeedInputValidation.packets("many") == .failure(.packetsNotWholeNumber))
    }

    @Test("year is empty or from 1900 to next year")
    func yearValidation() {
        #expect(SeedInputValidation.year("", currentYear: 2026) == .success(nil), "empty clears the year")
        #expect(SeedInputValidation.year("1900", currentYear: 2026) == .success(1900))
        #expect(SeedInputValidation.year("2027", currentYear: 2026) == .success(2027), "next year is allowed")
        #expect(SeedInputValidation.year("1899", currentYear: 2026) == .failure(.yearOutOfRange(earliest: 1900, latest: 2027)))
        #expect(SeedInputValidation.year("2028", currentYear: 2026) == .failure(.yearOutOfRange(earliest: 1900, latest: 2027)))
        #expect(SeedInputValidation.year("soon", currentYear: 2026) == .failure(.yearOutOfRange(earliest: 1900, latest: 2027)))
        #expect(SeedEditError.yearOutOfRange(earliest: 1900, latest: 2027).message == "Enter a year from 1900 to 2027, or leave it empty.")
    }

    // MARK: - Drafts

    @Test("drafts are keyed by seed and field, and cancel suppresses only the blur that follows")
    func draftLifecycle() {
        let editing = SeedEditing()
        let year = Self.key("s1", .year)
        let packets = Self.key("s1", .packets)

        editing.setDraft("2024", for: year)
        #expect(editing.text(for: year, shown: "2020") == "2024")
        #expect(editing.text(for: packets, shown: "3") == "3", "a field with no draft shows the stored value")

        editing.fail(year, message: "bad")
        #expect(editing.errors[year] == "bad")
        editing.setDraft("2025", for: year)
        #expect(editing.errors[year] == nil, "typing again clears the old error")

        editing.cancel(year)
        #expect(editing.draft(for: year) == nil)
        #expect(editing.consumeSuppressedBlur(for: year), "the blur after Escape is suppressed")
        #expect(!editing.consumeSuppressedBlur(for: year), "only once")
        #expect(!editing.consumeSuppressedBlur(for: packets))

        editing.setDraft("4", for: packets)
        editing.finish(packets)
        #expect(editing.draft(for: packets) == nil)
    }

    @Test("drafts for seeds that disappear are dropped and reported")
    func draftsForMissingSeeds() {
        let editing = SeedEditing()
        editing.setDraft("5", for: Self.key("gone", .packets))
        editing.setDraft("2024", for: Self.key("kept", .year))

        let removed = editing.discardMissing(liveIDs: ["kept"])

        #expect(removed == ["gone"])
        #expect(editing.draft(for: Self.key("gone", .packets)) == nil)
        #expect(editing.draft(for: Self.key("kept", .year)) == "2024")
    }

    // MARK: - Inline commit

    @Test("an inline year commit patches only the year and advances updatedAt")
    func inlineCommitPatchesOnlyTheField() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", packets: 2, year: 2020)], into: container)
        let writer = Self.makeWriter(container: container, undo: Self.makeUndoManager(), household: HouseholdBox(Self.household))

        let result = writer.commitDraft(Self.key("s1", .year), text: "2022", currentYear: 2026)

        let report = try #require(try? result.get())
        #expect(report.changed == ["s1"])
        let stored = try Self.fetchSeed("s1", in: container)
        #expect(stored.yearPacked == 2022)
        #expect(stored.packetCount == 2, "other fields are untouched")
        #expect(stored.updatedAt > 1, "the edit advances updatedAt")

        let writes = try Self.pendingPayloads(for: "s1", in: container)
        let update = try #require(writes.first)
        #expect(update.operation == "update")
        #expect(Set(update.payload.keys) == ["year_packed"], "the patch carries only the changed field")
        #expect(update.payload["year_packed"] as? Int == 2022)
    }

    @Test("clearing the year sends an explicit null")
    func clearingYearSendsNull() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", year: 2020)], into: container)
        let writer = Self.makeWriter(container: container, undo: Self.makeUndoManager(), household: HouseholdBox(Self.household))

        _ = writer.commitDraft(Self.key("s1", .year), text: "  ", currentYear: 2026)

        let stored = try Self.fetchSeed("s1", in: container)
        #expect(stored.yearPacked == nil)
        let update = try #require(try Self.pendingPayloads(for: "s1", in: container).first)
        #expect(update.payload["year_packed"] is NSNull)
        #expect(Set(update.payload.keys) == ["year_packed"])
    }

    @Test("an invalid draft writes nothing and returns the error")
    func invalidDraftWritesNothing() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", packets: 2, year: 2020)], into: container)
        let writer = Self.makeWriter(container: container, undo: Self.makeUndoManager(), household: HouseholdBox(Self.household))

        #expect(writer.commitDraft(Self.key("s1", .packets), text: "-3", currentYear: 2026) == .failure(.packetsNotWholeNumber))
        #expect(writer.commitDraft(Self.key("s1", .year), text: "1899", currentYear: 2026)
            == .failure(.yearOutOfRange(earliest: 1900, latest: 2027)))

        let stored = try Self.fetchSeed("s1", in: container)
        #expect(stored.packetCount == 2)
        #expect(stored.yearPacked == 2020)
        #expect(try Self.pendingPayloads(for: "s1", in: container).isEmpty)
    }

    @Test("a commit to the value already stored writes nothing and is not undoable")
    func unchangedCommitWritesNothing() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", packets: 2)], into: container)
        let undo = Self.makeUndoManager()
        let writer = Self.makeWriter(container: container, undo: undo, household: HouseholdBox(Self.household))

        let report = try #require(try? writer.commitDraft(Self.key("s1", .packets), text: "2", currentYear: 2026).get())

        #expect(report.unchanged == ["s1"])
        #expect(report.changed.isEmpty)
        #expect(try Self.pendingPayloads(for: "s1", in: container).isEmpty)
        #expect(!undo.canUndo)
    }

    // MARK: - Undo and redo

    @Test("undo and redo restore and re-apply an inline edit")
    func undoRedoInlineEdit() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", year: 2020)], into: container)
        let undo = Self.makeUndoManager()
        let writer = Self.makeWriter(container: container, undo: undo, household: HouseholdBox(Self.household))

        _ = writer.commitDraft(Self.key("s1", .year), text: "2022", currentYear: 2026)
        #expect(undo.canUndo)
        #expect(try Self.fetchSeed("s1", in: container).yearPacked == 2022)

        undo.undo()
        #expect(try Self.fetchSeed("s1", in: container).yearPacked == 2020)
        #expect(undo.canRedo)

        undo.redo()
        #expect(try Self.fetchSeed("s1", in: container).yearPacked == 2022)
    }

    @Test("one undo reverts a bulk status change on every seed, and redo re-applies it")
    func undoRedoBulkStatus() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("a"), Self.seed("b"), Self.seed("c", state: .wishlist)], into: container)
        let undo = Self.makeUndoManager()
        let writer = Self.makeWriter(container: container, undo: undo, household: HouseholdBox(Self.household))

        let report = writer.apply(.status(.saved), to: ["a", "b", "c"])
        #expect(report.changed.sorted() == ["a", "b", "c"])
        #expect(try Self.fetchSeed("c", in: container).state == .saved)

        undo.undo()
        #expect(try Self.fetchSeed("a", in: container).state == .active)
        #expect(try Self.fetchSeed("b", in: container).state == .active)
        #expect(try Self.fetchSeed("c", in: container).state == .wishlist, "each seed gets its own previous value")
        #expect(!undo.canUndo, "the whole bulk change was one undo step")

        undo.redo()
        #expect(try Self.fetchSeed("a", in: container).state == .saved)
        #expect(try Self.fetchSeed("c", in: container).state == .saved)
    }

    @Test("bulk tag adds skip seeds that already have the tag, and undo restores the list exactly")
    func bulkAddTag() throws {
        let container = Self.makeContainer()
        try Self.insert([
            Self.seed("a", tagIDs: []),
            Self.seed("b", tagIDs: ["tag_x"]),
        ], into: container)
        let undo = Self.makeUndoManager()
        let writer = Self.makeWriter(container: container, undo: undo, household: HouseholdBox(Self.household))

        let report = writer.apply(.addTag("tag_x"), to: ["a", "b"])

        #expect(report.changed == ["a"])
        #expect(report.unchanged == ["b"], "no duplicate tag")
        #expect(try Self.fetchSeed("a", in: container).tagIDs == ["tag_x"])
        #expect(try Self.fetchSeed("b", in: container).tagIDs == ["tag_x"])

        undo.undo()
        #expect(try Self.fetchSeed("a", in: container).tagIDs == [])
        #expect(try Self.fetchSeed("b", in: container).tagIDs == ["tag_x"])
    }

    @Test("moving to no location clears it with an explicit null, and undo puts it back")
    func moveAndUndoLocation() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("a", locationID: "loc_shed")], into: container)
        let undo = Self.makeUndoManager()
        let writer = Self.makeWriter(container: container, undo: undo, household: HouseholdBox(Self.household))

        _ = writer.apply(.location(nil), to: ["a"])
        #expect(try Self.fetchSeed("a", in: container).locationID == nil)
        let update = try #require(try Self.pendingPayloads(for: "a", in: container).first)
        #expect(update.payload["location_id"] is NSNull)

        undo.undo()
        #expect(try Self.fetchSeed("a", in: container).locationID == "loc_shed")
    }

    @Test("partial failures are reported, and undo covers only the seeds that changed")
    func partialFailureRegistersUndoForSuccesses() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", packets: 2)], into: container)
        let undo = Self.makeUndoManager()
        let writer = Self.makeWriter(container: container, undo: undo, household: HouseholdBox(Self.household))

        let report = writer.apply(.packets(5), to: ["s1", "missing"])

        #expect(report.changed == ["s1"])
        #expect(report.failures == [SeedWriteFailure(seedID: "missing", name: "A seed", message: "No longer available.")])
        #expect(try Self.fetchSeed("s1", in: container).packetCount == 5)

        undo.undo()
        #expect(try Self.fetchSeed("s1", in: container).packetCount == 2)
        #expect(!undo.canUndo, "the failed seed was never registered")
    }

    @Test("undo does not write to a seed deleted since the edit")
    func undoRevalidatesDeletedSeed() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", year: 2020)], into: container)
        let undo = Self.makeUndoManager()
        let writer = Self.makeWriter(container: container, undo: undo, household: HouseholdBox(Self.household))

        _ = writer.commitDraft(Self.key("s1", .year), text: "2022", currentYear: 2026)
        _ = writer.confirmDeletion(writer.requestDeletion(["s1"]))
        #expect(try Self.fetchSeed("s1", in: container).deletedAt != nil)

        undo.undo()

        let updates = try Self.pendingPayloads(for: "s1", in: container).filter { $0.operation == "update" }
        #expect(updates.count == 1)
        #expect(updates.first?.payload["year_packed"] as? Int == 2022, "no reverting write was queued")
        #expect(try Self.fetchSeed("s1", in: container).yearPacked == 2022)
    }

    @Test("undo does not write to a seed that has moved to another household")
    func undoRevalidatesHousehold() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", year: 2020)], into: container)
        let undo = Self.makeUndoManager()
        let household = HouseholdBox(Self.household)
        let writer = Self.makeWriter(container: container, undo: undo, household: household)

        _ = writer.commitDraft(Self.key("s1", .year), text: "2022", currentYear: 2026)
        household.id = "hh_someone_else"

        undo.undo()

        #expect(try Self.fetchSeed("s1", in: container).yearPacked == 2022)
    }

    // MARK: - Delete

    @Test("a delete needs a confirmed request, and deleting a missing seed is reported")
    func deleteNeedsConfirmation() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1")], into: container)
        let writer = Self.makeWriter(container: container, undo: Self.makeUndoManager(), household: HouseholdBox(Self.household))

        let request = writer.requestDeletion(["s1"])
        #expect(request.count == 1)
        #expect(try Self.fetchSeed("s1", in: container).deletedAt == nil, "asking does not delete")

        let report = writer.confirmDeletion(request)
        #expect(report.changed == ["s1"])
        #expect(try Self.fetchSeed("s1", in: container).deletedAt != nil)

        let again = writer.confirmDeletion(writer.requestDeletion(["s1"]))
        #expect(again.changed.isEmpty)
        #expect(again.failures.map(\.seedID) == ["s1"])
    }

    @Test("a delete request for several seeds names the count and is sorted")
    func deleteRequestCount() {
        let container = Self.makeContainer()
        let writer = Self.makeWriter(container: container, undo: Self.makeUndoManager(), household: HouseholdBox(Self.household))
        let request = writer.requestDeletion(["b", "a", "b"])
        #expect(request.seedIDs == ["a", "b"])
        #expect(request.count == 2)
    }

    @Test("a seed from another household is not written")
    func foreignHouseholdIsNotWritten() throws {
        let container = Self.makeContainer()
        let foreign = Self.seed("s1")
        foreign.householdID = "hh_other"
        try Self.insert([foreign], into: container)
        let writer = Self.makeWriter(container: container, undo: Self.makeUndoManager(), household: HouseholdBox(Self.household))

        let report = writer.apply(.packets(9), to: ["s1"])

        #expect(report.changed.isEmpty)
        #expect(report.failures.map(\.seedID) == ["s1"])
        #expect(report.failures.first?.name == "A seed", "another household's name never reaches a message")
        #expect(try Self.fetchSeed("s1", in: container).packetCount == 2)
    }

    // MARK: - Failures are presented, whatever produced them

    @Test("an undo that finds its seed deleted presents a message instead of failing silently")
    func undoFailureIsPresented() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("s1", year: 2020)], into: container)
        let undo = Self.makeUndoManager()
        let log = IssueLog()
        let writer = Self.makeWriter(container: container, undo: undo, household: HouseholdBox(Self.household), log: log)

        _ = writer.commitDraft(Self.key("s1", .year), text: "2022", currentYear: 2026)
        _ = writer.confirmDeletion(writer.requestDeletion(["s1"]))
        #expect(log.reports.isEmpty, "a successful delete presents nothing")

        undo.undo()

        #expect(log.reports.count == 1)
        #expect(log.reports.last?.issueMessage == "Couldn't change 1 of 1 seed: Seed s1. No longer available.")
    }

    @Test("a partly failed bulk change presents its failures, and the message names them")
    func partialBulkFailureIsPresented() throws {
        let container = Self.makeContainer()
        try Self.insert([Self.seed("a"), Self.seed("b")], into: container)
        let log = IssueLog()
        let writer = Self.makeWriter(container: container, undo: Self.makeUndoManager(), household: HouseholdBox(Self.household), log: log)

        let report = writer.apply(.status(.saved), to: ["a", "b", "ghost"])

        #expect(report.changed.sorted() == ["a", "b"])
        #expect(log.reports.count == 1)
        #expect(log.reports.first?.issueMessage == "Couldn't change 1 of 3 seeds: A seed. No longer available.")
    }

    @Test("a clean write presents nothing, and an issue message exists only when something failed")
    func issueMessageOnlyOnFailure() {
        #expect(SeedWriteReport(changed: ["a"]).issueMessage == nil)
        #expect(SeedWriteReport(unchanged: ["a"]).issueMessage == nil)
        let failed = SeedWriteReport(
            changed: ["a", "b"],
            failures: [SeedWriteFailure(seedID: "c", name: "Basil", message: "No longer available.")]
        )
        #expect(failed.issueMessage == "Couldn't change 1 of 3 seeds: Basil. No longer available.")
    }
}
