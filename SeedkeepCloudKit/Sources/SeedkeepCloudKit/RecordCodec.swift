#if canImport(CloudKit)
import CloudKit
import Foundation

// Mechanical CKRecord ↔ CloudKitRecordValue glue, driven by the SeedkeepRecordType manifest.
// Mirrors SimmerSmith's HouseholdRecordCodec — validated correct and adapted for Seedkeep.
//
// Spike validation note: SimmerSmith's codec encodes Bool→INT64 and handles cascade/setNull/
// crossDBString refs correctly. Seedkeep's spike-subset types use only scalar fields (no
// CKReference refs declared yet — JournalChecklistItem's journalEntryID is a String scalar
// until JournalEntry lands in the full R1 build). The codec handles refs generically anyway.

public enum SeedkeepRecordCodec {

    /// Encode a value into a CKRecord in the given zone.
    /// Reference fields with no target are left absent (= null on CloudKit).
    /// Cross-DB refs encode as plain String keys (G4 — never CKReferences).
    public static func encode(_ value: CloudKitRecordValue, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: value.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: value.type.recordTypeName, recordID: recordID)

        let fieldTypes = Dictionary(uniqueKeysWithValues: value.type.fields.map { ($0.name, $0.type) })
        for (name, scalar) in value.scalars {
            guard fieldTypes[name] != nil else { continue }  // ignore unknown fields
            record[name] = ckValue(for: scalar)
        }

        let refKinds = Dictionary(uniqueKeysWithValues: value.type.refs.map { ($0.name, $0.kind) })
        for (name, target) in value.refs {
            guard let kind = refKinds[name] else { continue }
            switch kind {
            case .crossDBString:
                record[name] = target as CKRecordValue
            case .setNullInZone:
                record[name] = CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: target, zoneID: zoneID), action: .none)
            case .cascadeParent:
                record[name] = CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: target, zoneID: zoneID), action: .deleteSelf)
            }
        }
        return record
    }

    /// Decode a fetched CKRecord back into a CloudKitRecordValue using the manifest.
    public static func decode(_ record: CKRecord, as type: SeedkeepRecordType) -> CloudKitRecordValue {
        var scalars: [String: ScalarValue] = [:]
        for field in type.fields {
            guard let raw = record[field.name] else { continue }
            switch field.type {
            case .string: if let v = raw as? String  { scalars[field.name] = .string(v) }
            case .int:    if let v = raw as? Int     { scalars[field.name] = .int(v) }
            case .double: if let v = raw as? Double  { scalars[field.name] = .double(v) }
            case .date:   if let v = raw as? Date    { scalars[field.name] = .date(v) }
            case .bool:   if let v = raw as? Int     { scalars[field.name] = .bool(v != 0) }
            }
        }
        var refs: [String: String] = [:]
        for ref in type.refs {
            switch ref.kind {
            case .crossDBString:
                if let v = record[ref.name] as? String { refs[ref.name] = v }
            case .setNullInZone, .cascadeParent:
                if let reference = record[ref.name] as? CKRecord.Reference {
                    refs[ref.name] = reference.recordID.recordName
                }
            }
        }
        return CloudKitRecordValue(type: type, recordName: record.recordID.recordName,
                                   scalars: scalars, refs: refs)
    }

    private static func ckValue(for scalar: ScalarValue) -> CKRecordValue {
        switch scalar {
        case .string(let v): return v as CKRecordValue
        case .int(let v):    return v as CKRecordValue
        case .double(let v): return v as CKRecordValue
        case .date(let v):   return v as CKRecordValue
        case .bool(let v):   return (v ? 1 : 0) as CKRecordValue  // G3: Bool → INT64
        }
    }
}
#endif
