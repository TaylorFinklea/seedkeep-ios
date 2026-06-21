import Foundation
import SeedkeepCloudKit

// R1 — forward migration adapters: each SwiftData `Local*` model → the `CloudKitRecordValue` the
// codec encodes into a CKRecord. Thin 1:1 passthroughs over the host-tested `SeedkeepRecordValues`
// builders (which own the field-mapping conventions: ref prefix/raw, optional-drop, Int64→Int,
// Bool→.bool, householdID omitted). The one-time household export plans over these.

extension LocalSeed {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.seed(
            id: id, customName: customName, customVariety: customVariety, customCompany: customCompany,
            customType: customType, notes: notes, stateRaw: stateRaw, sourceRaw: sourceRaw,
            packetCount: packetCount, yearPacked: yearPacked, tagIDsJSON: tagIDsJSON,
            growingInfoJSON: growingInfoJSON, catalogID: catalogID, locationID: locationID,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

extension LocalLocation {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.location(
            id: id, name: name, sortOrder: sortOrder,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

extension LocalTag {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.tag(
            id: id, name: name, color: color,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

extension LocalSeedPhoto {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.seedPhoto(
            id: id, seedID: seedID, r2Key: r2Key, roleRaw: roleRaw,
            width: width, height: height, byteSize: byteSize, capturedAt: capturedAt)
    }
}

extension LocalBed {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.bed(
            id: id, name: name, bedDescription: bedDescription, widthFeet: widthFeet,
            lengthFeet: lengthFeet, sortOrder: sortOrder,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

extension LocalPlantingEvent {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.plantingEvent(
            id: id, bedID: bedID, seedID: seedID, catalogSeedID: catalogSeedID,
            kindRaw: kindRaw, plannedFor: plannedFor, completedAt: completedAt, notes: notes,
            xFeet: xFeet, yFeet: yFeet, createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt,
            petSeed: petSeed, petRarity: petRarity, petCreatureKind: petCreatureKind, petName: petName,
            petPersonalityJSON: petPersonalityJSON, petSpawnedAt: petSpawnedAt)
        // petWiltedStreakDays + petLastMoodTickAt are intentionally NOT passed (iOS-local, never sync).
    }
}

extension LocalJournalEntry {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.journalEntry(
            id: id, occurredOn: occurredOn, body: body,
            seedID: seedID, bedID: bedID, plantingEventID: plantingEventID,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

extension LocalJournalEntryPhoto {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.journalEntryPhoto(
            id: id, entryID: entryID, storageKey: storageKey, sortOrder: sortOrder,
            width: width, height: height, createdAt: createdAt, updatedAt: updatedAt)
    }
}

extension LocalJournalChecklistItem {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.journalChecklistItem(
            id: id, entryID: entryID, text: text, completed: completed,
            sortOrder: sortOrder, updatedAt: updatedAt)
    }
}

extension LocalPetDeparture {
    var cloudKitValue: CloudKitRecordValue {
        SeedkeepRecordValues.petDeparture(
            plantingEventID: plantingEventID, goodbyeNoteJSON: goodbyeNoteJSON, reason: reason,
            fallback: fallback, createdAt: createdAt, updatedAt: updatedAt,
            departedAt: departedAt, deletedAt: deletedAt)
    }
}
