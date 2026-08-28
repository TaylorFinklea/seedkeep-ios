import Foundation

// Migration forward-mapping: a Local* SwiftData row's primitive field values → the
// CloudKitRecordValue the codec encodes into a CKRecord. Pure + host-testable (no SwiftData,
// no CloudKit). The app's one-time upgrade migration calls these with `local.<property>` values.
//
// Two conventions every per-type builder honors (centralised in `recordValue` so they can't drift):
//   1. References carry the RAW legacy id; `recordValue` derives the on-wire form from the
//      manifest's RefSpec.kind — in-zone refs (cascadeParent/.deleteSelf, setNullInZone/.none)
//      become the TARGET's prefixed recordName ("location:<id>"); cross-DB refs stay the raw
//      external id ("<catalogID>"). This is the migration's #1 correctness hazard, handled once.
//   2. Absent optionals are OMITTED (the CloudKit field/ref stays null). Builders pass dicts
//      through `scalars(_:)` / `refIDs(_:)`, which drop nils.
//
// Timestamps: the SwiftData models store Int64 unix-millis; ScalarValue.int is 64-bit Int on
// every Apple target, so `Int(int64Value)` is lossless.

public enum SeedkeepRecordValues {

    // MARK: - Generic manifest-driven assembly

    /// Build a record value for `type` from a legacy `id` plus typed scalars and raw ref ids.
    /// `refIDs` keys are ref-field names; values are RAW target ids (NOT prefixed) — in-zone
    /// refs get prefixed here from the manifest, cross-DB refs are passed through unchanged.
    public static func recordValue(
        type: SeedkeepRecordType,
        id: String,
        scalars: [String: ScalarValue],
        refIDs: [String: String] = [:]
    ) -> CloudKitRecordValue {
        let specsByName = Dictionary(uniqueKeysWithValues: type.refs.map { ($0.name, $0) })
        var refs: [String: String] = [:]
        for (name, rawID) in refIDs {
            guard let spec = specsByName[name] else { continue }   // ignore unknown ref fields
            switch spec.kind {
            case .crossDBString:
                refs[name] = rawID                                  // raw external id (no prefix)
            case .setNullInZone, .cascadeParent:
                refs[name] = inZoneRecordName(targetType: spec.target, id: rawID)   // prefixed
            }
        }
        return CloudKitRecordValue(
            type: type,
            recordName: SeedkeepRecordNames.recordName(for: type, id: id),
            scalars: scalars,
            refs: refs)
    }

    /// Prefixed recordName for an in-zone ref target. `targetType` is the manifest's PascalCase
    /// recordTypeName (e.g. "Location"); resolve it to the slug via the manifest so the prefix
    /// always matches the target's own recordName builder.
    static func inZoneRecordName(targetType: String, id: String) -> String {
        if let t = SeedkeepRecordType.allCases.first(where: { $0.recordTypeName == targetType }) {
            return SeedkeepRecordNames.recordName(for: t, id: id)
        }
        // Unreachable for the declared in-zone targets; lower-camel fallback keeps it total.
        return "\(targetType.prefix(1).lowercased() + targetType.dropFirst()):\(id)"
    }

    // MARK: - Optional-dropping dict helpers

    /// Build a scalars dict, omitting keys whose value is nil (absent optional → null field).
    public static func scalars(_ pairs: [String: ScalarValue?]) -> [String: ScalarValue] {
        pairs.compactMapValues { $0 }
    }

    /// Build a refIDs dict, omitting keys whose raw id is nil (absent ref → null).
    public static func refIDs(_ pairs: [String: String?]) -> [String: String] {
        pairs.compactMapValues { $0 }
    }

    // MARK: - Per-type builders
    //
    // Each maps one Local* model's fields to a record value. REFERENCE PATTERN — every other
    // builder mirrors this one: typed scalars (right ScalarValue case per manifest field type;
    // Bool→.bool, Int64→.int), optionals dropped, refs passed RAW (locationID, catalogID),
    // householdID intentionally absent (the zone is the household).

