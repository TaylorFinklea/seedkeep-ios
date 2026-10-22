import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

/// N3 store compatibility: a disk-backed store written by pre-N3 code (base `c632a33`, see
/// `PreN3StoreFixture`) opens with the current code, reads back intact, and takes local writes.
/// Its `LocalPendingWrite` rows and CloudKit deletion intents are left exactly as they were.
@MainActor
@Suite("Pre-N3 store compatibility", .serialized)
struct PreN3StoreCompatibilityTests {
    private final class BundleToken {}

    /// A copy of the bundled fixture in a fresh temporary directory, so the bundle copy never changes.
    private static func copyFixture() throws -> (directory: URL, store: URL) {
        let source = try #require(Bundle(for: BundleToken.self).url(
            forResource: PreN3StoreFixture.resourceName, withExtension: PreN3StoreFixture.resourceExtension))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-n3-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("seedkeep.store")
        try FileManager.default.copyItem(at: source, to: store)
        return (directory, store)
    }

    private static func open(_ url: URL) throws -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func expectedContainer() throws -> ModelContainer {
        let container = makeTestContainer(name: "preN3Expected-\(UUID().uuidString)")
        try PreN3StoreFixture.insertRows(into: ModelContext(container))
        return container
    }

    // MARK: - Row snapshots (every stored field)

    private static func rows(_ container: ModelContainer) throws -> [String: [String]] {
        let c = ModelContext(container)
        func s(_ value: Any?) -> String { value.map { "\($0)" } ?? "nil" }
        return [
            "location": try c.fetch(FetchDescriptor<LocalLocation>()).map {
                [ $0.id, $0.householdID, $0.name, s($0.sortOrder), s($0.createdAt), s($0.updatedAt), s($0.deletedAt) ]
                    .joined(separator: "|") }.sorted(),
            "tag": try c.fetch(FetchDescriptor<LocalTag>()).map {
                [ $0.id, $0.householdID, $0.name, s($0.color), s($0.createdAt), s($0.updatedAt), s($0.deletedAt) ]
                    .joined(separator: "|") }.sorted(),
            "seed": try c.fetch(FetchDescriptor<LocalSeed>()).map {
                [ $0.id, $0.householdID, s($0.catalogID), $0.stateRaw, s($0.packetCount), s($0.locationID),
                  s($0.yearPacked), $0.sourceRaw, s($0.customName), s($0.customVariety), s($0.customCompany),
                  s($0.customType), s($0.notes), $0.tagIDs.joined(separator: ","), s($0.growingInfo),
                  s($0.createdAt), s($0.updatedAt), s($0.deletedAt) ].joined(separator: "|") }.sorted(),
            "seedPhoto": try c.fetch(FetchDescriptor<LocalSeedPhoto>()).map {
                [ $0.id, $0.seedID, $0.householdID, s($0.r2Key), $0.roleRaw, s($0.width), s($0.height),
                  s($0.byteSize), s($0.capturedAt) ].joined(separator: "|") }.sorted(),
            "bed": try c.fetch(FetchDescriptor<LocalBed>()).map {
                [ $0.id, $0.householdID, $0.name, s($0.bedDescription), s($0.widthFeet), s($0.lengthFeet),
                  s($0.sortOrder), s($0.createdAt), s($0.updatedAt), s($0.deletedAt) ].joined(separator: "|") }.sorted(),
            "planting": try c.fetch(FetchDescriptor<LocalPlantingEvent>()).map {
                [ $0.id, $0.householdID, s($0.bedID), s($0.seedID), s($0.catalogSeedID), $0.kindRaw, $0.plannedFor,
                  s($0.completedAt), s($0.notes), s($0.xFeet), s($0.yFeet), s($0.createdAt), s($0.updatedAt),
                  s($0.deletedAt), s($0.petSeed), s($0.petRarity), s($0.petCreatureKind), s($0.petName),
                  s($0.petPersonalityJSON), s($0.petSpawnedAt), s($0.petWiltedStreakDays), s($0.petLastMoodTickAt) ]
                    .joined(separator: "|") }.sorted(),
            "petDeparture": try c.fetch(FetchDescriptor<LocalPetDeparture>()).map {
                [ $0.plantingEventID, s($0.goodbyeNoteJSON), $0.reason, s($0.fallback), s($0.createdAt),
                  s($0.updatedAt), s($0.departedAt), s($0.deletedAt) ].joined(separator: "|") }.sorted(),
            "journalEntry": try c.fetch(FetchDescriptor<LocalJournalEntry>()).map {
                [ $0.id, $0.householdID, $0.occurredOn, $0.body, s($0.seedID), s($0.bedID), s($0.plantingEventID),
                  s($0.createdAt), s($0.updatedAt), s($0.deletedAt) ].joined(separator: "|") }.sorted(),
            "journalPhoto": try c.fetch(FetchDescriptor<LocalJournalEntryPhoto>()).map {
                [ $0.id, $0.entryID, s($0.storageKey), s($0.sortOrder), s($0.width), s($0.height),
                  s($0.createdAt), s($0.updatedAt) ].joined(separator: "|") }.sorted(),
            "checklist": try c.fetch(FetchDescriptor<LocalJournalChecklistItem>()).map {
                [ $0.id, $0.entryID, $0.text, s($0.completed), s($0.sortOrder), s($0.updatedAt) ]
                    .joined(separator: "|") }.sorted(),
            "pendingWrite": try pendingWrites(c),
            "cloudKitDeletion": try cloudKitDeletions(c),
            "syncCursor": try c.fetch(FetchDescriptor<LocalSyncCursor>()).map {
                [ $0.id, $0.householdID, $0.kind, s($0.cursor), s($0.cursorID), s($0.lastSyncedAt) ]
                    .joined(separator: "|") }.sorted(),
            "assistantThread": try c.fetch(FetchDescriptor<LocalAssistantThread>()).map {
                [ $0.id, $0.householdID, $0.title, $0.threadKind, s($0.createdAt), s($0.updatedAt), s($0.deletedAt) ]
                    .joined(separator: "|") }.sorted(),
            "assistantMessage": try c.fetch(FetchDescriptor<LocalAssistantMessage>()).map {
                [ $0.id, $0.threadID, $0.role, $0.contentJSON, s($0.pageContext), s($0.model), s($0.usageJSON),
                  s($0.createdAt) ].joined(separator: "|") }.sorted(),
            "assistantToolCall": try c.fetch(FetchDescriptor<LocalAssistantToolCall>()).map {
                [ $0.id, $0.messageID, $0.threadID, $0.toolName, $0.argsJSON, $0.status, s($0.resultJSON),
                  s($0.proposedChangeJSON), s($0.confirmedAt), s($0.createdAt), s($0.updatedAt) ]
                    .joined(separator: "|") }.sorted(),
            "assistantKeyStatus": try c.fetch(FetchDescriptor<LocalAssistantKeyStatus>()).map {
                [ $0.id, $0.provider, s($0.configured), s($0.updatedAt) ].joined(separator: "|") }.sorted(),
            "catalogCorrection": try c.fetch(FetchDescriptor<LocalCatalogCorrection>()).map {
                [ $0.id, s($0.catalogSeedID), s($0.catalogSeedName), s($0.fieldName), s($0.valueType),
                  s($0.suggestedValue), s($0.clientSeenValue), s($0.body), $0.status, s($0.aiReviewScore),
                  s($0.aiNotes), s($0.dismissedReason), s($0.conflictWithID), s($0.userAcknowledgedBounds),
                  s($0.createdAt), s($0.reviewedAt), s($0.appliedAt), s($0.escalatedAt), s($0.updatedAt),
                  s($0.deletedAt), s($0.appliedFieldName), s($0.appliedNewValue) ].joined(separator: "|") }.sorted(),
            "recommendation": try c.fetch(FetchDescriptor<LocalRecommendation>()).map {
                [ $0.catalogSeedID, $0.locationSignature, s($0.computedAt), $0.source, s($0.confidence), $0.verdict,
                  s($0.rangeStart), s($0.rangeEnd), s($0.indoorStart), s($0.indoorEnd), $0.scoresAnchorDate,
                  $0.dailyScoresJSON, s($0.reasoning), s($0.fetchedAt) ].joined(separator: "|") }.sorted(),
            "petMoodSnapshot": try c.fetch(FetchDescriptor<LocalPetMoodSnapshot>()).map {
                [ $0.id, $0.plantingEventID, $0.dayYMD, $0.moodLabel, s($0.compositeScore), s($0.createdAt) ]
                    .joined(separator: "|") }.sorted(),
            "journalRecoveryItem": try c.fetch(FetchDescriptor<LocalJournalRecoveryItem>()).map {
                [ $0.id, $0.scopeKey, $0.snapshotJSON, s($0.detectedAt), $0.status ].joined(separator: "|") }.sorted(),
            "forecastSnapshot": try c.fetch(FetchDescriptor<LocalForecastSnapshot>()).map {
                [ $0.id, $0.forecastJSON, $0.observedJSON, s($0.lastWaterFireDate), s($0.lastHeatDomeFireDate),
                  s($0.lastHeatEventDate), s($0.lastAuthStatusRaw), s($0.sawTimeZoneIdentifier), s($0.sawClockAt),
                  s($0.coordGeneration), s($0.outcomeRaw) ].joined(separator: "|") }.sorted(),
        ]
    }

    private static func pendingWrites(_ c: ModelContext) throws -> [String] {
        try c.fetch(FetchDescriptor<LocalPendingWrite>()).map {
            [ $0.id, $0.entityType, $0.entityID, $0.operation, $0.payloadJSON, "\($0.createdAt)",
              "\($0.attemptCount)", $0.lastError ?? "nil", "\($0.nextAttemptAt)", "\($0.isDeadLettered)" ]
                .joined(separator: "|") }.sorted()
    }

    private static func cloudKitDeletions(_ c: ModelContext) throws -> [String] {
        try c.fetch(FetchDescriptor<LocalCloudKitDeletion>()).map {
            [ $0.id, $0.scopeID, $0.householdID, $0.recordName, "\($0.createdAt)" ].joined(separator: "|")
        }.sorted()
    }

    // MARK: - Tests

    @Test("the pre-N3 store opens and every row reads back intact")
    func preN3StoreReadsBackIntact() throws {
        let (directory, url) = try Self.copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try Self.open(url)

        let actual = try Self.rows(container)
        let expected = try Self.rows(try Self.expectedContainer())
        #expect(actual.keys.sorted() == expected.keys.sorted())
        for (model, rows) in expected {
            #expect(!rows.isEmpty, "the fixture has \(model) rows")
            #expect(actual[model] == rows, "\(model) rows changed")
        }
        #expect(actual.count == SeedkeepSchema.all.count, "every @Model has fixture rows")
        #expect(actual["pendingWrite"]?.count == 4)
        #expect(actual["cloudKitDeletion"]?.count == 2)

        // Relationships are stored as IDs; each one resolves.
        let c = ModelContext(container)
        let seeds = Dictionary(uniqueKeysWithValues: try c.fetch(FetchDescriptor<LocalSeed>()).map { ($0.id, $0) })
        let beds = Set(try c.fetch(FetchDescriptor<LocalBed>()).map(\.id))
        let plantings = Set(try c.fetch(FetchDescriptor<LocalPlantingEvent>()).map(\.id))
        let entries = Set(try c.fetch(FetchDescriptor<LocalJournalEntry>()).map(\.id))
        let locations = Set(try c.fetch(FetchDescriptor<LocalLocation>()).map(\.id))
        let tags = Set(try c.fetch(FetchDescriptor<LocalTag>()).map(\.id))
        let seed = try #require(seeds["seed_1"])
        #expect(seed.locationID.map(locations.contains) == true)
        #expect(!seed.tagIDs.isEmpty && seed.tagIDs.allSatisfy(tags.contains))
        #expect(seed.growingInfo == PreN3StoreFixture.growingInfo)
        for photo in try c.fetch(FetchDescriptor<LocalSeedPhoto>()) {
            #expect(seeds[photo.seedID] != nil)
        }
        for event in try c.fetch(FetchDescriptor<LocalPlantingEvent>()) {
            #expect(event.bedID.map(beds.contains) ?? true)
            #expect(event.seedID.map { seeds[$0] != nil } ?? true)
        }
        #expect(try c.fetch(FetchDescriptor<LocalPetDeparture>()).allSatisfy { plantings.contains($0.plantingEventID) })
        for entry in try c.fetch(FetchDescriptor<LocalJournalEntry>()) {
            #expect(entry.seedID.map { seeds[$0] != nil } ?? true)
            #expect(entry.bedID.map(beds.contains) ?? true)
            #expect(entry.plantingEventID.map(plantings.contains) ?? true)
        }
        let journalPhotos = try c.fetch(FetchDescriptor<LocalJournalEntryPhoto>())
        #expect(journalPhotos.allSatisfy { entries.contains($0.entryID) })
        #expect(try c.fetch(FetchDescriptor<LocalJournalChecklistItem>()).allSatisfy { entries.contains($0.entryID) })
        // Photo references: legacy server keys stay, CloudKit-born photos have none.
        #expect(journalPhotos.first { $0.id == "jp_legacy" }?.storageKey == "journal/hh_fixture/je_1/0.jpg")
        #expect(journalPhotos.first { $0.id == "journal_photo_local_ck" }?.storageKey == nil)
        let seedPhotos = try c.fetch(FetchDescriptor<LocalSeedPhoto>())
        #expect(seedPhotos.first { $0.id == "photo_legacy" }?.r2Key == "photos/hh_fixture/legacy.jpg")
        #expect(seedPhotos.first { $0.id == "seed_photo_local_ck" }?.r2Key == nil)
    }

    @Test("enqueue create, update and delete work on the pre-N3 store and leave its queue and tombstones alone")
    func enqueueOnPreN3Store() throws {
        let (directory, url) = try Self.copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let h = PreN3StoreFixture.householdID

        do {
            let container = try Self.open(url)
            let before = ModelContext(container)
            let pendingBefore = try Self.pendingWrites(before)
            let deletionsBefore = try Self.cloudKitDeletions(before)
            let engine = SyncEngine(container: container)
            var signals = 0
            engine.onLocalHouseholdMutation = { signals += 1 }

            // Creates.
            let location = try engine.enqueueCreateLocation(name: "Basement", sortOrder: 2, householdID: h)
            let tag = try engine.enqueueCreateTag(name: "Early", color: "#00aa00", householdID: h)
            let seed = try engine.enqueueCreateSeed(
                .init(state: .active, packet_count: 3, location_id: location.id, source: .swap,
                      custom_name: "Sungold", tag_ids: [tag.id]),
                householdID: h)
            let bed = try engine.enqueueCreateBed(.init(name: "South bed", width_feet: 3, length_feet: 6), householdID: h)
            let planting = try engine.enqueueCreatePlantingEvent(
                .init(bed_id: bed.id, seed_id: seed.id, kind: .sowing, planned_for: "2026-05-15", x_feet: 0.5, y_feet: 0.5),
                householdID: h)
            // Updates to pre-N3 rows, including explicit clears.
            try engine.enqueueUpdateLocation(id: "loc_1", name: "Garden shed", sortOrder: nil)
            try engine.enqueueUpdateTag(id: "tag_1", name: nil, color: .some(nil))
            try engine.enqueueUpdateSeed(id: "seed_1", .init(location_id: .some(nil), notes: "Saved from 2025"))
            try engine.enqueueUpdateBed(id: "bed_1", .init(name: "North raised bed"))
            try engine.enqueueUpdatePlantingEvent(id: "pe_1", .init(completed_at: .some(1_000_000)))
            // Deletes of pre-N3 rows, one with a pre-N3 pending create of its own.
            try engine.enqueueDeleteSeed(id: "seed_local_pending")
            try engine.enqueueDeleteBed(id: "bed_1")
            try engine.enqueueDeletePlantingEvent(id: "pe_1")
            try engine.enqueueDeleteLocation(id: "loc_1")
            try engine.enqueueDeleteTag(id: "tag_1")

            #expect(signals == 15, "each write signals the CloudKit save exactly once")
            let after = ModelContext(container)
            #expect(try Self.pendingWrites(after) == pendingBefore, "no LocalPendingWrite is created or changed")
            #expect(try Self.cloudKitDeletions(after) == deletionsBefore, "CloudKit deletion intents are untouched")
            #expect(planting.bedID == bed.id && planting.seedID == seed.id)
        }

        // The writes are on disk: reopen the store.
        let reopened = try Self.open(url)
        let c = ModelContext(reopened)
        func one<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>) throws -> T {
            try #require(try c.fetch(FetchDescriptor<T>(predicate: predicate)).first)
        }
        let sungold = try one(LocalSeed.self, #Predicate { $0.customName == "Sungold" })
        #expect(sungold.householdID == h && sungold.packetCount == 3 && sungold.source == .swap)
        let basement = try one(LocalLocation.self, #Predicate { $0.name == "Basement" })
        #expect(sungold.locationID == basement.id)
        let early = try one(LocalTag.self, #Predicate { $0.name == "Early" })
        #expect(sungold.tagIDs == [early.id] && early.color == "#00aa00")
        let southBed = try one(LocalBed.self, #Predicate { $0.name == "South bed" })
        #expect(southBed.widthFeet == 3 && southBed.lengthFeet == 6 && southBed.deletedAt == nil)
        let bedID = southBed.id
        let newPlanting = try one(LocalPlantingEvent.self, #Predicate { $0.bedID == bedID })
        #expect(newPlanting.seedID == sungold.id && newPlanting.plannedFor == "2026-05-15")

        let seed1 = try one(LocalSeed.self, #Predicate { $0.id == "seed_1" })
        #expect(seed1.locationID == nil, "an explicit clear nulls the stored value")
        #expect(seed1.notes == "Saved from 2025")
        #expect(seed1.customName == "Cherokee Purple" && seed1.tagIDs == ["tag_1"], "omitted fields are untouched")
        #expect(seed1.growingInfo == PreN3StoreFixture.growingInfo)
        #expect(seed1.updatedAt > 2_500)
        let tag1 = try one(LocalTag.self, #Predicate { $0.id == "tag_1" })
        #expect(tag1.color == nil && tag1.name == "Heirloom" && tag1.deletedAt != nil)
        let loc1 = try one(LocalLocation.self, #Predicate { $0.id == "loc_1" })
        #expect(loc1.name == "Garden shed" && loc1.deletedAt != nil)
        let bed1 = try one(LocalBed.self, #Predicate { $0.id == "bed_1" })
        #expect(bed1.name == "North raised bed" && bed1.deletedAt != nil)
        let pe1 = try one(LocalPlantingEvent.self, #Predicate { $0.id == "pe_1" })
        #expect(pe1.completedAt == 1_000_000 && pe1.deletedAt != nil)
        #expect(try one(LocalSeed.self, #Predicate { $0.id == "seed_local_pending" }).deletedAt != nil)

        // Rows nothing wrote to are unchanged, and so are the queue and the tombstones.
        let expected = try Self.rows(try Self.expectedContainer())
        let actual = try Self.rows(reopened)
        for model in ["seedPhoto", "petDeparture", "journalEntry", "journalPhoto", "checklist",
                      "pendingWrite", "cloudKitDeletion", "syncCursor", "assistantThread", "assistantMessage",
                      "assistantToolCall", "assistantKeyStatus", "catalogCorrection", "recommendation", "petMoodSnapshot",
                      "journalRecoveryItem", "forecastSnapshot"] {
            #expect(actual[model] == expected[model], "\(model) rows changed")
        }
    }
}
