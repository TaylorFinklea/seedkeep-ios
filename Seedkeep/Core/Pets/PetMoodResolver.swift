import Foundation
import SwiftData
import SeedkeepKit

/// Builds `PetMoodInputs` for a single `LocalPlantingEvent` by issuing
/// the SwiftData fetches called out in the Phase 5 spec ("Inputs" table,
/// line 551). Pure-ish: no notifications, no writes — the resolver is a
/// query layer between SwiftData and the pure `MoodEngine`.
///
/// Lives on the main actor because SwiftData `ModelContext` use from
/// background actors is not yet supported in this codebase (mirrors
/// `SyncEngine`'s annotation).
@MainActor
public enum PetMoodResolver {
    /// Resolve inputs for `event` given the current wall clock `now`.
    /// `context` should be a fresh `ModelContext` derived from the
    /// app's `ModelContainer`. The caller owns its lifecycle.
    public static func resolveInputs(
        event: LocalPlantingEvent,
        now: Date,
        context: ModelContext
    ) -> PetMoodInputs {
        let eventID = event.id
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // 1) Latest journal entry for this planting (loneliness).
        let latestJournalMs = latestJournalEntryMs(
            plantingEventID: eventID,
            context: context
        )
        let daysSinceJournal = latestJournalMs.map { days(between: $0, and: nowMs) }
            ?? days(between: event.createdAt, and: nowMs)

        // 2) Watered-checklist item (thirst). Two-hop: entry IDs, then
        //    checklist items with text containing "water".
        let entryIDs = journalEntryIDs(plantingEventID: eventID, context: context)
        let wateredMs = latestWateredItemMs(entryIDs: entryIDs, context: context)
        let daysSinceWatered = wateredMs.map { days(between: $0, and: nowMs) }

        // 3) Latest photo across this planting's entries (attention).
        let latestPhotoMs = latestPhotoMs(entryIDs: entryIDs, context: context)
        let daysSincePhoto = latestPhotoMs.map { days(between: $0, and: nowMs) }
            ?? days(between: event.createdAt, and: nowMs)

        // 4) Age in days from `pet_spawned_at`. Single clock per spec
        //    decision #1. Floor to 0 for safety.
        let spawnedMs = event.petSpawnedAt ?? event.createdAt
        let ageDays = max(0, days(between: spawnedMs, and: nowMs))

        // 5) Harvest window from the linked `LocalSeed.growingInfo`.
        let harvestWindow = resolveHarvestWindow(seedID: event.seedID, context: context)

        // 6) Sibling activity (companionship). Most recent across siblings
        //    of `max(sibling.updatedAt, latestJournalEntry(sibling).createdAt)`.
        let siblingMs = latestSiblingActivityMs(event: event, context: context)
        let daysSinceSiblingActivity = siblingMs.map { days(between: $0, and: nowMs) }

        return PetMoodInputs(
            daysSinceJournal: daysSinceJournal,
            daysSinceWatered: daysSinceWatered,
            daysSincePhoto: daysSincePhoto,
            ageDays: ageDays,
            harvestWindowMaxDays: harvestWindow,
            daysSinceSiblingActivity: daysSinceSiblingActivity
        )
    }

    // MARK: - Sub-queries

    /// Most-recent `LocalJournalEntry` for this planting (occurredOn as
    /// the timestamp, parsed in YMD form). Returns the entry's
    /// `createdAt` as the wall-clock approximation — `occurredOn` is a
    /// date string, `createdAt` is the closest epoch the schema offers.
    private static func latestJournalEntryMs(
        plantingEventID: String,
        context: ModelContext
    ) -> Int64? {
        var descriptor = FetchDescriptor<LocalJournalEntry>(
            predicate: #Predicate { entry in
                entry.plantingEventID == plantingEventID && entry.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.occurredOn, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.createdAt
    }

    /// All non-deleted entry IDs for this planting — used as the IN
    /// list for the photo + checklist sub-queries.
    private static func journalEntryIDs(
        plantingEventID: String,
        context: ModelContext
    ) -> [String] {
        let descriptor = FetchDescriptor<LocalJournalEntry>(
            predicate: #Predicate { entry in
                entry.plantingEventID == plantingEventID && entry.deletedAt == nil
            }
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.id)
    }