    /// LocalSeed → Seed. Custom-merged (packetCount-min, tagIDs-union, deletedAt-sticky).
    /// NOTE: `tagIDsJSON` is LocalSeed's storage column; it maps to the CloudKit field "tagIDs".
    /// `catalogID` is a cross-DB ref (raw); `locationID` is an in-zone setNull ref (gets prefixed).
    public static func seed(
        id: String,
        customName: String?,
        customVariety: String?,
        customCompany: String?,
        customType: String?,
        notes: String?,
        stateRaw: String,
        sourceRaw: String,
        packetCount: Int,
        yearPacked: Int?,
        tagIDsJSON: String,
        growingInfoJSON: String?,
        catalogID: String?,
        locationID: String?,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64?
    ) -> CloudKitRecordValue {
        recordValue(
            type: .seed,
            id: id,
            scalars: scalars([
                "customName":      customName.map(ScalarValue.string),
                "customVariety":   customVariety.map(ScalarValue.string),
                "customCompany":   customCompany.map(ScalarValue.string),
                "customType":      customType.map(ScalarValue.string),
                "notes":           notes.map(ScalarValue.string),
                "stateRaw":        .string(stateRaw),
                "sourceRaw":       .string(sourceRaw),
                "packetCount":     .int(packetCount),
                "yearPacked":      yearPacked.map(ScalarValue.int),
                "tagIDs":          .string(tagIDsJSON),
                "growingInfoJSON": growingInfoJSON.map(ScalarValue.string),
                "createdAt":       .int(Int(createdAt)),
                "updatedAt":       .int(Int(updatedAt)),
                "deletedAt":       deletedAt.map { ScalarValue.int(Int($0)) },
            ]),
            refIDs: refIDs([
                "locationID": locationID,   // in-zone setNull → "location:<id>"
                "catalogID":  catalogID,    // cross-DB → raw id
            ]))
    }

    /// The Household root record (the CKShare anchor). No Local* model — built from the
    /// household's id + name during migration. No deletedAt (deleting a household = deleting the zone).
    public static func household(id: String, name: String, createdAt: Int64, updatedAt: Int64) -> CloudKitRecordValue {
        recordValue(type: .household, id: id, scalars: scalars([
            "name":      .string(name),
            "createdAt": .int(Int(createdAt)),
            "updatedAt": .int(Int(updatedAt)),
        ]))
    }

    /// LocalLocation → Location (seed storage location; no refs).
    public static func location(id: String, name: String, sortOrder: Int, createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) -> CloudKitRecordValue {
        recordValue(type: .location, id: id, scalars: scalars([
            "name":      .string(name),
            "sortOrder": .int(sortOrder),
            "createdAt": .int(Int(createdAt)),
            "updatedAt": .int(Int(updatedAt)),
            "deletedAt": deletedAt.map { ScalarValue.int(Int($0)) },
        ]))
    }

    /// LocalTag → Tag (no refs).
    public static func tag(id: String, name: String, color: String?, createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) -> CloudKitRecordValue {
        recordValue(type: .tag, id: id, scalars: scalars([
            "name":      .string(name),
            "color":     color.map(ScalarValue.string),
            "createdAt": .int(Int(createdAt)),
            "updatedAt": .int(Int(updatedAt)),
            "deletedAt": deletedAt.map { ScalarValue.int(Int($0)) },
        ]))
    }

    /// LocalBed → Bed (no refs).
    public static func bed(id: String, name: String, bedDescription: String?, widthFeet: Double?, lengthFeet: Double?, sortOrder: Int, createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) -> CloudKitRecordValue {
        recordValue(type: .bed, id: id, scalars: scalars([
            "name":           .string(name),
            "bedDescription": bedDescription.map(ScalarValue.string),
            "widthFeet":      widthFeet.map(ScalarValue.double),
            "lengthFeet":     lengthFeet.map(ScalarValue.double),
            "sortOrder":      .int(sortOrder),
            "createdAt":      .int(Int(createdAt)),
            "updatedAt":      .int(Int(updatedAt)),
            "deletedAt":      deletedAt.map { ScalarValue.int(Int($0)) },
        ]))
    }

    /// LocalPlantingEvent → PlantingEvent. Carries the synced pet-identity fields; EXCLUDES the
    /// iOS-local streak counters. Refs: bedID/seedID in-zone (setNull); catalogSeedID cross-DB.
    public static func plantingEvent(
        id: String, bedID: String?, seedID: String?, catalogSeedID: String?,
        kindRaw: String, plannedFor: String, completedAt: Int64?, notes: String?,
        xFeet: Double?, yFeet: Double?, createdAt: Int64, updatedAt: Int64, deletedAt: Int64?,
        petSeed: String?, petRarity: String?, petCreatureKind: String?, petName: String?,
        petPersonalityJSON: String?, petSpawnedAt: Int64?
    ) -> CloudKitRecordValue {
        recordValue(type: .plantingEvent, id: id,
            scalars: scalars([
                "kindRaw":            .string(kindRaw),
                "plannedFor":         .string(plannedFor),
                "completedAt":        completedAt.map { ScalarValue.int(Int($0)) },
                "notes":              notes.map(ScalarValue.string),
                "xFeet":              xFeet.map(ScalarValue.double),
                "yFeet":              yFeet.map(ScalarValue.double),
                "createdAt":          .int(Int(createdAt)),
                "updatedAt":          .int(Int(updatedAt)),
                "deletedAt":          deletedAt.map { ScalarValue.int(Int($0)) },
                "petSeed":            petSeed.map(ScalarValue.string),
                "petRarity":          petRarity.map(ScalarValue.string),
                "petCreatureKind":    petCreatureKind.map(ScalarValue.string),
                "petName":            petName.map(ScalarValue.string),
                "petPersonalityJSON": petPersonalityJSON.map(ScalarValue.string),
                "petSpawnedAt":       petSpawnedAt.map { ScalarValue.int(Int($0)) },
            ]),
            refIDs: refIDs([
                "bedID":         bedID,
                "seedID":        seedID,
                "catalogSeedID": catalogSeedID,
            ]))
    }

