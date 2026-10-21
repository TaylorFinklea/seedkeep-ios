import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

/// The Garden screens over the in-memory store and `SyncEngine` (R3 G2): New and Edit bed send only
/// what changed, resizing never moves plantings, a Plan paints end to end, a household change resets
/// the session, and a remote deletion of the selected planting closes details.
@MainActor
@Suite("Garden — screens over SyncEngine", .serialized)
struct GardenScreensIntegrationTests {
    static let household = "hh_screens"
    static let day = CalendarDay.make(year: 2026, month: 5, day: 10)!

    @MainActor
    final class Harness {
        let container: ModelContainer
        let engine: SyncEngine
        var household: String? = GardenScreensIntegrationTests.household

        init() {
            container = makeTestContainer(name: "gardenScreensTests")
            let client = SeedkeepClient(configuration: .init(baseURL: URL(string: "https://test.invalid")!))
            engine = SyncEngine(client: client, container: container)
        }

        func update(_ form: BedForm, bedID: String) throws -> GardenActions.Outcome {
            try BedFormWriter.update(
                form, scope: .init(householdID: GardenScreensIntegrationTests.household, bedID: bedID),
                currentHouseholdID: household, sync: engine, container: container
            )
        }

        func deleteBed(_ bedID: String) throws -> GardenActions.Outcome {
            try BedFormWriter.delete(
                scope: .init(householdID: GardenScreensIntegrationTests.household, bedID: bedID),
                currentHouseholdID: household, sync: engine, container: container
            )
        }

        func actions(bedID: String) -> GardenActions {
            GardenActions(
                sync: engine,
                container: container,
                scope: .init(householdID: GardenScreensIntegrationTests.household, bedID: bedID),
                currentHouseholdID: { [unowned self] in self.household }
            )
        }

        func insert(_ models: [any PersistentModel]) throws {
            let context = ModelContext(container)
            for model in models { context.insert(model) }
            try context.save()
        }

        func all<T: PersistentModel>(_ type: T.Type) throws -> [T] {
            try ModelContext(container).fetch(FetchDescriptor<T>())
        }

