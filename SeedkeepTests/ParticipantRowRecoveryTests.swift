import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

// R1 27d.18 — participant stranded-row recovery. Covers the ten non-negotiable invariants from
// `.docs/ai/phases/2026-07-16-r1-27d18-participant-row-recovery-spec.md`. Tests 1 and 2 are the
// two spec-marked repro tests: they must FAIL if the migration hookup is stashed/guarded out
// (verified empirically during implementation, not re-checked by CI).
@MainActor
@Suite("Participant row recovery (27d.18)", .serialized)
struct ParticipantRowRecoveryTests {

    private func makeContainer() -> ModelContainer {
        makeTestContainer(name: "prr-\(UUID().uuidString)")
    }

    // MARK: - Invariant 1 (REPRO) — five queue-backed types re-home

    @Test("stranded five-type rows are excluded from owner-zone export before recovery, re-homed after")
    func strandedFiveTypesExcludedPreMigrationThenRehomed() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        setup.insert(LocalLocation(id: "loc1", householdID: signedIn, name: "Garage", sortOrder: 0, createdAt: 1, updatedAt: 2))
        setup.insert(LocalTag(id: "tag1", householdID: signedIn, name: "Heirloom", createdAt: 1, updatedAt: 2))
        setup.insert(LocalSeed(id: "seed1", householdID: signedIn, state: .active, packetCount: 3, source: .store, createdAt: 1, updatedAt: 2))
        setup.insert(LocalBed(id: "bed1", householdID: signedIn, name: "North", createdAt: 1, updatedAt: 2))
        setup.insert(LocalPlantingEvent(id: "pe1", householdID: signedIn, kindRaw: "sowing", plannedFor: "2026-07-01", createdAt: 1, updatedAt: 2))
        try setup.save()