    /// LocalPetDeparture → PetDeparture. The record id IS the plantingEventID, AND the
    /// cascadeParent ref targets the parent planting — both use plantingEventID.
    public static func petDeparture(
        plantingEventID: String, goodbyeNoteJSON: String?, reason: String, fallback: Bool,
        createdAt: Int64, updatedAt: Int64, departedAt: Int64, deletedAt: Int64?
    ) -> CloudKitRecordValue {
        recordValue(type: .petDeparture, id: plantingEventID,
            scalars: scalars([
                "goodbyeNoteJSON": goodbyeNoteJSON.map(ScalarValue.string),
                "reason":          .string(reason),
                "fallback":        .bool(fallback),
                "createdAt":       .int(Int(createdAt)),
                "updatedAt":       .int(Int(updatedAt)),
                "departedAt":      .int(Int(departedAt)),
                "deletedAt":       deletedAt.map { ScalarValue.int(Int($0)) },
            ]),
            refIDs: refIDs([
                "plantingEventID": plantingEventID,   // cascadeParent → "plantingEvent:<id>"
            ]))
    }

    /// LocalJournalEntry → JournalEntry. At-most-one parent; all three FKs are in-zone setNull refs.
    public static func journalEntry(id: String, occurredOn: String, body: String, seedID: String?, bedID: String?, plantingEventID: String?, createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) -> CloudKitRecordValue {
        recordValue(type: .journalEntry, id: id,
            scalars: scalars([
                "occurredOn": .string(occurredOn),
                "body":       .string(body),
                "createdAt":  .int(Int(createdAt)),
                "updatedAt":  .int(Int(updatedAt)),
                "deletedAt":  deletedAt.map { ScalarValue.int(Int($0)) },
            ]),
            refIDs: refIDs([
                "seedID":          seedID,
                "bedID":           bedID,
                "plantingEventID": plantingEventID,
            ]))
    }

    /// LocalJournalEntryPhoto → JournalEntryPhoto. cascadeParent ref → JournalEntry.
    public static func journalEntryPhoto(id: String, entryID: String, storageKey: String?, sortOrder: Int, width: Int?, height: Int?, createdAt: Int64, updatedAt: Int64) -> CloudKitRecordValue {
        recordValue(type: .journalEntryPhoto, id: id,
            scalars: scalars([
                "storageKey": storageKey.map(ScalarValue.string),
                "sortOrder":  .int(sortOrder),
                "width":      width.map(ScalarValue.int),
                "height":     height.map(ScalarValue.int),
                "createdAt":  .int(Int(createdAt)),
                "updatedAt":  .int(Int(updatedAt)),
            ]),
            refIDs: refIDs(["entryID": entryID]))
    }

    /// LocalSeedPhoto → SeedPhoto. Immutable; cascadeParent ref → Seed.
    public static func seedPhoto(id: String, seedID: String, r2Key: String?, roleRaw: String, width: Int?, height: Int?, byteSize: Int?, capturedAt: Int64) -> CloudKitRecordValue {
        recordValue(type: .seedPhoto, id: id,
            scalars: scalars([
                "r2Key":      r2Key.map(ScalarValue.string),
                "roleRaw":    .string(roleRaw),
                "width":      width.map(ScalarValue.int),
                "height":     height.map(ScalarValue.int),
                "byteSize":   byteSize.map(ScalarValue.int),
                "capturedAt": .int(Int(capturedAt)),
            ]),
            refIDs: refIDs(["seedID": seedID]))
    }

    /// LocalJournalChecklistItem → JournalChecklistItem. Custom (completed,updatedAt) pair merge;
    /// cascadeParent ref → JournalEntry.
    public static func journalChecklistItem(id: String, entryID: String, text: String, completed: Bool, sortOrder: Int, updatedAt: Int64) -> CloudKitRecordValue {
        recordValue(type: .journalChecklistItem, id: id,
            scalars: scalars([
                "text":      .string(text),
                "completed": .bool(completed),
                "sortOrder": .int(sortOrder),
                "updatedAt": .int(Int(updatedAt)),
            ]),
            refIDs: refIDs(["entryID": entryID]))
    }

    /// The migration idempotency receipt (G12). id == householdID; recordName "migrated:<id>".
    public static func migrationReceipt(householdID: String, completedAt: Int64, schemaVersion: Int) -> CloudKitRecordValue {
        recordValue(type: .migrationReceipt, id: householdID, scalars: scalars([
            "completedAt":   .int(Int(completedAt)),
            "schemaVersion": .int(schemaVersion),
        ]))
    }
}
