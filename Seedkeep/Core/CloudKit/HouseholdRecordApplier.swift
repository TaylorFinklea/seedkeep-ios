import Foundation
import SwiftData
import SeedkeepKit
import SeedkeepCloudKit

// R1 — the reverse mapping (sync read-path): a fetched `CloudKitRecordValue` → upsert into the
// local SwiftData store. The inverse of LocalModelAdapters. Conventions:
//   - the model id is `rawID(recordName)` ("seed:s1" → "s1");
//   - in-zone refs are DEPREFIXED back to the raw id (refs["locationID"] = "location:loc1" → "loc1");
//   - cross-DB refs (catalogID, catalogSeedID) are already raw;
//   - absent scalars clear OPTIONAL model fields (full-record semantics) but use `?? existing` to
//     preserve REQUIRED fields a well-formed record always carries;
//   - new records get `householdID` (the zone IS the household; records don't carry it).
// Host/unit-testable. NOT yet wired into the live engine — the glue (decode CKRecord → apply) lands
// with the engine integration. CONTRACT for that glue: route a fetched record through
// SeedkeepRecordMerger BEFORE the applier whenever a local pending edit exists, so the sticky-
// deletedAt guarantee holds. The applier clears `deletedAt` when a record omits it, which is correct
// ONLY for fully-merged / authoritative server records — never feed it an un-merged conflicting peer.
@MainActor
enum HouseholdRecordApplier {

    static func apply(_ value: CloudKitRecordValue, householdID: String, into context: ModelContext) {
        switch value.type {
        case .seed:                 applySeed(value, householdID: householdID, into: context)
        case .location:             applyLocation(value, householdID: householdID, into: context)
        case .tag:                  applyTag(value, householdID: householdID, into: context)
        case .seedPhoto:            applySeedPhoto(value, householdID: householdID, into: context)
        case .bed:                  applyBed(value, householdID: householdID, into: context)
        case .plantingEvent:        applyPlantingEvent(value, householdID: householdID, into: context)
        case .journalEntry:         applyJournalEntry(value, householdID: householdID, into: context)
        case .journalEntryPhoto:    applyJournalEntryPhoto(value, into: context)
        case .journalChecklistItem: applyChecklistItem(value, into: context)
        case .petDeparture:         applyPetDeparture(value, into: context)
        case .household, .migrationReceipt:
            break   // infrastructure records — not mirrored into SwiftData models
        }
    }

    private static func first<T: PersistentModel>(_ context: ModelContext, _ d: FetchDescriptor<T>) -> T? {
        (try? context.fetch(d))?.first
    }
    private static func deref(_ refs: [String: String], _ name: String) -> String? {
        refs[name].map(SeedkeepRecordNames.rawID)
    }

    // MARK: - Per-type appliers