        // BEFORE: none of these appear in the owner-zone export.
        let before = HouseholdMigrationPlanner.fetchInput(
            from: ModelContext(container), householdID: owner, householdName: "G", householdCreatedAt: 1, householdUpdatedAt: 1)
        #expect(before.locations.isEmpty)
        #expect(before.tags.isEmpty)
        #expect(before.seeds.isEmpty)
        #expect(before.beds.isEmpty)
        #expect(before.plantingEvents.isEmpty)

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        // AFTER: every stranded row now resolves into the owner-zone export.
        let after = HouseholdMigrationPlanner.fetchInput(
            from: ModelContext(container), householdID: owner, householdName: "G", householdCreatedAt: 1, householdUpdatedAt: 1)
        #expect(after.locations.map(\.id) == ["loc1"])
        #expect(after.tags.map(\.id) == ["tag1"])
        #expect(after.seeds.map(\.id) == ["seed1"])
        #expect(after.beds.map(\.id) == ["bed1"])
        #expect(after.plantingEvents.map(\.id) == ["pe1"])
        let plan = HouseholdMigrationPlanner.plan(after, completedAt: 1)
        #expect(plan.contains { $0.recordName == "seed:seed1" })
    }

    // MARK: - Invariant 2 (REPRO) — FK-evidenced journal entry + checklist re-home together

    @Test("FK-evidenced journal entry and its checklist items re-home together (post-step-1 union)")
    func fkEvidencedJournalEntryAndChecklistRehomeTogether() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        // A pre-existing owner-zone bed (simulates a row already in the adopted shared garden).
        setup.insert(LocalBed(id: "ownerBed", householdID: owner, name: "South", createdAt: 1, updatedAt: 2))
        // A stranded seed that ALSO re-homes THIS SAME call (the "after step 1" union case).
        setup.insert(LocalSeed(id: "strandedSeed", householdID: signedIn, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 2))
        // Entry A resolves via the just-rehomed seed; entry B resolves via the pre-existing owner bed.
        let entryA = LocalJournalEntry(
            id: "entryA", householdID: signedIn, occurredOn: "2026-06-01", body: "Sprouted",
            seedID: "strandedSeed", bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil)
        let entryB = LocalJournalEntry(
            id: "entryB", householdID: signedIn, occurredOn: "2026-06-02", body: "Weeded",
            seedID: nil, bedID: "ownerBed", plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil)
        setup.insert(entryA)
        setup.insert(entryB)
        setup.insert(LocalJournalChecklistItem(id: "ciA", entryID: "entryA", text: "Water", completed: false, sortOrder: 0, updatedAt: 2))
        try setup.save()

        // BEFORE: neither entry nor its checklist item appears in the owner-zone export.
        let before = HouseholdMigrationPlanner.fetchInput(
            from: ModelContext(container), householdID: owner, householdName: "G", householdCreatedAt: 1, householdUpdatedAt: 1)
        #expect(before.journalEntries.isEmpty)
        #expect(before.checklistItems.isEmpty)

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        // AFTER: both entries + the checklist item resolve into the owner-zone export.
        let after = HouseholdMigrationPlanner.fetchInput(
            from: ModelContext(container), householdID: owner, householdName: "G", householdCreatedAt: 1, householdUpdatedAt: 1)
        #expect(Set(after.journalEntries.map(\.id)) == Set(["entryA", "entryB"]))
        #expect(after.checklistItems.map(\.id) == ["ciA"], "the checklist item follows its re-homed parent by entryID membership, with no mutation of its own")
    }

    // MARK: - Invariant 3 — ambiguous journal entries quarantine with a faithful snapshot

    @Test("a journal entry with no FK is quarantined, not exported, with a faithful pending snapshot")
    func noFKEntryIsQuarantinedWithFaithfulSnapshot() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        let entry = LocalJournalEntry(
            id: "ambiguous1", householdID: signedIn, occurredOn: "2026-05-10", body: "Solo musings",
            seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 5, updatedAt: 6, deletedAt: nil)
        setup.insert(entry)
        setup.insert(LocalJournalChecklistItem(id: "ci-amb-1", entryID: "ambiguous1", text: "Feed", completed: true, sortOrder: 0, updatedAt: 6))
        setup.insert(LocalJournalChecklistItem(id: "ci-amb-2", entryID: "ambiguous1", text: "Prune", completed: false, sortOrder: 1, updatedAt: 6))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let after = HouseholdMigrationPlanner.fetchInput(
            from: ModelContext(container), householdID: owner, householdName: "G", householdCreatedAt: 1, householdUpdatedAt: 1)
        #expect(after.journalEntries.isEmpty, "an ambiguous entry must never appear in the owner-zone export")

        let stillParked = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "ambiguous1" })
        ).first)
        #expect(stillParked.householdID == signedIn, "an ambiguous entry's householdID must be left unchanged")

        let item = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "ambiguous1" })
        ).first)
        #expect(item.status == "pending")
        let scope = ParticipantRowRecovery.scopeKey(ownerZoneHouseholdID: owner, signedInHouseholdID: signedIn)
        #expect(item.scopeKey == scope)
        let snapshot = try #require(ParticipantRowRecovery.decodeSnapshot(item.snapshotJSON))
        #expect(snapshot.occurredOn == "2026-05-10")
        #expect(snapshot.body == "Solo musings")
        #expect(snapshot.checklistItems.map(\.text) == ["Feed", "Prune"])
        #expect(snapshot.checklistItems.map(\.completed) == [true, false])
    }

    @Test("a journal entry with a solo FK (doesn't resolve into the owner zone) is quarantined")
    func soloFKEntryIsQuarantined() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"
        let parkedSolo = "parked-solo-\(UUID().uuidString)"

        let setup = ModelContext(container)
        // A seed that exists only in the parked solo household — never resolves into the owner zone.
        setup.insert(LocalSeed(id: "soloSeed", householdID: parkedSolo, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 2))
        setup.insert(LocalJournalEntry(
            id: "soloFKEntry", householdID: signedIn, occurredOn: "2026-05-11", body: "Refresh-imported",
            seedID: "soloSeed", bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let after = HouseholdMigrationPlanner.fetchInput(
            from: ModelContext(container), householdID: owner, householdName: "G", householdCreatedAt: 1, householdUpdatedAt: 1)
        #expect(after.journalEntries.isEmpty, "a solo FK must not resolve into the owner-zone export")
        let item = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "soloFKEntry" })
        ).first)
        #expect(item.status == "pending")
    }

    // MARK: - Invariant 4 — owner mode is a no-op

    @Test("owner mode (no participant marker) performs zero writes")
    func ownerModeNoParticipantMarkerIsNoOp() throws {
        let container = makeContainer()
        let householdID = "hh-\(UUID().uuidString)"
        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: householdID, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 2))
        try setup.save()

        // Owner mode: signed-in == owner-zone (no participant marker present).
        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: householdID, ownerZoneHouseholdID: householdID)
        #expect(ran == false)

        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalJournalRecoveryItem>()).isEmpty)
        let seed = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "s1" })
        ).first)
        #expect(seed.householdID == householdID, "owner mode must not touch any row")
    }

    // MARK: - Invariant 7 — flag-OFF is byte-identical (same guard, framed for the OFF case)

    @Test("the same-ID guard a flag-OFF resolver value would produce is a safe no-op")
    func sameIDGuardIsNoOpForAFlagOffEquivalentValue() throws {
        // This does NOT exercise AppEnvironment or the flag-OFF call site — AppEnvironment is
        // un-instantiable in this suite, so there is no flag-OFF call-site coverage here despite this
        // test's proximity to "Invariant 7". It only proves `runIfNeeded`'s own same-ID guard is a
        // safe no-op for the SAME VALUE that `AppEnvironment.activeGardenHouseholdID` would produce
        // when the CloudKit flag is off (`ActiveGardenContext.householdID`'s `cloudKitSyncEnabled`
        // guard resolves it to the signed-in household ID in that case) — this test and
        // `ownerModeNoParticipantMarkerIsNoOp` exercise the identical code path for that reason. The
        // real flag gate is `AppEnvironment.swift:227-243`, unreachable from this harness.
        let container = makeContainer()
        let householdID = "hh-\(UUID().uuidString)"
        let setup = ModelContext(container)
        setup.insert(LocalLocation(id: "loc1", householdID: householdID, name: "Shed", sortOrder: 0, createdAt: 1, updatedAt: 2))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: householdID, ownerZoneHouseholdID: householdID)
        #expect(ran == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalJournalRecoveryItem>()).isEmpty)
    }

    // MARK: - Invariant 5 — marker idempotency + failure atomicity

    @Test("a second run after success performs zero writes")
    func secondRunAfterSuccessPerformsZeroWrites() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"
        let setup = ModelContext(container)
        setup.insert(LocalLocation(id: "loc1", householdID: signedIn, name: "Garage", sortOrder: 0, createdAt: 1, updatedAt: 2))
        try setup.save()

        let ran1 = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran1 == true)

        // A NEW stranded row appears after the first run — if the second run actually executed, it
        // would re-home this too. It must not, proving the marker skips the whole pass.
        let setup2 = ModelContext(container)
        setup2.insert(LocalLocation(id: "loc2", householdID: signedIn, name: "Barn", sortOrder: 1, createdAt: 1, updatedAt: 2))
        try setup2.save()

        let ran2 = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran2 == false, "the durable marker must skip a second run")

        let loc2 = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.id == "loc2" })
        ).first)
        #expect(loc2.householdID == signedIn, "a second (skipped) run must perform zero writes")
    }

    @Test("a failed save writes no marker and the rerun recovers")
    func failedSaveWritesNoMarkerAndRerunRecovers() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"
        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: signedIn, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 2))
        try setup.save()

        struct Boom: Error {}
        let ran1 = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner,
            saveOperation: { _ in throw Boom() })
        #expect(ran1 == false)

        let afterFailure = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "s1" })
        ).first)
        #expect(afterFailure.householdID == signedIn, "a failed save must leave the durable store exactly as it was")

        let ran2 = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran2 == true, "no marker was persisted on failure, so the rerun must recover")

        let afterRecovery = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "s1" })
        ).first)
        #expect(afterRecovery.householdID == owner)
    }

    // MARK: - Invariant 6 — byte-identical fields across re-home, tombstone intact

    @Test("re-home preserves every field except householdID, including an intact tombstone")
    func rehomePreservesFieldsAndTombstone() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        let live = LocalSeed(
            id: "s-live", householdID: signedIn, catalogID: "cat1", state: .active, packetCount: 7,
            locationID: "loc1", yearPacked: 2022, source: .store, customName: "Brandywine",
            customVariety: "Heirloom", customCompany: "Baker Creek", customType: "Tomato",
            notes: "notes here", tagIDs: ["t1"], growingInfo: nil, createdAt: 111, updatedAt: 222, deletedAt: nil)
        let tombstoned = LocalSeed(
            id: "s-tomb", householdID: signedIn, state: .active, packetCount: 1, source: .store,
            createdAt: 10, updatedAt: 999, deletedAt: 999)
        setup.insert(live)
        setup.insert(tombstoned)
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let context = ModelContext(container)
        let rehomedLive = try #require(context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "s-live" })).first)
        #expect(rehomedLive.householdID == owner)
        #expect(rehomedLive.catalogID == "cat1")
        #expect(rehomedLive.packetCount == 7)
        #expect(rehomedLive.locationID == "loc1")
        #expect(rehomedLive.yearPacked == 2022)
        #expect(rehomedLive.customName == "Brandywine")
        #expect(rehomedLive.customVariety == "Heirloom")
        #expect(rehomedLive.customCompany == "Baker Creek")
        #expect(rehomedLive.customType == "Tomato")
        #expect(rehomedLive.notes == "notes here")
        #expect(rehomedLive.tagIDs == ["t1"])
        #expect(rehomedLive.createdAt == 111)
        #expect(rehomedLive.updatedAt == 222, "re-home must not bump the clock")
        #expect(rehomedLive.deletedAt == nil)

        let rehomedTomb = try #require(context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "s-tomb" })).first)
        #expect(rehomedTomb.householdID == owner)
        #expect(rehomedTomb.createdAt == 10)
        #expect(rehomedTomb.updatedAt == 999)
        #expect(rehomedTomb.deletedAt == 999, "a tombstoned stranded row must re-home with the tombstone intact")
    }

    // MARK: - Invariant 8 — share-to-garden recreates from snapshot post-wipe

    @Test("share-to-garden recreates from snapshot atomically when the live row is gone (post-wipe path)")
    func shareRecreatesFromSnapshotPostWipe() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        setup.insert(LocalJournalEntry(
            id: "je1", householdID: signedIn, occurredOn: "2026-06-01", body: "Solo notes",
            seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil))
        setup.insert(LocalJournalChecklistItem(id: "ci1", entryID: "je1", text: "Water", completed: true, sortOrder: 0, updatedAt: 2))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let beforeWipe = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "je1" })
        ).first)
        #expect(beforeWipe.status == "pending")

        // Simulate a future adopt wipe: the 10 garden types (including the quarantined entry +
        // checklist item) are wiped, but the registry — not a garden type — survives.
        try HouseholdCloudCoordinator.wipeHouseholdSwiftData(container: container)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "je1" })).isEmpty)
        let survivingItem = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "je1" })
        ).first, "the registry must survive a garden wipe")
        #expect(survivingItem.status == "pending")

        let scope = ParticipantRowRecovery.scopeKey(ownerZoneHouseholdID: owner, signedInHouseholdID: signedIn)
        let liveRehomed = try ParticipantRowRecovery.shareLiveEntryIfPresent(
            itemID: "je1", ownerZoneHouseholdID: owner, currentScopeKey: scope, container: container)
        #expect(liveRehomed == false, "no live row remains after the wipe")

        let snapshot = try #require(ParticipantRowRecovery.decodeSnapshot(survivingItem.snapshotJSON))
        #expect(snapshot.body == "Solo notes")
        #expect(snapshot.checklistItems.map(\.text) == ["Water"])

        // R1 27d.18 hardening #1 — the recreate now goes through ONE atomic save (entry + checklist
        // items + the registry flip to `shared`) instead of separate JournalStore calls per row.
        let created = try ParticipantRowRecovery.recreateFromSnapshotAtomically(
            itemID: "je1", ownerZoneHouseholdID: owner, currentScopeKey: scope, container: container)

        #expect(created.id != "je1", "recreate mints a fresh id rather than reusing the stranded one")
        #expect(created.id.hasPrefix("journal_local_"))
        #expect(created.householdID == owner)
        #expect(created.body == "Solo notes")

        let createdEntryID = created.id
        let checklist = try ModelContext(container).fetch(
            FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.entryID == createdEntryID })
        )
        #expect(checklist.map(\.text) == ["Water"])
        #expect(checklist.map(\.completed) == [true])
        #expect(checklist.allSatisfy { $0.id.hasPrefix("journal_checklist_local_") })

        let finalItem = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "je1" })
        ).first)
        #expect(finalItem.status == "shared")
    }

    // MARK: - Invariant 1 (hardening) — atomic recreate is retry-safe after an injected failure

    @Test("a failed atomic recreate persists nothing and leaves the item pending; a retry produces exactly ONE entry")
    func atomicRecreateRetryAfterInjectedFailureProducesExactlyOneEntry() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        setup.insert(LocalJournalEntry(
            id: "retry-entry", householdID: signedIn, occurredOn: "2026-06-11", body: "Retry me",
            seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil))
        setup.insert(LocalJournalChecklistItem(id: "retry-ci", entryID: "retry-entry", text: "Weed", completed: false, sortOrder: 0, updatedAt: 2))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        // Simulate the post-wipe path: the live row is gone, only the registry snapshot remains.
        try HouseholdCloudCoordinator.wipeHouseholdSwiftData(container: container)

        let scope = ParticipantRowRecovery.scopeKey(ownerZoneHouseholdID: owner, signedInHouseholdID: signedIn)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try ParticipantRowRecovery.recreateFromSnapshotAtomically(
                itemID: "retry-entry", ownerZoneHouseholdID: owner, currentScopeKey: scope,
                container: container, saveOperation: { _ in throw Boom() })
        }

        // Nothing persisted: no journal entry exists yet, and the registry item is still pending —
        // proving the whole recreate (entry + checklist items + registry flip) is one atomic unit.
        let afterFailure = try ModelContext(container).fetch(FetchDescriptor<LocalJournalEntry>())
        #expect(afterFailure.isEmpty, "a failed atomic save must persist nothing")
        let itemAfterFailure = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "retry-entry" })
        ).first)
        #expect(itemAfterFailure.status == "pending", "a failed atomic save must not flip the registry item")

        // Retry — mirrors a retap of the still-enabled Share button — succeeds this time.
        let recreated = try ParticipantRowRecovery.recreateFromSnapshotAtomically(
            itemID: "retry-entry", ownerZoneHouseholdID: owner, currentScopeKey: scope, container: container)

        let allEntries = try ModelContext(container).fetch(FetchDescriptor<LocalJournalEntry>())
        #expect(allEntries.count == 1, "a retry after a failed atomic save must produce exactly ONE entry, not a duplicate")
        #expect(allEntries.first?.id == recreated.id)
        #expect(recreated.householdID == owner)
        #expect(recreated.body == "Retry me")

        let recreatedEntryID = recreated.id
        let checklist = try ModelContext(container).fetch(
            FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.entryID == recreatedEntryID })
        )
        #expect(checklist.map(\.text) == ["Weed"])

        let finalItem = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "retry-entry" })
        ).first)
        #expect(finalItem.status == "shared")
    }

    // MARK: - Invariant 2 (hardening) — scope re-validation refuses a foreign-scope item

    @Test("an action refuses when the registry item's scopeKey doesn't match the current scope; nothing is mutated")
    func scopeMismatchRefusesAndMutatesNothing() throws {
        let container = makeContainer()
        let signedIn = "S"
        let staleOwner = "O1"
        let currentOwner = "O2"

        let setup = ModelContext(container)
        setup.insert(LocalJournalEntry(
            id: "cross-scope-entry", householdID: signedIn, occurredOn: "2026-06-10", body: "Cross scope",
            seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil))
        let staleScope = ParticipantRowRecovery.scopeKey(ownerZoneHouseholdID: staleOwner, signedInHouseholdID: signedIn)
        setup.insert(LocalJournalRecoveryItem(
            id: "cross-scope-entry", scopeKey: staleScope, snapshotJSON: "{}", detectedAt: 1, status: "pending"))
        try setup.save()

        // The item's scopeKey is "O1|S" but the action is invoked under the CURRENT scope "O2|S".
        let currentScope = ParticipantRowRecovery.scopeKey(ownerZoneHouseholdID: currentOwner, signedInHouseholdID: signedIn)
        #expect(currentScope != staleScope)

        #expect(throws: SeedkeepError.self) {
            try ParticipantRowRecovery.shareLiveEntryIfPresent(
                itemID: "cross-scope-entry", ownerZoneHouseholdID: currentOwner, currentScopeKey: currentScope, container: container)
        }
        #expect(throws: SeedkeepError.self) {
            try ParticipantRowRecovery.keepPrivate(itemID: "cross-scope-entry", currentScopeKey: currentScope, container: container)
        }
        #expect(throws: SeedkeepError.self) {
            try ParticipantRowRecovery.markShared(itemID: "cross-scope-entry", currentScopeKey: currentScope, container: container)
        }

        let entry = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "cross-scope-entry" })
        ).first)
        #expect(entry.householdID == signedIn, "a scope-mismatched action must not mutate the live row")

        let item = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "cross-scope-entry" })
        ).first)
        #expect(item.status == "pending", "a scope-mismatched action must not mutate the registry item")
    }

    // MARK: - Invariant 3 (hardening) — tombstoned ambiguous entries are never registered

    @Test("a stranded soft-deleted entry with no FK is left parked with its tombstone, not registered for review")
    func strandedTombstonedNoFKEntryIsNotRegisteredAndStaysParked() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        setup.insert(LocalJournalEntry(
            id: "tomb-no-fk", householdID: signedIn, occurredOn: "2026-05-20", body: "Deleted solo entry",
            seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: 3))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let after = HouseholdMigrationPlanner.fetchInput(
            from: ModelContext(container), householdID: owner, householdName: "G", householdCreatedAt: 1, householdUpdatedAt: 1)
        #expect(after.journalEntries.isEmpty, "a tombstoned ambiguous entry must never appear in the owner-zone export")

        #expect(try ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "tomb-no-fk" })
        ).isEmpty, "a tombstoned ambiguous entry must not be registered for review")

        let stillParked = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "tomb-no-fk" })
        ).first)
        #expect(stillParked.householdID == signedIn, "must be left completely untouched")
        #expect(stillParked.deletedAt == 3, "the tombstone must remain intact")
    }

    // MARK: - Invariant 6 (breadth) — byte-identity for LocalPlantingEvent + FK-evidenced LocalJournalEntry

    @Test("re-home preserves every field of a LocalPlantingEvent, including the never-sync pet streak columns")
    func rehomePreservesPlantingEventFieldsIncludingNeverSyncPetColumns() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        let event = LocalPlantingEvent(
            id: "pe-live", householdID: signedIn, bedID: "bed1", seedID: "seed1", catalogSeedID: "cat1",
            kindRaw: "sowing", plannedFor: "2026-07-01", completedAt: nil, notes: "notes",
            xFeet: 1.5, yFeet: 2.5, createdAt: 111, updatedAt: 222, deletedAt: nil,
            petSeed: "abc123", petRarity: "rare", petCreatureKind: "garden_worm", petName: "Wiggles",
            petPersonalityJSON: "{\"name\":\"Wiggles\"}", petSpawnedAt: 333,
            petWiltedStreakDays: 4, petLastMoodTickAt: 444)
        setup.insert(event)
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let context = ModelContext(container)
        let rehomed = try #require(context.fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == "pe-live" })).first)
        #expect(rehomed.householdID == owner)
        #expect(rehomed.bedID == "bed1")
        #expect(rehomed.seedID == "seed1")
        #expect(rehomed.catalogSeedID == "cat1")
        #expect(rehomed.kindRaw == "sowing")
        #expect(rehomed.plannedFor == "2026-07-01")
        #expect(rehomed.completedAt == nil)
        #expect(rehomed.notes == "notes")
        #expect(rehomed.xFeet == 1.5)
        #expect(rehomed.yFeet == 2.5)
        #expect(rehomed.createdAt == 111)
        #expect(rehomed.updatedAt == 222, "re-home must not bump the clock")
        #expect(rehomed.deletedAt == nil)
        #expect(rehomed.petSeed == "abc123")
        #expect(rehomed.petRarity == "rare")
        #expect(rehomed.petCreatureKind == "garden_worm")
        #expect(rehomed.petName == "Wiggles")
        #expect(rehomed.petPersonalityJSON == "{\"name\":\"Wiggles\"}")
        #expect(rehomed.petSpawnedAt == 333)
        #expect(rehomed.petWiltedStreakDays == 4, "the never-sync pet streak columns must survive re-home untouched")
        #expect(rehomed.petLastMoodTickAt == 444, "the never-sync pet streak columns must survive re-home untouched")
    }

    @Test("FK-evidenced re-home preserves every field of the journal entry, not just its id")
    func fkEvidencedRehomePreservesJournalEntryFields() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        setup.insert(LocalBed(id: "ownerBed2", householdID: owner, name: "East", createdAt: 1, updatedAt: 2))
        setup.insert(LocalJournalEntry(
            id: "fk-entry", householdID: signedIn, occurredOn: "2026-06-05", body: "Full field check",
            seedID: nil, bedID: "ownerBed2", plantingEventID: nil, createdAt: 77, updatedAt: 88, deletedAt: nil))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let context = ModelContext(container)
        let rehomed = try #require(context.fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "fk-entry" })).first)
        #expect(rehomed.householdID == owner)
        #expect(rehomed.occurredOn == "2026-06-05")
        #expect(rehomed.body == "Full field check")
        #expect(rehomed.seedID == nil)
        #expect(rehomed.bedID == "ownerBed2")
        #expect(rehomed.plantingEventID == nil)
        #expect(rehomed.createdAt == 77)
        #expect(rehomed.updatedAt == 88, "re-home must not bump the clock")
        #expect(rehomed.deletedAt == nil)
    }

    // MARK: - Invariant 9 — keep-private

    @Test("keep-private marks the item kept and leaves rows parked; nothing deleted")
    func keepPrivateLeavesRowsParkedAndMarksKept() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"

        let setup = ModelContext(container)
        setup.insert(LocalJournalEntry(
            id: "je-kept", householdID: signedIn, occurredOn: "2026-06-03", body: "Private thought",
            seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil))
        setup.insert(LocalJournalChecklistItem(id: "ci-kept", entryID: "je-kept", text: "Note", completed: false, sortOrder: 0, updatedAt: 2))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let scope = ParticipantRowRecovery.scopeKey(ownerZoneHouseholdID: owner, signedInHouseholdID: signedIn)
        try ParticipantRowRecovery.keepPrivate(itemID: "je-kept", currentScopeKey: scope, container: container)

        let item = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "je-kept" })
        ).first)
        #expect(item.status == "kept")

        let entry = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "je-kept" })
        ).first)
        #expect(entry.householdID == signedIn, "a kept row stays parked under the signed-in household")

        let checklist = try ModelContext(container).fetch(
            FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.entryID == "je-kept" })
        )
        #expect(checklist.count == 1, "nothing is deleted")
    }

    // MARK: - Invariant 10 — nothing outside scope is touched

    @Test("rows belonging to a third household (e.g. the parked solo zone) are left untouched")
    func thirdHouseholdRowsUntouched() throws {
        let container = makeContainer()
        let signedIn = "signed-\(UUID().uuidString)"
        let owner = "owner-\(UUID().uuidString)"
        let otherHousehold = "other-\(UUID().uuidString)"

        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "otherSeed", householdID: otherHousehold, state: .active, packetCount: 2, source: .store, createdAt: 1, updatedAt: 2))
        setup.insert(LocalSeed(id: "strandedSeed", householdID: signedIn, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 2))
        try setup.save()

        let ran = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner)
        #expect(ran == true)

        let otherSeed = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "otherSeed" })
        ).first)
        #expect(otherSeed.householdID == otherHousehold, "a row belonging to neither the signed-in nor owner-zone ID must be left untouched")

        let stranded = try #require(ModelContext(container).fetch(
            FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "strandedSeed" })
        ).first)
        #expect(stranded.householdID == owner)
    }
}