        func bed(_ id: String) throws -> LocalBed? {
            try ModelContext(container).fetch(FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == id })).first
        }

        func event(_ id: String) throws -> LocalPlantingEvent? {
            try ModelContext(container).fetch(
                FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id })
            ).first
        }

        /// Pending writes for one entity, payloads decoded.
        func pending(_ entityID: String) throws -> [(op: String, payload: [String: Any])] {
            let rows = try ModelContext(container).fetch(FetchDescriptor<LocalPendingWrite>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )).filter { $0.entityID == entityID }
            return rows.map { row in
                let object = (try? JSONSerialization.jsonObject(with: Data(row.payloadJSON.utf8))) as? [String: Any]
                return (row.operation, object ?? [:])
            }
        }

        func snapshot(householdID: String? = GardenScreensIntegrationTests.household) throws -> GardenSession.Snapshot {
            GardenSessionReconciler.snapshot(
                householdID: householdID, isSignedIn: true,
                beds: try all(LocalBed.self), events: try all(LocalPlantingEvent.self), seeds: try all(LocalSeed.self)
            )
        }

        func data(bedID: String) throws -> GardenBedData {
            let bed = try #require(try bed(bedID))
            return GardenBedData(bed: bed, events: try all(LocalPlantingEvent.self), seeds: try all(LocalSeed.self),
                                 climate: nil)
        }
    }

    static func bed(_ id: String, width: Double?, length: Double?, sortOrder: Int = 0,
                    description: String? = nil) -> LocalBed {
        LocalBed(id: id, householdID: household, name: id.capitalized, bedDescription: description,
                 widthFeet: width, lengthFeet: length, sortOrder: sortOrder, createdAt: 1, updatedAt: 1)
    }

    static func seed(_ id: String = "seed_basil") -> LocalSeed {
        LocalSeed(id: id, householdID: household, state: .active, packetCount: 1, source: .store,
                  customName: "Basil", createdAt: 1, updatedAt: 1)
    }

    static func event(_ id: String, bed: String, x: Double?, y: Double?) -> LocalPlantingEvent {
        LocalPlantingEvent(id: id, householdID: household, bedID: bed, seedID: "seed_basil", kindRaw: "sowing",
                           plannedFor: "2026-05-01", xFeet: x, yFeet: y, createdAt: 1, updatedAt: 1)
    }

    // MARK: - New and Edit bed

    @Test func newBedCreatesAFourByEightBed() throws {
        let h = Harness()
        var form = BedForm.new()
        form.name = "North"
        form.description = "Raised"
        let created = try #require(try BedFormWriter.create(form, sync: h.engine, householdID: Self.household))
        #expect(created.hasGrid)
        let bed = try #require(try h.bed(created.id))
        #expect(bed.householdID == Self.household)
        #expect(bed.widthFeet == 4)
        #expect(bed.lengthFeet == 8)
        #expect(bed.bedDescription == "Raised")
        let write = try #require(try h.pending(created.id).first)
        #expect(write.op == "create")
        #expect(write.payload["width_feet"] as? Double == 4)
        #expect(write.payload["length_feet"] as? Double == 8)
        #expect(write.payload["name"] as? String == "North")
    }

    @Test func aBlankSizeCreatesABedWithoutAGrid() throws {
        let h = Harness()
        var form = BedForm.new()
        form.name = "Pots"
        form.width = ""
        let created = try #require(try BedFormWriter.create(form, sync: h.engine, householdID: Self.household))
        #expect(!created.hasGrid)
        #expect(try h.bed(created.id)?.widthFeet == nil)
    }

    @Test func editSendsOnlyTheChangedFieldsAndKeepsAnUntouchedOversizeSize() throws {
        let h = Harness()
        try h.insert([Self.bed("north", width: 60, length: 8.5, description: "Raised")])
        var form = BedForm.edit(.init(name: "North", description: "Raised", widthFeet: 60, lengthFeet: 8.5))
        #expect(try h.update(form, bedID: "north") == .unchanged)
        #expect(try h.pending("north").isEmpty)

        form.name = "North bed"
        #expect(try h.update(form, bedID: "north") == .written)
        let write = try #require(try h.pending("north").last)
        #expect(write.op == "update")
        #expect(Set(write.payload.keys) == ["name"])
        let bed = try #require(try h.bed("north"))
        #expect(bed.name == "North bed")
        #expect(bed.widthFeet == 60)
        #expect(bed.lengthFeet == 8.5)
        #expect(bed.bedDescription == "Raised")
    }

    @Test func resizingNeverMovesPlantings() throws {
        let h = Harness()
        try h.insert([
            Self.bed("north", width: 4, length: 8), Self.seed(),
            Self.event("far", bed: "north", x: 3.5, y: 7.5),
            Self.event("near", bed: "north", x: 0.5, y: 0.5),
        ])
        var form = BedForm.edit(.init(name: "North", description: nil, widthFeet: 4, lengthFeet: 8))
        form.width = "3"
        form.length = "6"
        #expect(try h.update(form, bedID: "north") == .written)

        let write = try #require(try h.pending("north").last)
        #expect(Set(write.payload.keys) == ["width_feet", "length_feet"])
        // No planting was written or moved.
        #expect(try h.pending("far").isEmpty)
        #expect(try h.event("far")?.xFeet == 3.5)
        #expect(try h.event("far")?.yFeet == 7.5)

        let data = try h.data(bedID: "north")
        #expect(data.size == GridSize(columns: 3, rows: 6))
        let offGrid = GardenGrid.offGrid(events: data.events, bedID: "north", size: data.size)
        #expect(offGrid.outside.map(\.id) == ["far"])
        #expect(offGrid.unplaced.isEmpty)
        let rows = data.rows(today: Self.day)
        #expect(rows.first { $0.id == "far" }?.squareText == "Outside the grid")
        #expect(rows.first { $0.id == "far" }?.canPlace == true)
        #expect(rows.first { $0.id == "near" }?.squareText == "R6 · S1")
    }

    @Test func clearingADescriptionSendsAnEmptyString() throws {
        let h = Harness()
        try h.insert([Self.bed("north", width: 4, length: 8, description: "Raised")])
        var form = BedForm.edit(.init(name: "North", description: "Raised", widthFeet: 4, lengthFeet: 8))
        form.description = "  "
        #expect(try h.update(form, bedID: "north") == .written)
        let write = try #require(try h.pending("north").last)
        #expect(write.op == "update")
        #expect(Set(write.payload.keys) == ["description"])
        #expect(write.payload["description"] as? String == "")
        #expect(try h.bed("north")?.bedDescription == "")
    }

    @Test func deletingABedTombstonesItAndQueuesADelete() throws {
        let h = Harness()
        try h.insert([Self.bed("north", width: 4, length: 8), Self.seed(), Self.event("e1", bed: "north", x: 0.5, y: 0.5)])
        #expect(try h.deleteBed("north") == .written)
        #expect(try h.bed("north")?.deletedAt != nil)
        #expect(try h.pending("north").map(\.op) == ["delete"])
        // Its plantings aren't written.
        #expect(try h.pending("e1").isEmpty)
        #expect(try h.event("e1")?.deletedAt == nil)
    }

    @Test func bedEditAndDeleteAfterAGardenChangeWriteNothing() throws {
        let h = Harness()
        try h.insert([Self.bed("north", width: 4, length: 8)])
        h.household = "hh_other"
        var form = BedForm.edit(.init(name: "North", description: nil, widthFeet: 4, lengthFeet: 8))
        form.name = "North bed"
        #expect(try h.update(form, bedID: "north") == .refused(GardenActions.scopeChangedMessage))
        #expect(try h.deleteBed("north") == .refused(GardenActions.scopeChangedMessage))
        #expect(try h.all(LocalPendingWrite.self).isEmpty)
        let bed = try #require(try h.bed("north"))
        #expect(bed.name == "North")
        #expect(bed.deletedAt == nil)
    }

    @Test func bedEditAndDeleteOfABedDeletedElsewhereWriteNothing() throws {
        let h = Harness()
        // Another device's delete lands as a local tombstone, with no pending write here.
        let gone = Self.bed("north", width: 4, length: 8)
        gone.deletedAt = 5
        try h.insert([gone, Self.bed("other", width: 4, length: 8)])
        // A bed in another garden counts as gone too.
        let foreign = LocalBed(id: "foreign", householdID: "hh_other", name: "Foreign", widthFeet: 4, lengthFeet: 8,
                               createdAt: 1, updatedAt: 1)
        try h.insert([foreign])
        for id in ["north", "foreign"] {
            var form = BedForm.edit(.init(name: "North", description: nil, widthFeet: 4, lengthFeet: 8))
            form.name = "Renamed"
            #expect(try h.update(form, bedID: id) == .refused(BedFormWriter.bedDeletedMessage))
            #expect(try h.deleteBed(id) == .refused(BedFormWriter.bedDeletedMessage))
        }
        #expect(try h.all(LocalPendingWrite.self).isEmpty)
        #expect(try h.bed("north")?.deletedAt == 5)
        #expect(try h.bed("foreign")?.name == "Foreign")
    }

    // MARK: - Place in bed

    @Test func placeInBedCreatesAPlantingAtTheSquareCentre() throws {
        let h = Harness()
        try h.insert([Self.bed("north", width: 4.5, length: 8), Self.seed()])
        let input = PlaceInBed.createInput(
            bedID: "north", seedID: "seed_basil", kind: .transplant, plannedFor: "2026-05-10", notes: "Edge",
            square: GridSquare(column: 3, rowFromTop: 1), widthFeet: 4.5, lengthFeet: 8
        )
        let created = try h.engine.enqueueCreatePlantingEvent(input, householdID: Self.household)
        let event = try #require(try h.event(created.id))
        #expect(event.householdID == Self.household)
        #expect(event.bedID == "north")
        #expect(event.seedID == "seed_basil")
        #expect(event.kindRaw == "transplant")
        #expect(event.xFeet == 3.5)
        #expect(event.yFeet == 6.5)
        let write = try #require(try h.pending(created.id).first)
        #expect(write.op == "create")
        #expect(write.payload["x_feet"] as? Double == 3.5)
        #expect(write.payload["y_feet"] as? Double == 6.5)
        #expect(write.payload["bed_id"] as? String == "north")
        // It shows in that square.
        let data = try h.data(bedID: "north")
        #expect(data.squares[GridSquare(column: 3, rowFromTop: 1)]?.events.map(\.id) == [created.id])
    }

    @Test func placeInBedOffLeavesThePlantingUnplaced() throws {
        let h = Harness()
        try h.insert([Self.bed("north", width: 4, length: 8), Self.seed()])
        let input = PlaceInBed.createInput(
            bedID: "north", seedID: "seed_basil", kind: .sowing, plannedFor: "2026-05-10", notes: nil,
            square: nil, widthFeet: 4, lengthFeet: 8
        )
        let created = try h.engine.enqueueCreatePlantingEvent(input, householdID: Self.household)
        let event = try #require(try h.event(created.id))
        #expect(event.xFeet == nil)
        #expect(event.yFeet == nil)
    }

    // MARK: - Plan

    @Test func aPlanPaintsTheSeedInItsBedEndToEnd() throws {
        let h = Harness()
        try h.insert([
            Self.bed("pots", width: nil, length: nil, sortOrder: 0),
            Self.bed("north", width: 4, length: 8, sortOrder: 1),
            Self.seed(),
        ])
        let session = GardenSession()
        session.reconcile(try h.snapshot())
        let choices = try h.all(LocalBed.self).map { GardenSession.BedChoice($0) }
        #expect(session.plan(seedID: "seed_basil", isActive: true, beds: choices) == .planned(bedID: "north"))

        // The Garden screen takes it (the snapshot's grid beds are the live beds with a grid).
        let plan = try #require(GardenPlanHandoff.take(from: session, gridBedIDs: try h.snapshot().gridBedIDs))
        #expect(plan.bedID == "north")

        let outcome = GardenBedSupport.handle(
            .activate(GridSquare(column: 1, rowFromTop: 0)),
            session: session, data: try h.data(bedID: "north"), planDate: Self.day,
            actions: h.actions(bedID: "north"), onError: { Issue.record($0) }
        )
        #expect(outcome == GardenBedSupport.Outcome())
        let created = try #require(try h.all(LocalPlantingEvent.self).first)
        #expect(created.bedID == "north")
        #expect(created.seedID == "seed_basil")
        #expect(created.plannedFor == "2026-05-10")
        #expect(created.xFeet == 1.5)
        #expect(created.yFeet == 7.5)
        // The brush stays for the next square.
        #expect(session.isPainting)
        #expect(session.brushSeedID == "seed_basil")
    }

    @Test func aPlanWithOnlyAGridlessBedNeedsABedThenResumesAfterNewBed() throws {
        let h = Harness()
        try h.insert([Self.bed("pots", width: nil, length: nil), Self.seed()])
        let session = GardenSession()
        session.reconcile(try h.snapshot())
        let choices = try h.all(LocalBed.self).map { GardenSession.BedChoice($0) }
        #expect(session.plan(seedID: "seed_basil", isActive: true, beds: choices) == .needsBed)
        #expect(GardenPlanHandoff.take(from: session, gridBedIDs: try h.snapshot().gridBedIDs) == nil)

        var form = BedForm.new()
        form.name = "North"
        let created = try BedFormWriter.create(form, sync: h.engine, householdID: Self.household)
        #expect(GardenPlanHandoff.resume(session: session, created: created, beds: choices) == .planned(bedID: created?.id ?? ""))
        session.reconcile(try h.snapshot())
        let plan = try #require(GardenPlanHandoff.take(from: session, gridBedIDs: try h.snapshot().gridBedIDs))
        #expect(plan.bedID == created?.id)
        #expect(plan.seedID == "seed_basil")
    }

    // MARK: - Reconcile

    @Test func aHouseholdChangeResetsTheSession() throws {
        let h = Harness()
        try h.insert([Self.bed("north", width: 4, length: 8), Self.seed(), Self.event("e1", bed: "north", x: 0.5, y: 0.5)])
        let session = GardenSession()
        session.reconcile(try h.snapshot())
        session.showBed("north")
        session.startPainting(seedID: "seed_basil")
        session.select(eventID: "e1", presentDetails: true)

        session.reconcile(try h.snapshot(householdID: "hh_other"))
        #expect(session.bedID == nil)
        #expect(session.brushSeedID == nil)
        #expect(session.selectedEventID == nil)
        #expect(!session.detailsPresented)
        #expect(session.mode == .idle)
    }

    @Test func aRemoteDeletionOfTheSelectedPlantingClosesDetails() throws {
        let h = Harness()
        try h.insert([Self.bed("north", width: 4, length: 8), Self.seed(), Self.event("e1", bed: "north", x: 0.5, y: 0.5)])
        let session = GardenSession()
        session.reconcile(try h.snapshot())
        session.showBed("north")
        session.select(eventID: "e1", presentDetails: true)

        // Another device's delete lands as a local tombstone.
        try h.engine.enqueueDeletePlantingEvent(id: "e1")
        session.reconcile(try h.snapshot())
        #expect(session.selectedEventID == nil)
        #expect(!session.detailsPresented)
        #expect(session.bedID == "north")
    }
}
