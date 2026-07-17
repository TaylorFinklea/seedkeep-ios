import Foundation
import SwiftData

// R1 27d.18 — one-time recovery for participant garden rows stranded under the signed-in server
// household ID by pre-fix builds 47–49 (see `.docs/ai/decisions.md` 2026-07-16 "Ambiguous pre-fix
// participant journal rows recover via evidence gating plus a review inbox"). Mirrors the
// planner/executor split in `HouseholdMigrationPlanner` + `HouseholdMigrationExecutor`: a pure
// planning function (SwiftData rows in → disposition lists out, host-testable with no container)
// plus a small runner that fetches, applies, and durably marks the one-time pass.
enum ParticipantRowRecovery {

    // MARK: - Pure planning

    /// Already-fetched candidate rows. `locations`/`tags`/`seeds`/`beds`/`plantingEvents`/
    /// `journalEntries` are the STRANDED candidates (householdID == signed-in ID) — the caller
    /// fetches with that filter, exactly like `HouseholdMigrationPlanner.fetchInput`.
    /// `checklistItems` carries every local row (the type has no `householdID` column; it is scoped
    /// by `entryID` membership only, same as `HouseholdMigrationPlanner.fetchInput`'s journal
    /// children). `owner*IDs` are the ids already resolvable in the owner-zone garden BEFORE this
    /// run (pre-existing peer rows) — `plan()` unions these with the five-type rows it is re-homing
    /// this same call to get the "after step 1" resolution set the FK-evidence rule requires.
    struct Input {
        var signedInHouseholdID: String
        var ownerZoneHouseholdID: String
        var locations: [LocalLocation] = []
        var tags: [LocalTag] = []
        var seeds: [LocalSeed] = []
        var beds: [LocalBed] = []
        var plantingEvents: [LocalPlantingEvent] = []
        var journalEntries: [LocalJournalEntry] = []
        var checklistItems: [LocalJournalChecklistItem] = []
        var ownerSeedIDs: Set<String> = []
        var ownerBedIDs: Set<String> = []
        var ownerPlantingEventIDs: Set<String> = []
    }

    struct QuarantinedEntry {
        var entry: LocalJournalEntry
        var checklistItems: [LocalJournalChecklistItem]
    }

    struct Plan {
        var rehomeLocations: [LocalLocation] = []
        var rehomeTags: [LocalTag] = []
        var rehomeSeeds: [LocalSeed] = []
        var rehomeBeds: [LocalBed] = []
        var rehomePlantingEvents: [LocalPlantingEvent] = []
        var rehomeJournalEntries: [LocalJournalEntry] = []
        var quarantined: [QuarantinedEntry] = []
    }

    /// Pure: candidate rows in → disposition lists out. No ModelContext, no I/O — host-testable like
    /// `HouseholdMigrationPlanner.plan()`.
    ///
    /// The five queue-backed types always re-home (evidence rule #1 — the adopt wipe made every
    /// prior local row for these types disappear, and no view-driven path re-imported them under
    /// CloudKit-ON builds 47–49, so a row surviving with the signed-in ID can only be a
    /// participant-authored garden row).
    ///
    /// A journal entry re-homes automatically only when its `parentKind` FK resolves into the
    /// owner-zone garden AS OF AFTER STEP 1 (pre-existing owner rows ∪ the five-type rows this same
    /// call is re-homing) — that FK could only have been set by code running against the adopted
    /// garden, i.e. post-adopt authorship. Everything else journal-shaped (no FK, or an FK that
    /// still doesn't resolve) is quarantined with its checklist items snapshotted for the review inbox.
    static func plan(_ input: Input) -> Plan {
        var out = Plan()
        out.rehomeLocations = input.locations
        out.rehomeTags = input.tags
        out.rehomeSeeds = input.seeds
        out.rehomeBeds = input.beds
        out.rehomePlantingEvents = input.plantingEvents

        let resolvedSeedIDs = input.ownerSeedIDs.union(input.seeds.map(\.id))
        let resolvedBedIDs = input.ownerBedIDs.union(input.beds.map(\.id))
        let resolvedPlantingEventIDs = input.ownerPlantingEventIDs.union(input.plantingEvents.map(\.id))
        let checklistByEntry = Dictionary(grouping: input.checklistItems, by: \.entryID)

        for entry in input.journalEntries {
            let resolves: Bool
            switch entry.parentKind {
            case .seed(let id): resolves = resolvedSeedIDs.contains(id)
            case .bed(let id): resolves = resolvedBedIDs.contains(id)
            case .plantingEvent(let id): resolves = resolvedPlantingEventIDs.contains(id)
            case .garden: resolves = false
            }
            if resolves {
                out.rehomeJournalEntries.append(entry)
            } else {
                out.quarantined.append(QuarantinedEntry(
                    entry: entry, checklistItems: checklistByEntry[entry.id] ?? []))
            }
        }
        return out
    }

