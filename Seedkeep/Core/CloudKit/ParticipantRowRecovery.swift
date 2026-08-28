import Foundation
import SwiftData
import SeedkeepKit

// R1 27d.18 — one-time recovery for participant garden rows stranded under the signed-in server
// household ID by pre-fix builds 47–49 (see `.docs/ai/decisions.md` 2026-07-16 "Ambiguous pre-fix
// participant journal rows recover via evidence gating plus a review inbox"). Mirrors the
// planner/executor split in `HouseholdMigrationPlanner` + `HouseholdMigrationExecutor`: a pure
// planning function (SwiftData rows in → disposition lists out, host-testable with no container)
// plus a small runner that fetches, applies, and durably marks the one-time pass.
enum ParticipantRowRecovery {

    // MARK: - Pure planning

    /// Already-fetched candidate rows. `locations`/`tags`/`seeds`/`seedPhotos`/`beds`/`plantingEvents`/
    /// `journalEntries` are the STRANDED candidates (householdID == signed-in ID) — the caller
    /// fetches with that filter, exactly like `HouseholdMigrationPlanner.fetchInput`.
    /// `checklistItems` carries every local row (the type has no `householdID` column; it is scoped
    /// by `entryID` membership only, same as `HouseholdMigrationPlanner.fetchInput`'s journal
    /// children). `owner*IDs` are the ids already resolvable in the owner-zone garden BEFORE this
    /// run (pre-existing peer rows) — `plan()` unions these with the primary rows it is re-homing
    /// this same call to get the "after step 1" resolution set the FK-evidence rule requires.
    struct Input {
        var signedInHouseholdID: String
        var ownerZoneHouseholdID: String
        var locations: [LocalLocation] = []
        var tags: [LocalTag] = []
        var seeds: [LocalSeed] = []
        var seedPhotos: [LocalSeedPhoto] = []
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
        var rehomeSeedPhotos: [LocalSeedPhoto] = []
        var rehomeBeds: [LocalBed] = []
        var rehomePlantingEvents: [LocalPlantingEvent] = []
        var rehomeJournalEntries: [LocalJournalEntry] = []
        var quarantined: [QuarantinedEntry] = []
    }

