import Foundation
import SwiftData

/// Memoizes the Journal work that does not change per keystroke, so the feed is not rebuilt on every
/// render. Owned by a view with `@State`.
///
/// - The entity index, with its sorted menu options, is built once per change to the household's
///   seeds, beds or plantings. Changes are detected by a hash over the fields the labels and the
///   relation read, plus `updatedAt`.
/// - Each entry's folded body is kept per entry ID, and reused while the entry's `updatedAt` is
///   unchanged.
final class JournalFeedCache {
    /// How many times the entity index has been built. Tests use it to check the memo.
    private(set) var indexBuildCount = 0

    private var indexKey: Int?
    private var index: JournalEntityIndex?
    private var foldedBodies: [String: FoldedBody] = [:]

    private struct FoldedBody {
        let updatedAt: Int64
        let text: String
    }

    /// The entity index for the household's current seeds, beds and plantings. Reuses the last one
    /// while those are unchanged.
    func entityIndex(
        householdID: String?,
        seeds: [LocalSeed],
        beds: [LocalBed],
        plantings: [LocalPlantingEvent]
    ) -> JournalEntityIndex {
        let key = Self.key(householdID: householdID, seeds: seeds, beds: beds, plantings: plantings)
        if let index, key == indexKey {
            return index
        }
        let built = JournalEntityIndex(householdID: householdID, seeds: seeds, beds: beds, plantings: plantings)
        indexBuildCount += 1
        indexKey = key
        index = built
        return built
    }

    /// The feed for the criteria, using the memoized index and folded bodies.
    func feed(
        householdID: String?,
        entries: [LocalJournalEntry],
        seeds: [LocalSeed],
        beds: [LocalBed],
        plantings: [LocalPlantingEvent],
        criteria: JournalCriteria
    ) -> JournalFeed {
        let index = entityIndex(householdID: householdID, seeds: seeds, beds: beds, plantings: plantings)
        pruneFoldedBodies(keeping: entries)
        return JournalFeed(
            householdID: householdID,
            entries: entries,
            index: index,
            criteria: criteria,
            foldedBody: { self.foldedBody(for: $0) })
    }

    private func foldedBody(for entry: LocalJournalEntry) -> String {
        if let hit = foldedBodies[entry.id], hit.updatedAt == entry.updatedAt {
            return hit.text
        }
        let text = JournalFilter.fold(entry.body)
        foldedBodies[entry.id] = FoldedBody(updatedAt: entry.updatedAt, text: text)
        return text
    }

    /// Drops folded bodies for entries that are gone, once the cache has clearly outgrown the feed.
    private func pruneFoldedBodies(keeping entries: [LocalJournalEntry]) {
        guard foldedBodies.count > 2 * entries.count + 64 else { return }
        let live = Set(entries.map(\.id))
        foldedBodies = foldedBodies.filter { live.contains($0.key) }
    }

    private static func key(
        householdID: String?,
        seeds: [LocalSeed],
        beds: [LocalBed],
        plantings: [LocalPlantingEvent]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(householdID)
        for seed in seeds {
            hasher.combine(seed.id)
            hasher.combine(seed.householdID)
            hasher.combine(seed.customName)
            hasher.combine(seed.deletedAt)
            hasher.combine(seed.updatedAt)
        }
        for bed in beds {
            hasher.combine(bed.id)
            hasher.combine(bed.householdID)
            hasher.combine(bed.name)
            hasher.combine(bed.sortOrder)
            hasher.combine(bed.deletedAt)
            hasher.combine(bed.updatedAt)
        }
        for event in plantings {
            hasher.combine(event.id)
            hasher.combine(event.householdID)
            hasher.combine(event.bedID)
            hasher.combine(event.seedID)
            hasher.combine(event.kindRaw)
            hasher.combine(event.plannedFor)
            hasher.combine(event.deletedAt)
            hasher.combine(event.updatedAt)
        }
        return hasher.finalize()
    }
}