    // MARK: - Snapshot payload (mirrors `LocalPendingWrite.payloadJSON`)

    struct EntrySnapshot: Codable {
        var occurredOn: String
        var body: String
        var seedID: String?
        var bedID: String?
        var plantingEventID: String?
        var createdAt: Int64
        var updatedAt: Int64
        var deletedAt: Int64?
        var checklistItems: [ChecklistSnapshot]

        struct ChecklistSnapshot: Codable {
            var text: String
            var completed: Bool
            var sortOrder: Int
            var updatedAt: Int64
        }

        init(entry: LocalJournalEntry, checklistItems: [LocalJournalChecklistItem]) {
            occurredOn = entry.occurredOn
            body = entry.body
            seedID = entry.seedID
            bedID = entry.bedID
            plantingEventID = entry.plantingEventID
            createdAt = entry.createdAt
            updatedAt = entry.updatedAt
            deletedAt = entry.deletedAt
            self.checklistItems = checklistItems
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { ChecklistSnapshot(text: $0.text, completed: $0.completed, sortOrder: $0.sortOrder, updatedAt: $0.updatedAt) }
        }

        var encodedJSON: String? {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }

        static func decode(_ json: String) -> EntrySnapshot? {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(EntrySnapshot.self, from: data)
        }
    }

    static func decodeSnapshot(_ json: String) -> EntrySnapshot? {
        EntrySnapshot.decode(json)
    }

    // MARK: - Scope + marker

    static func scopeKey(ownerZoneHouseholdID: String, signedInHouseholdID: String) -> String {
        "\(ownerZoneHouseholdID)|\(signedInHouseholdID)"
    }

    @MainActor
    private static func markerKey(scopeKey: String) -> String {
        "seedkeep.ck.recovery27d18.\(HouseholdCloudCoordinator.cloudKitEnvironmentTag).\(scopeKey)"
    }

    // MARK: - Runner