    /// Pure: candidate rows in → disposition lists out. No ModelContext, no I/O — host-testable like
    /// `HouseholdMigrationPlanner.plan()`.
    ///
    /// The five queue-backed primary types always re-home (evidence rule #1 — the adopt wipe made every
    /// prior local row for these types disappear, and no view-driven path re-imported them under
    /// CloudKit-ON builds 47–49, so a row surviving with the signed-in ID can only be a
    /// participant-authored garden row). A seed photo re-homes when its parent seed resolves in
    /// that post-step-1 set, preserving the photo relationship without exporting an orphan.
    ///
    /// A journal entry re-homes automatically only when its `parentKind` FK resolves into the
    /// owner-zone garden AS OF AFTER STEP 1 (pre-existing owner rows ∪ the five-type rows this same
    /// call is re-homing) — that FK could only have been set by code running against the adopted
    /// garden, i.e. post-adopt authorship. Everything else journal-shaped (no FK, or an FK that
    /// still doesn't resolve) is quarantined with its checklist items snapshotted for the review inbox.
    ///
    /// R1 27d.18 hardening #3 (tombstone filter) — an AMBIGUOUS entry (no FK, or an FK that doesn't
    /// resolve) that is ALSO already soft-deleted (`deletedAt != nil`) gets NO registry item: it is
    /// left completely untouched instead. Without this, the review inbox would offer to "Share" an
    /// already-deleted entry, and the share path would resurrect deleted content by recreating it.
    /// FK-evidenced entries keep re-homing with an intact tombstone regardless (unchanged, existing
    /// behavior) — only the ambiguous/quarantine branch gets the filter.
    static func plan(_ input: Input) -> Plan {
        var out = Plan()
        out.rehomeLocations = input.locations
        out.rehomeTags = input.tags
        out.rehomeSeeds = input.seeds
        out.rehomeBeds = input.beds
        out.rehomePlantingEvents = input.plantingEvents

        let resolvedSeedIDs = input.ownerSeedIDs.union(input.seeds.map(\.id))
        out.rehomeSeedPhotos = input.seedPhotos.filter { resolvedSeedIDs.contains($0.seedID) }
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
            } else if entry.deletedAt == nil {
                out.quarantined.append(QuarantinedEntry(
                    entry: entry, checklistItems: checklistByEntry[entry.id] ?? []))
            }
            // else: ambiguous AND already soft-deleted — leave parked, no registry item (hardening #3).
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
        input.seedPhotos = fetch(FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.householdID == sid }))
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
        for row in disposition.rehomeSeedPhotos { row.householdID = oid }
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
    //
    // R1 27d.18 hardening #2 (scope re-validation, defense-in-depth) — every action below now
    // requires the CALLER's `currentScopeKey` and refuses (throws, no mutation of any kind) when the
    // registry item's own `scopeKey` doesn't match it. Without this, an item/entry id passed by a
    // stale reference — e.g. a captured `LocalJournalRecoveryItem` across a garden switch while the
    // review sheet is still open, or a future call site that doesn't re-derive scope per call — could
    // push content into whatever owner zone happens to be active. The registry item is always looked
    // up FIRST so the guard runs before any mutation is attempted.

    /// Share to garden, live-row path: if the stranded/quarantined entry still exists locally,
    /// re-home it in place (checklist items + journal photos need no mutation — they carry no
    /// `householdID`; they are scoped by `entryID` membership and already follow the parent) and
    /// mark the registry item `shared`. Returns `false` when no live row remains (post-wipe), so the
    /// caller recreates via `recreateFromSnapshotAtomically` instead.
    @discardableResult
    @MainActor
    static func shareLiveEntryIfPresent(
        itemID: String, ownerZoneHouseholdID: String, currentScopeKey: String, container: ModelContainer
    ) throws -> Bool {
        let context = ModelContext(container)
        guard let registryItem = try context.fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == itemID })
        ).first else { return false }
        guard registryItem.scopeKey == currentScopeKey else {
            throw SeedkeepError(
                code: "scope_mismatch",
                message: "This item belongs to a different garden and can't be shared here.")
        }
        guard let entry = try context.fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == itemID })
        ).first else { return false }
        entry.householdID = ownerZoneHouseholdID
        registryItem.status = "shared"
        try context.save()
        return true
    }

    /// Marks a registry item `shared`. Superseded, as the production post-wipe caller, by
    /// `recreateFromSnapshotAtomically` (hardening #1 — see its doc), which flips status in the SAME
    /// save as the recreate; kept as a low-level primitive for a caller that recreates through a
    /// different path and still needs the scope guard.
    @MainActor
    static func markShared(itemID: String, currentScopeKey: String, container: ModelContainer) throws {
        let context = ModelContext(container)
        guard let item = try context.fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == itemID })
        ).first else { return }
        guard item.scopeKey == currentScopeKey else {
            throw SeedkeepError(
                code: "scope_mismatch",
                message: "This item belongs to a different garden and can't be shared here.")
        }
        item.status = "shared"
        try context.save()
    }

    /// Keep private: mark the registry item `kept`. Any live row stays parked and hidden — nothing
    /// deleted anywhere.
    @MainActor
    static func keepPrivate(itemID: String, currentScopeKey: String, container: ModelContainer) throws {
        let context = ModelContext(container)
        guard let item = try context.fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == itemID })
        ).first else { return }
        guard item.scopeKey == currentScopeKey else {
            throw SeedkeepError(
                code: "scope_mismatch",
                message: "This item belongs to a different garden and can't be shared here.")
        }
        item.status = "kept"
        try context.save()
    }

    /// Atomic post-wipe recreate (R1 27d.18 hardening #1). The ORIGINAL post-wipe path in
    /// `AppEnvironment.shareJournalRecoveryItem` called `JournalStore.create`, one
    /// `addChecklistItem`/`updateChecklistItem` pair per snapshot row, then `markShared` — each its
    /// own `ModelContext` + `save()`. If `create` succeeded and a later step threw, the registry item
    /// stayed `pending` while a `journal_local_` entry already existed; a retap of the (unconditionally
    /// re-enabled) Share button would then recreate a SECOND entry, duplicating content in the owner
    /// zone. This inserts the entry + every checklist item + flips the registry item to `shared` in
    /// ONE `context.save()`, so a mid-batch failure leaves nothing persisted and the registry item
    /// still `pending` — a retry is safe. Mints ids/fields exactly as `JournalStore`'s CloudKit
    /// authoring path does (`journal_local_`/`journal_checklist_local_` prefixes, the owner-zone
    /// `householdID` stamp); every fresh row shares one `now` timestamp since nothing here is ever
    /// updated afterward, so `JournalStore`'s monotonic max-bump (used for edits) doesn't apply. The
    /// FK the entry once carried is intentionally NOT reattached — same reasoning as the path this
    /// replaces (a quarantined entry's FK, by definition, never resolved into the owner-zone garden).
    /// Also re-validates `currentScopeKey` (hardening #2) before touching anything.
    @discardableResult
    @MainActor
    static func recreateFromSnapshotAtomically(
        itemID: String,
        ownerZoneHouseholdID: String,
        currentScopeKey: String,
        container: ModelContainer,
        saveOperation: ((ModelContext) throws -> Void)? = nil
    ) throws -> LocalJournalEntry {
        let context = ModelContext(container)
        guard let item = try context.fetch(
            FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == itemID })
        ).first else {
            throw SeedkeepError(code: "not_found", message: "Recovery item not found")
        }
        guard item.scopeKey == currentScopeKey else {
            throw SeedkeepError(
                code: "scope_mismatch",
                message: "This item belongs to a different garden and can't be shared here.")
        }
        guard let snapshot = EntrySnapshot.decode(item.snapshotJSON) else {
            throw SeedkeepError(
                code: "invalid_snapshot", message: "The recovery item's snapshot could not be read")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let entryID = "journal_local_\(UUID().uuidString)"
        let entry = LocalJournalEntry(
            id: entryID, householdID: ownerZoneHouseholdID, occurredOn: snapshot.occurredOn,
            body: snapshot.body, seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: now, updatedAt: now, deletedAt: nil)
        context.insert(entry)
        for (index, checklistItem) in snapshot.checklistItems.enumerated() {
            context.insert(LocalJournalChecklistItem(
                id: "journal_checklist_local_\(UUID().uuidString)", entryID: entryID,
                text: checklistItem.text, completed: checklistItem.completed,
                sortOrder: index, updatedAt: now))
        }
        item.status = "shared"
        try (saveOperation ?? { try $0.save() })(context)
        return entry
    }
}
