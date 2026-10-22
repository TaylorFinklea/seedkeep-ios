import Foundation
import SwiftData
import Testing
@testable import Seedkeep

/// N3 store compatibility: the rows a pre-N3 build (base `c632a33`, before the server client and
/// server sync were deleted) wrote to disk. `PreN3StoreFixtureGenerator` wrote them to the bundled
/// `Fixtures/pre-n3-seedkeep.sqlite`; `PreN3StoreCompatibilityTests` opens a copy with the current
/// code and checks every value below.
///
/// Only `@Model` initializers are used here, so this file compiles before and after N3.
enum PreN3StoreFixture {
    static let resourceName = "pre-n3-seedkeep"
    static let resourceExtension = "sqlite"

    static let householdID = "hh_fixture"
    static let scopeID = "owner|seedkeep-hh_fixture"

    static let growingInfo = GrowingInfoSnapshot(
        scientific_name: "Solanum lycopersicum",
        life_cycle: "annual",
        sun_requirement: "full",
        frost_tolerance: "tender",
        sow_method: "transplant",
        seed_depth_inches: 0.25,
        days_to_germinate_min: 5,
        days_to_germinate_max: 10,
        days_to_maturity_min: 75,
        days_to_maturity_max: 85,
        soil_temp_min_f: 60,
        soil_temp_max_f: 85,
        plant_spacing_inches: 24,
        row_spacing_inches: 36,
        hardiness_zone_min: 3,
        hardiness_zone_max: 11,
        viability_years: 4,
        instructions: "Start indoors 6-8 weeks before last frost."
    )

    /// Payloads in the shape the pre-N3 `SyncEngine.enqueue*` wrote (a create carries the
    /// client-supplied id; an update keeps an explicit `null` as the clear marker).
    static let seedCreatePayload =
        #"{"id":"seed_local_pending","state":"active","packet_count":1,"source":"store","custom_name":"Pending seed","tag_ids":[]}"#
    static let seedUpdatePayload = #"{"notes":"Water daily","location_id":null}"#
    static let deadLetterPayload =
        #"{"id":"pe_dead","seed_id":"seed_missing","kind":"sowing","planned_for":"2026-05-01"}"#