    /// Durable one-time migration. No-ops (zero writes, returns `false`) when:
    ///  - `ownerZoneHouseholdID == signedInHouseholdID` (owner mode / no participant marker — the
    ///    caller only invokes this when they differ, but the guard makes the function safe and
    ///    host-testable standalone);
    ///  - the durable per-scope marker is already set (idempotency).
    /// Atomic: one `ModelContext`, one `context.save()` covering every re-home + registry insert.
    /// The marker is written ONLY after that save succeeds, so a failure leaves detection stateless
    /// and the next launch safely re-runs. Returns `true` when it ran and the save succeeded (whether
    /// or not anything needed re-homing) — the caller fires `noteHouseholdMutation()` on `true` so any
    /// re-homed rows push immediately instead of waiting for the next debounce.
    @discardableResult
    @MainActor
    static func runIfNeeded(
        container: ModelContainer,
        signedInHouseholdID: String,
        ownerZoneHouseholdID: String,
        saveOperation: ((ModelContext) throws -> Void)? = nil
    ) -> Bool {
        guard ownerZoneHouseholdID != signedInHouseholdID else { return false }
        let scope = scopeKey(ownerZoneHouseholdID: ownerZoneHouseholdID, signedInHouseholdID: signedInHouseholdID)
        let key = markerKey(scopeKey: scope)
        guard !UserDefaults.standard.bool(forKey: key) else { return false }

        let context = ModelContext(container)
        let sid = signedInHouseholdID
        let oid = ownerZoneHouseholdID
        func fetch<T: PersistentModel>(_ d: FetchDescriptor<T>) -> [T] { (try? context.fetch(d)) ?? [] }

        var input = Input(signedInHouseholdID: sid, ownerZoneHouseholdID: oid)
        input.locations = fetch(FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.householdID == sid }))
        input.tags = fetch(FetchDescriptor<LocalTag>(predicate: #Predicate { $0.householdID == sid }))
        input.seeds = fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.householdID == sid }))
        input.beds = fetch(FetchDescriptor<LocalBed>(predicate: #Predicate { $0.householdID == sid }))
        input.plantingEvents = fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.householdID == sid }))
        input.journalEntries = fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.householdID == sid }))
        input.checklistItems = fetch(FetchDescriptor<LocalJournalChecklistItem>())
        input.ownerSeedIDs = Set(fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.householdID == oid })).map(\.id))
        input.ownerBedIDs = Set(fetch(FetchDescriptor<LocalBed>(predicate: #Predicate { $0.householdID == oid })).map(\.id))
        input.ownerPlantingEventIDs = Set(fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.householdID == oid })).map(\.id))

        let disposition = plan(input)

        for row in disposition.rehomeLocations { row.householdID = oid }
        for row in disposition.rehomeTags { row.householdID = oid }
        for row in disposition.rehomeSeeds { row.householdID = oid }
        for row in disposition.rehomeBeds { row.householdID = oid }
        for row in disposition.rehomePlantingEvents { row.householdID = oid }
        for row in disposition.rehomeJournalEntries { row.householdID = oid }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for quarantined in disposition.quarantined {
            let entryID = quarantined.entry.id
            let alreadyRegistered = try? context.fetch(
                FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == entryID })
            ).first
            guard alreadyRegistered == nil,
                  let json = EntrySnapshot(entry: quarantined.entry, checklistItems: quarantined.checklistItems).encodedJSON
            else { continue }
            context.insert(LocalJournalRecoveryItem(
                id: entryID, scopeKey: scope, snapshotJSON: json, detectedAt: now, status: "pending"))
        }

        do {
            try (saveOperation ?? { try $0.save() })(context)
        } catch {
            return false
        }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    // MARK: - Review inbox actions

    /// Share to garden, live-row path: if the stranded/quarantined entry still exists locally,
    /// re-home it in place (checklist items + journal photos need no mutation — they carry no
    /// `householdID`; they are scoped by `entryID` membership and already follow the parent) and
    /// mark the registry item `shared`. Returns `false` when no live row remains (post-wipe), so the
    /// caller recreates from `snapshotJSON` instead.
    @discardableResult
    @MainActor
    static func shareLiveEntryIfPresent(itemID: String, ownerZoneHouseholdID: String, container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        guard let entry = try? context.fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == itemID })
        ).first else { return false }
        entry.householdID = ownerZoneHouseholdID
        if let item = try? context.fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == itemID })
        ).first {
            item.status = "shared"
        }
        try? context.save()
        return true
    }

    /// Marks a registry item `shared` after the caller recreated it via `JournalStore`'s CloudKit
    /// authoring path (the post-wipe path, when `shareLiveEntryIfPresent` returned `false`).
    @MainActor
    static func markShared(itemID: String, container: ModelContainer) {
        let context = ModelContext(container)
        guard let item = try? context.fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == itemID })
        ).first else { return }
        item.status = "shared"
        try? context.save()
    }

    /// Keep private: mark the registry item `kept`. Any live row stays parked and hidden — nothing
    /// deleted anywhere.
    @MainActor
    static func keepPrivate(itemID: String, container: ModelContainer) {
        let context = ModelContext(container)
        guard let item = try? context.fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == itemID })
        ).first else { return }
        item.status = "kept"
        try? context.save()
    }
}