    private static func applySeed(_ v: CloudKitRecordValue, householdID: String, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalSeed(id: id, householdID: householdID, state: .active, packetCount: 0, source: .store, createdAt: 0, updatedAt: 0); context.insert(s); return s }()
        m.stateRaw       = v.scalars["stateRaw"]?.asString ?? m.stateRaw
        m.sourceRaw      = v.scalars["sourceRaw"]?.asString ?? m.sourceRaw
        m.packetCount    = v.scalars["packetCount"]?.asInt ?? m.packetCount
        m.customName     = v.scalars["customName"]?.asString
        m.customVariety  = v.scalars["customVariety"]?.asString
        m.customCompany  = v.scalars["customCompany"]?.asString
        m.customType     = v.scalars["customType"]?.asString
        m.notes          = v.scalars["notes"]?.asString
        m.yearPacked     = v.scalars["yearPacked"]?.asInt
        m.tagIDsJSON     = v.scalars["tagIDs"]?.asString ?? m.tagIDsJSON
        m.growingInfoJSON = v.scalars["growingInfoJSON"]?.asString
        m.createdAt      = v.scalars["createdAt"]?.asInt64 ?? m.createdAt
        m.updatedAt      = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
        m.deletedAt      = v.scalars["deletedAt"]?.asInt64
        m.locationID     = deref(v.refs, "locationID")     // in-zone → deprefixed
        m.catalogID      = v.refs["catalogID"]             // cross-DB → raw
    }

    private static func applyLocation(_ v: CloudKitRecordValue, householdID: String, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalLocation(id: id, householdID: householdID, name: "", sortOrder: 0, createdAt: 0, updatedAt: 0); context.insert(s); return s }()
        m.name      = v.scalars["name"]?.asString ?? m.name
        m.sortOrder = v.scalars["sortOrder"]?.asInt ?? m.sortOrder
        m.createdAt = v.scalars["createdAt"]?.asInt64 ?? m.createdAt
        m.updatedAt = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
        m.deletedAt = v.scalars["deletedAt"]?.asInt64
    }

    private static func applyTag(_ v: CloudKitRecordValue, householdID: String, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalTag>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalTag(id: id, householdID: householdID, name: "", createdAt: 0, updatedAt: 0); context.insert(s); return s }()
        m.name      = v.scalars["name"]?.asString ?? m.name
        m.color     = v.scalars["color"]?.asString
        m.createdAt = v.scalars["createdAt"]?.asInt64 ?? m.createdAt
        m.updatedAt = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
        m.deletedAt = v.scalars["deletedAt"]?.asInt64
    }

    private static func applySeedPhoto(_ v: CloudKitRecordValue, householdID: String, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalSeedPhoto(id: id, seedID: "", householdID: householdID, r2Key: "", role: .extra, capturedAt: 0); context.insert(s); return s }()
        m.seedID     = deref(v.refs, "seedID") ?? m.seedID
        m.r2Key      = v.scalars["r2Key"]?.asString ?? m.r2Key
        m.roleRaw    = v.scalars["roleRaw"]?.asString ?? m.roleRaw
        m.width      = v.scalars["width"]?.asInt
        m.height     = v.scalars["height"]?.asInt
        m.byteSize   = v.scalars["byteSize"]?.asInt
        m.capturedAt = v.scalars["capturedAt"]?.asInt64 ?? m.capturedAt
    }

    private static func applyBed(_ v: CloudKitRecordValue, householdID: String, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalBed(id: id, householdID: householdID, name: "", createdAt: 0, updatedAt: 0); context.insert(s); return s }()
        m.name           = v.scalars["name"]?.asString ?? m.name
        m.bedDescription = v.scalars["bedDescription"]?.asString
        m.widthFeet      = v.scalars["widthFeet"]?.asDouble
        m.lengthFeet     = v.scalars["lengthFeet"]?.asDouble
        m.sortOrder      = v.scalars["sortOrder"]?.asInt ?? m.sortOrder
        m.createdAt      = v.scalars["createdAt"]?.asInt64 ?? m.createdAt
        m.updatedAt      = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
        m.deletedAt      = v.scalars["deletedAt"]?.asInt64
    }

    private static func applyPlantingEvent(_ v: CloudKitRecordValue, householdID: String, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalPlantingEvent(id: id, householdID: householdID, kindRaw: "", plannedFor: "", createdAt: 0, updatedAt: 0); context.insert(s); return s }()
        m.bedID         = deref(v.refs, "bedID")
        m.seedID        = deref(v.refs, "seedID")
        m.catalogSeedID = v.refs["catalogSeedID"]   // cross-DB → raw
        m.kindRaw       = v.scalars["kindRaw"]?.asString ?? m.kindRaw
        m.plannedFor    = v.scalars["plannedFor"]?.asString ?? m.plannedFor
        m.completedAt   = v.scalars["completedAt"]?.asInt64
        m.notes         = v.scalars["notes"]?.asString
        m.xFeet         = v.scalars["xFeet"]?.asDouble
        m.yFeet         = v.scalars["yFeet"]?.asDouble
        m.createdAt     = v.scalars["createdAt"]?.asInt64 ?? m.createdAt
        m.updatedAt     = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
        m.deletedAt     = v.scalars["deletedAt"]?.asInt64
        m.petSeed            = v.scalars["petSeed"]?.asString
        m.petRarity          = v.scalars["petRarity"]?.asString
        m.petCreatureKind    = v.scalars["petCreatureKind"]?.asString
        m.petName            = v.scalars["petName"]?.asString
        m.petPersonalityJSON = v.scalars["petPersonalityJSON"]?.asString
        m.petSpawnedAt       = v.scalars["petSpawnedAt"]?.asInt64
        // petWiltedStreakDays + petLastMoodTickAt are NEVER synced — left untouched (local-only).
    }

    private static func applyJournalEntry(_ v: CloudKitRecordValue, householdID: String, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalJournalEntry(id: id, householdID: householdID, occurredOn: "", body: "", seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 0, updatedAt: 0, deletedAt: nil); context.insert(s); return s }()
        m.occurredOn      = v.scalars["occurredOn"]?.asString ?? m.occurredOn
        m.body            = v.scalars["body"]?.asString ?? m.body
        m.seedID          = deref(v.refs, "seedID")
        m.bedID           = deref(v.refs, "bedID")
        m.plantingEventID = deref(v.refs, "plantingEventID")
        m.createdAt       = v.scalars["createdAt"]?.asInt64 ?? m.createdAt
        m.updatedAt       = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
        m.deletedAt       = v.scalars["deletedAt"]?.asInt64
    }

    private static func applyJournalEntryPhoto(_ v: CloudKitRecordValue, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalJournalEntryPhoto(id: id, entryID: "", storageKey: "", sortOrder: 0, width: nil, height: nil, createdAt: 0, updatedAt: 0); context.insert(s); return s }()
        m.entryID    = deref(v.refs, "entryID") ?? m.entryID
        m.storageKey = v.scalars["storageKey"]?.asString ?? m.storageKey
        m.sortOrder  = v.scalars["sortOrder"]?.asInt ?? m.sortOrder
        m.width      = v.scalars["width"]?.asInt
        m.height     = v.scalars["height"]?.asInt
        m.createdAt  = v.scalars["createdAt"]?.asInt64 ?? m.createdAt
        m.updatedAt  = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
    }

    private static func applyChecklistItem(_ v: CloudKitRecordValue, into context: ModelContext) {
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == id }))
            ?? { let s = LocalJournalChecklistItem(id: id, entryID: "", text: "", completed: false, sortOrder: 0, updatedAt: 0); context.insert(s); return s }()
        m.entryID   = deref(v.refs, "entryID") ?? m.entryID
        m.text      = v.scalars["text"]?.asString ?? m.text
        m.completed = v.scalars["completed"]?.asBool ?? m.completed
        m.sortOrder = v.scalars["sortOrder"]?.asInt ?? m.sortOrder
        m.updatedAt = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
    }

    private static func applyPetDeparture(_ v: CloudKitRecordValue, into context: ModelContext) {
        // id == plantingEventID (the recordName is "petDeparture:<plantingEventID>").
        let id = SeedkeepRecordNames.rawID(v.recordName)
        let m = first(context, FetchDescriptor<LocalPetDeparture>(predicate: #Predicate { $0.plantingEventID == id }))
            ?? { let s = LocalPetDeparture(plantingEventID: id, reason: "", createdAt: 0, updatedAt: 0, departedAt: 0); context.insert(s); return s }()
        m.goodbyeNoteJSON = v.scalars["goodbyeNoteJSON"]?.asString
        m.reason          = v.scalars["reason"]?.asString ?? m.reason
        m.fallback        = v.scalars["fallback"]?.asBool ?? m.fallback
        m.createdAt       = v.scalars["createdAt"]?.asInt64 ?? m.createdAt
        m.updatedAt       = v.scalars["updatedAt"]?.asInt64 ?? m.updatedAt
        m.departedAt      = v.scalars["departedAt"]?.asInt64 ?? m.departedAt
        m.deletedAt       = v.scalars["deletedAt"]?.asInt64
    }
}
