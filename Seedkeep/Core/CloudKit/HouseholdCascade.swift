#if canImport(CloudKit)
import Foundation
import SwiftData

// R1 live-engine wiring — client-side soft-delete CASCADE parity (spec gotcha G5). The server does
// this cascade on DELETE today (grep-verified: seeds.ts:459-466, beds.ts:224-231,
// planting-events.ts:471-474); CloudKit has no server, so the deleting device must cascade itself or
// peers see PlantingEvents / JournalEntries that still reference a tombstoned Seed/Bed/PlantingEvent.
//
// Rules mirrored exactly:
//   - a soft-deleted Seed → soft-delete its PlantingEvents (seed_id) + JournalEntries (seed_id)
//   - a soft-deleted Bed  → soft-delete its PlantingEvents (bed_id)  + JournalEntries (bed_id)
//   - a soft-deleted PlantingEvent → soft-delete its JournalEntries (planting_event_id)
// The cascaded children get a bumped `updatedAt` so the coordinator's pushDirty propagates the
// tombstones; the merger's universal sticky-`deletedAt` makes them converge even against a concurrent
// peer edit. Idempotent — acts only on not-yet-deleted children. Runs each sync (also catches a peer's
// fetched parent tombstone, cascading it into local children).
//
// DEFERRED (lower-harm, see the 2026-06-28 spec): SeedPhoto hard-delete on Seed delete (a dangling
// photo of a tombstoned seed), Location null-out on Location delete (dangling soft-ref), and Tag
// removal on Tag delete (already an acknowledged set-union add-only limitation).
@MainActor
enum HouseholdCascade {

    /// Apply the soft-delete cascade in `context`, stamping cascaded children with `now`. Saves the
    /// context and returns true iff anything was newly soft-deleted. Throws on save failure so the
    /// coordinator surfaces it (mirrors the other coordinator stages) rather than silently dropping
    /// the pass's tombstones.
    @discardableResult
    static func apply(in context: ModelContext, now: Int64) throws -> Bool {
        let deletedSeedIDs = Set(fetch(context, FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.deletedAt != nil })).map(\.id))
        let deletedBedIDs  = Set(fetch(context, FetchDescriptor<LocalBed>(predicate: #Predicate { $0.deletedAt != nil })).map(\.id))
        var deletedPEIDs   = Set(fetch(context, FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.deletedAt != nil })).map(\.id))
        var changed = false

        for pe in fetch(context, FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.deletedAt == nil })) {
            let bySeed = pe.seedID.map(deletedSeedIDs.contains) ?? false
            let byBed  = pe.bedID.map(deletedBedIDs.contains) ?? false
            if bySeed || byBed {
                pe.deletedAt = now
                pe.updatedAt = now
                deletedPEIDs.insert(pe.id)
                changed = true
            }
        }

        for je in fetch(context, FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.deletedAt == nil })) {
            let bySeed = je.seedID.map(deletedSeedIDs.contains) ?? false
            let byBed  = je.bedID.map(deletedBedIDs.contains) ?? false
            let byPE   = je.plantingEventID.map(deletedPEIDs.contains) ?? false
            if bySeed || byBed || byPE {
                je.deletedAt = now
                je.updatedAt = now
                changed = true
            }
        }

        if changed { try context.save() }
        return changed
    }

    private static func fetch<T: PersistentModel>(_ context: ModelContext, _ d: FetchDescriptor<T>) -> [T] {
        (try? context.fetch(d)) ?? []
    }
}
#endif