    /// Latest completed checklist item whose text contains "water"
    /// across the given entry set. Spec calls this an approximation
    /// because `updatedAt` is the only timestamp the schema exposes.
    private static func latestWateredItemMs(
        entryIDs: [String],
        context: ModelContext
    ) -> Int64? {
        guard !entryIDs.isEmpty else { return nil }
        let descriptor = FetchDescriptor<LocalJournalChecklistItem>(
            predicate: #Predicate { item in
                entryIDs.contains(item.entryID) && item.completed == true
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.first(where: { $0.text.localizedStandardContains("water") })?.updatedAt
    }

    /// Most-recent photo across the entry set.
    private static func latestPhotoMs(
        entryIDs: [String],
        context: ModelContext
    ) -> Int64? {
        guard !entryIDs.isEmpty else { return nil }
        var descriptor = FetchDescriptor<LocalJournalEntryPhoto>(
            predicate: #Predicate { photo in
                entryIDs.contains(photo.entryID)
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.createdAt
    }

    /// Pull `growingInfo.days_to_maturity_max` off the linked
    /// `LocalSeed`. Nil if any link in the chain is missing — spec:
    /// "catalog-only seeds: if a planting references only a
    /// `catalog_seed_id` with no local `LocalSeed`, impatience falls
    /// back to neutral".
    private static func resolveHarvestWindow(
        seedID: String?,
        context: ModelContext
    ) -> Int? {
        guard let seedID else { return nil }
        var descriptor = FetchDescriptor<LocalSeed>(
            predicate: #Predicate { seed in seed.id == seedID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?
            .growingInfo?.days_to_maturity_max
    }

    /// Sibling planting set per spec: same bed OR same seed, excluding
    /// self, excluding soft-deleted. For each sibling, take
    /// `max(sibling.updatedAt, latestJournalEntry(sibling).createdAt)`.
    /// Nil if no siblings (mood engine treats nil as neutral 60).
    private static func latestSiblingActivityMs(
        event: LocalPlantingEvent,
        context: ModelContext
    ) -> Int64? {
        let selfID = event.id
        let bedID = event.bedID
        let seedID = event.seedID

        // SwiftData's #Predicate doesn't compose disjunctions cleanly
        // across optionals, so run two narrower fetches and merge.
        var siblings: [LocalPlantingEvent] = []

        if let bedID {
            let descriptor = FetchDescriptor<LocalPlantingEvent>(
                predicate: #Predicate { sibling in
                    sibling.bedID == bedID
                        && sibling.id != selfID
                        && sibling.deletedAt == nil
                }
            )
            if let rows = try? context.fetch(descriptor) {
                siblings.append(contentsOf: rows)
            }
        }

        if let seedID {
            let descriptor = FetchDescriptor<LocalPlantingEvent>(
                predicate: #Predicate { sibling in
                    sibling.seedID == seedID
                        && sibling.id != selfID
                        && sibling.deletedAt == nil
                }
            )
            if let rows = try? context.fetch(descriptor) {
                siblings.append(contentsOf: rows)
            }
        }

        // Dedupe by id (a sibling might match on both bed and seed).
        var seenIDs = Set<String>()
        let unique = siblings.filter { seenIDs.insert($0.id).inserted }
        guard !unique.isEmpty else { return nil }

        var bestMs: Int64 = .min
        for sibling in unique {
            var candidate = sibling.updatedAt
            if let entryMs = latestJournalEntryMs(
                plantingEventID: sibling.id,
                context: context
            ) {
                candidate = max(candidate, entryMs)
            }
            bestMs = max(bestMs, candidate)
        }
        return bestMs == .min ? nil : bestMs
    }

    // MARK: - Time helpers

    /// Whole days between two epoch-ms timestamps, floored to 0. Uses
    /// the Gregorian calendar in the device's current timezone so day
    /// boundaries match the household's local calendar.
    private static func days(between earlierMs: Int64, and laterMs: Int64) -> Int {
        let earlier = Date(timeIntervalSince1970: TimeInterval(earlierMs) / 1000)
        let later = Date(timeIntervalSince1970: TimeInterval(laterMs) / 1000)
        let cal = Calendar.current
        let earlierDay = cal.startOfDay(for: earlier)
        let laterDay = cal.startOfDay(for: later)
        let components = cal.dateComponents([.day], from: earlierDay, to: laterDay)
        return max(0, components.day ?? 0)
    }
}