    /// Inserts every fixture row into `context` and saves.
    @MainActor
    static func insertRows(into context: ModelContext) throws {
        let h = householdID
        context.insert(LocalLocation(id: "loc_1", householdID: h, name: "Shed", sortOrder: 1,
                                     createdAt: 1_000, updatedAt: 1_100))
        context.insert(LocalTag(id: "tag_1", householdID: h, name: "Heirloom", color: "#aa0000",
                                createdAt: 1_000, updatedAt: 1_200))
        context.insert(LocalSeed(
            id: "seed_1", householdID: h, catalogID: "cat_1", state: .active, packetCount: 2,
            locationID: "loc_1", yearPacked: 2025, source: .store, customName: "Cherokee Purple",
            customVariety: "Heirloom", customCompany: "Baker Creek", customType: "Tomato",
            notes: "Saved from 2024", tagIDs: ["tag_1"], growingInfo: growingInfo,
            createdAt: 2_000, updatedAt: 2_500
        ))
        context.insert(LocalSeed(
            id: "seed_2", householdID: h, state: .wishlist, packetCount: 0, source: .gift,
            customName: "Deleted bean", createdAt: 2_000, updatedAt: 2_600, deletedAt: 2_600
        ))
        context.insert(LocalSeed(
            id: "seed_local_pending", householdID: h, state: .active, packetCount: 1,
            source: .store, customName: "Pending seed", createdAt: 2_700, updatedAt: 2_700
        ))
        context.insert(LocalSeedPhoto(id: "photo_legacy", seedID: "seed_1", householdID: h,
                                      r2Key: "photos/hh_fixture/legacy.jpg", role: .front,
                                      width: 1_200, height: 1_600, byteSize: 240_000, capturedAt: 2_100))
        context.insert(LocalSeedPhoto(id: "seed_photo_local_ck", seedID: "seed_1", householdID: h,
                                      r2Key: nil, role: .back, byteSize: 180_000, capturedAt: 2_200))
        context.insert(LocalBed(id: "bed_1", householdID: h, name: "North bed",
                                bedDescription: "Raised cedar", widthFeet: 4, lengthFeet: 8, sortOrder: 0,
                                createdAt: 3_000, updatedAt: 3_100))
        context.insert(LocalBed(id: "bed_2", householdID: h, name: "Gone bed", widthFeet: 2.5,
                                lengthFeet: 3, sortOrder: 1, createdAt: 3_000, updatedAt: 3_200,
                                deletedAt: 3_200))
        context.insert(LocalPlantingEvent(
            id: "pe_1", householdID: h, bedID: "bed_1", seedID: "seed_1", catalogSeedID: "cat_1",
            kindRaw: "sowing", plannedFor: "2026-04-01", notes: "Two per cell", xFeet: 1.5, yFeet: 2,
            createdAt: 4_000, updatedAt: 4_100
        ))
        context.insert(LocalPlantingEvent(
            id: "pe_2", householdID: h, bedID: "bed_1", seedID: "seed_1", kindRaw: "harvest",
            plannedFor: "2026-07-20", completedAt: 4_900, createdAt: 4_000, updatedAt: 4_900,
            petSeed: String(repeating: "a", count: 64), petRarity: "rare", petCreatureKind: "garden_worm",
            petName: "Wriggles", petSpawnedAt: 4_000, petWiltedStreakDays: 2, petLastMoodTickAt: 4_800
        ))
        context.insert(LocalPetDeparture(plantingEventID: "pe_2",
                                         goodbyeNoteJSON: #"{"note_text":"Farewell","signoff":"W"}"#,
                                         reason: "wilted_too_long", createdAt: 4_950, updatedAt: 4_950,
                                         departedAt: 4_950))
        context.insert(LocalJournalEntry(id: "je_1", householdID: h, occurredOn: "2025-07-15",
                                         body: "First fruit", seedID: "seed_1", bedID: nil,
                                         plantingEventID: nil, createdAt: 5_000, updatedAt: 5_100,
                                         deletedAt: nil))
        context.insert(LocalJournalEntry(id: "je_2", householdID: h, occurredOn: "2025-08-01",
                                         body: "Mulched", seedID: nil, bedID: "bed_1",
                                         plantingEventID: nil, createdAt: 5_200, updatedAt: 5_200,
                                         deletedAt: nil))
        context.insert(LocalJournalEntry(id: "je_3", householdID: h, occurredOn: "2025-08-02",
                                         body: "Deleted note", seedID: nil, bedID: nil,
                                         plantingEventID: "pe_1", createdAt: 5_300, updatedAt: 5_400,
                                         deletedAt: 5_400))
        context.insert(LocalJournalEntryPhoto(id: "jp_legacy", entryID: "je_1",
                                              storageKey: "journal/hh_fixture/je_1/0.jpg", sortOrder: 0,
                                              width: 800, height: 600, createdAt: 5_010, updatedAt: 5_010))
        context.insert(LocalJournalEntryPhoto(id: "journal_photo_local_ck", entryID: "je_1",
                                              storageKey: nil, sortOrder: 1, width: nil, height: nil,
                                              createdAt: 5_020, updatedAt: 5_020))
        context.insert(LocalJournalChecklistItem(id: "jc_1", entryID: "je_1", text: "Stake plants",
                                                 completed: true, sortOrder: 0, updatedAt: 5_030))
        context.insert(LocalPendingWrite(id: "pw_seed_create", entityType: "seed",
                                         entityID: "seed_local_pending", operation: "create",
                                         payloadJSON: seedCreatePayload, createdAt: 6_000))
        context.insert(LocalPendingWrite(id: "pw_seed_update", entityType: "seed", entityID: "seed_1",
                                         operation: "update", payloadJSON: seedUpdatePayload,
                                         createdAt: 6_100, attemptCount: 2, lastError: "internal_error: boom",
                                         nextAttemptAt: 9_000))
        context.insert(LocalPendingWrite(id: "pw_bed_delete", entityType: "bed", entityID: "bed_2",
                                         operation: "delete", payloadJSON: "{}", createdAt: 6_200))
        context.insert(LocalPendingWrite(id: "pw_dead", entityType: "planting_event", entityID: "pe_dead",
                                         operation: "create", payloadJSON: deadLetterPayload,
                                         createdAt: 6_300, attemptCount: 6,
                                         lastError: "validation_failed: unknown seed", nextAttemptAt: 6_400,
                                         isDeadLettered: true))
        context.insert(LocalCloudKitDeletion(scopeID: scopeID, householdID: h,
                                             recordName: "SeedPhoto_seed_photo_deleted", createdAt: 7_000))
        context.insert(LocalCloudKitDeletion(scopeID: scopeID, householdID: h,
                                             recordName: "JournalChecklistItem_jc_deleted", createdAt: 7_100))
        context.insert(LocalSyncCursor(householdID: h, kind: "seeds", cursor: 2_600,
                                       cursorID: "seed_2", lastSyncedAt: 8_000))
        // Models whose feeding code N3 removed (or that only the device writes), one row each, so a
        // later removal of an unused model has a store to upgrade from.
        context.insert(LocalAssistantThread(id: "thread_1", householdID: h, title: "Tomato help",
                                            threadKind: "chat", createdAt: 9_000, updatedAt: 9_100, deletedAt: nil))
        context.insert(LocalAssistantMessage(id: "msg_1", threadID: "thread_1", role: "assistant",
                                             contentJSON: #"[{"type":"text","text":"Water deeply."}]"#,
                                             pageContext: #"{"pageType":"seed","entityId":"seed_1"}"#,
                                             model: "claude-test", usageJSON: #"{"input_tokens":12}"#,
                                             createdAt: 9_050))
        context.insert(LocalAssistantToolCall(id: "tool_1", messageID: "msg_1", threadID: "thread_1",
                                              toolName: "update_seed", argsJSON: #"{"notes":"x"}"#,
                                              status: "done", resultJSON: #"{"ok":true}"#,
                                              proposedChangeJSON: nil, confirmedAt: 9_060,
                                              createdAt: 9_055, updatedAt: 9_060))
        context.insert(LocalAssistantKeyStatus(id: "household_hh_fixture_anthropic", provider: "anthropic",
                                               configured: true, updatedAt: 9_070))
        context.insert(LocalCatalogCorrection(id: "corr_1", catalogSeedID: "cat_1",
                                              catalogSeedName: "Cherokee Purple", fieldName: "days_to_maturity_min",
                                              valueType: "int", suggestedValue: "80", clientSeenValue: "75",
                                              body: "Packet says 80", status: "applied", aiReviewScore: 0.9,
                                              aiNotes: "Matches packet", userAcknowledgedBounds: true,
                                              createdAt: 9_200, reviewedAt: 9_250, appliedAt: 9_300,
                                              updatedAt: 9_300, appliedFieldName: "days_to_maturity_min",
                                              appliedNewValue: "80"))
        context.insert(LocalRecommendation(catalogSeedID: "cat_1", locationSignature: "zip:64111",
                                           computedAt: 9_400, source: "rule", confidence: 0.8, verdict: "plant_now",
                                           rangeStart: "2026-04-01", rangeEnd: "2026-05-15", indoorStart: "2026-02-15",
                                           indoorEnd: "2026-03-15", scoresAnchorDate: "2026-04-01",
                                           dailyScoresJSON: "[0.5,0.75,1.0]", reasoning: "After last frost",
                                           fetchedAt: 9_450))
        context.insert(LocalPetMoodSnapshot(plantingEventID: "pe_2", dayYMD: "2026-07-19", moodLabel: "wilted",
                                            compositeScore: 30, createdAt: 9_500))
        context.insert(LocalJournalRecoveryItem(id: "recovery_1", scopeKey: "hh_owner|hh_fixture",
                                                snapshotJSON: #"{"id":"je_stranded","body":"Stranded"}"#,
                                                detectedAt: 9_600, status: "pending"))
        context.insert(LocalForecastSnapshot(id: "current", forecastJSON: #"{"days":[]}"#,
                                             observedJSON: #"{"highs":[]}"#,
                                             lastWaterFireDate: Date(timeIntervalSince1970: 1_780_000_000),
                                             lastHeatDomeFireDate: nil,
                                             lastHeatEventDate: Date(timeIntervalSince1970: 1_779_000_000),
                                             lastAuthStatusRaw: 2, sawTimeZoneIdentifier: "America/Chicago",
                                             sawClockAt: Date(timeIntervalSince1970: 1_781_000_000),
                                             coordGeneration: 3, outcomeRaw: "successNoWarnings"))
        try context.save()
    }
}

/// Writes the pre-N3 fixture store. Not part of the gate: it runs only when the test runner gets
/// `SEEDKEEP_GENERATE_PRE_N3_FIXTURE=<output directory>` (pass `TEST_RUNNER_SEEDKEEP_GENERATE_PRE_N3_FIXTURE`
/// to `xcodebuild test`). Fold the WAL into the main file afterwards
/// (`sqlite3 <store> 'PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;'`) and copy the
/// single file to `SeedkeepTests/Fixtures/pre-n3-seedkeep.sqlite`.
@Suite("Pre-N3 store fixture generator")
struct PreN3StoreFixtureGenerator {
    static let outputDirectory = ProcessInfo.processInfo.environment["SEEDKEEP_GENERATE_PRE_N3_FIXTURE"]

    @MainActor
    @Test("writes the pre-N3 fixture store", .enabled(if: outputDirectory != nil))
    func generate() throws {
        let directory = URL(fileURLWithPath: try #require(Self.outputDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(PreN3StoreFixture.resourceName).\(PreN3StoreFixture.resourceExtension)")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        try PreN3StoreFixture.insertRows(into: ModelContext(container))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
