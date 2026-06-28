#if canImport(CloudKit)
import Foundation
import SwiftData
import SeedkeepKit
import SeedkeepCloudKit

// R1 live-engine wiring — the SwiftData-projection gate around the (already host-tested,
// untouched) `HouseholdRecordApplier`. Two responsibilities the applier deliberately doesn't own:
//
//  1. updatedAt-LWW guard (`shouldApply`): the engine's field-merger reconciles CKRecords, but
//     SwiftData is a SEPARATE store rehydrated from the server each launch. A fetched remote must
//     not clobber a STRICTLY-newer un-pushed local edit; if it would, we skip the projection and
//     let the next `pushDirty` push the local record (which then field-merges at serverRecordChanged
//     and converges). Apply when remote.updatedAt >= local.updatedAt (or the record is new / has no
//     clock). Types without an `updatedAt` clock (SeedPhoto) always apply (content keyed by id).
//
//  2. Hard-delete projection (`deleteLocal`): a CloudKit record DELETION (the G5 cascade sweep) is
//     unambiguous — the row is gone from the zone — so the local model is hard-deleted. (Normal
//     Seedkeep deletes are SOFT — a tombstone save, handled by the applier's deletedAt path — not
//     a CloudKit deletion.)
@MainActor
enum HouseholdApplyGate {

    /// True if the decoded remote should be projected into SwiftData (remote newer-or-equal, or a
    /// new/clock-less record); false to preserve a strictly-newer local edit (LWW).
    static func shouldApply(_ value: CloudKitRecordValue, into context: ModelContext) -> Bool {
        guard let incoming = value.scalars["updatedAt"]?.asInt64 else { return true }
        guard let existing = existingUpdatedAt(value, into: context) else { return true }
        return incoming >= existing
    }

    /// Hard-delete the local model addressed by a fetched CloudKit deletion `recordName`
    /// ("seed:s1" → LocalSeed id "s1"). Infrastructure records (household/migrated) are ignored.
    static func deleteLocal(recordName: String, into context: ModelContext) {
        guard let slug = recordName.split(separator: ":", maxSplits: 1).first.map(String.init),
              let type = SeedkeepRecordType(rawValue: slug) else { return }
        let id = SeedkeepRecordNames.rawID(recordName)
        switch type {
        case .seed:                 delete(LocalSeed.self, id, context)
        case .location:             delete(LocalLocation.self, id, context)
        case .tag:                  delete(LocalTag.self, id, context)
        case .seedPhoto:            delete(LocalSeedPhoto.self, id, context)
        case .bed:                  delete(LocalBed.self, id, context)
        case .plantingEvent:        delete(LocalPlantingEvent.self, id, context)
        case .journalEntry:         delete(LocalJournalEntry.self, id, context)
        case .journalEntryPhoto:    delete(LocalJournalEntryPhoto.self, id, context)
        case .journalChecklistItem: delete(LocalJournalChecklistItem.self, id, context)
        case .petDeparture:
            // Keyed on plantingEventID (recordName "petDeparture:<plantingEventID>").
            if let m = first(context, FetchDescriptor<LocalPetDeparture>(
                predicate: #Predicate { $0.plantingEventID == id })) {
                context.delete(m)
            }
        case .household, .migrationReceipt:
            break   // infrastructure — never mirrored as a SwiftData row
        }
    }

    // MARK: - Helpers

    private static func first<T: PersistentModel>(_ context: ModelContext, _ d: FetchDescriptor<T>) -> T? {
        (try? context.fetch(d))?.first
    }

    private static func delete<T: PersistentModel>(_ type: T.Type, _ id: String, _ context: ModelContext)
    where T: HouseholdDeletable {
        if let m = first(context, FetchDescriptor<T>(predicate: T.idPredicate(id))) { context.delete(m) }
    }

    /// The existing local model's merge clock, or nil if absent / clock-less (→ always apply).
    private static func existingUpdatedAt(_ value: CloudKitRecordValue, into context: ModelContext) -> Int64? {
        let id = SeedkeepRecordNames.rawID(value.recordName)
        switch value.type {
        case .seed:                 return first(context, FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id }))?.updatedAt
        case .location:             return first(context, FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.id == id }))?.updatedAt
        case .tag:                  return first(context, FetchDescriptor<LocalTag>(predicate: #Predicate { $0.id == id }))?.updatedAt
        case .bed:                  return first(context, FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == id }))?.updatedAt
        case .plantingEvent:        return first(context, FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id }))?.updatedAt
        case .journalEntry:         return first(context, FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id }))?.updatedAt
        case .journalEntryPhoto:    return first(context, FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.id == id }))?.updatedAt
        case .journalChecklistItem: return first(context, FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == id }))?.updatedAt
        case .petDeparture:         return first(context, FetchDescriptor<LocalPetDeparture>(predicate: #Predicate { $0.plantingEventID == id }))?.updatedAt
        case .seedPhoto, .household, .migrationReceipt:
            return nil   // no merge clock → always apply
        }
    }
}

/// Lets `deleteLocal` look a model up by id generically. Conformances are 1-line; the predicate
/// closure keeps the `id` comparison inside the macro context SwiftData requires.
protocol HouseholdDeletable: PersistentModel {
    static func idPredicate(_ id: String) -> Predicate<Self>
}
extension LocalSeed: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalSeed> { #Predicate { $0.id == id } } }
extension LocalLocation: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalLocation> { #Predicate { $0.id == id } } }
extension LocalTag: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalTag> { #Predicate { $0.id == id } } }
extension LocalSeedPhoto: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalSeedPhoto> { #Predicate { $0.id == id } } }
extension LocalBed: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalBed> { #Predicate { $0.id == id } } }
extension LocalPlantingEvent: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalPlantingEvent> { #Predicate { $0.id == id } } }
extension LocalJournalEntry: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalJournalEntry> { #Predicate { $0.id == id } } }
extension LocalJournalEntryPhoto: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalJournalEntryPhoto> { #Predicate { $0.id == id } } }
extension LocalJournalChecklistItem: HouseholdDeletable { static func idPredicate(_ id: String) -> Predicate<LocalJournalChecklistItem> { #Predicate { $0.id == id } } }
#endif
