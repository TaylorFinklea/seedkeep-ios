#if canImport(CloudKit)
import CloudKit
import Foundation

/// Seedkeep household zone provisioner.
/// Adapted from SimmerSmith's HouseholdZoneProvisioner with Seedkeep-specific:
///   - Container id: `iCloud.app.seedkeep`
///   - Zone name: `seedkeep-<householdID>` (spec §architecture, G10)
///   - Root record type: `Household` with recordName `household:<householdID>`
///
/// Compiles headlessly; live operations need a signed build + iCloud account (G6).
public struct SeedkeepZoneProvisioner {
    public let container: CKContainer

    public init(containerIdentifier: String = "iCloud.app.seedkeep") {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    /// Deterministic zone name (G10 — two of an owner's devices racing at first launch
    /// converge on ONE zone name from the same householdID → idempotent modifyRecordZones
    /// produces one zone, never a fork).
    public static func zoneName(householdID: String) -> String {
        SeedkeepRecordNames.zoneName(householdID: householdID)
    }

    /// Idempotent: saving an existing zone is a no-op success.
    @discardableResult
    public func ensureZone(householdID: String) async throws -> CKRecordZone {
        let zone = CKRecordZone(
            zoneID: CKRecordZone.ID(
                zoneName: Self.zoneName(householdID: householdID),
                ownerName: CKCurrentUserDefaultName))
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
        return zone
    }

    /// Fetch-or-create the `Household` root record (recordName = `household:<householdID>`).
    /// This is also the CKShare root.
    public func ensureHousehold(householdID: String, name: String) async throws -> CKRecord {
        let db   = container.privateCloudDatabase
        let zone = try await ensureZone(householdID: householdID)
        let recordID = CKRecord.ID(
            recordName: SeedkeepRecordNames.household(householdID),
            zoneID: zone.zoneID)
        do {
            return try await db.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: SeedkeepRecordType.household.recordTypeName,
                                  recordID: recordID)
            let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
            record["name"]      = name as CKRecordValue
            record["createdAt"] = nowMillis as CKRecordValue   // INT64 millis (manifest: createdAt .int)
            record["updatedAt"] = nowMillis as CKRecordValue
            _ = try await db.modifyRecords(saving: [record], deleting: [])
            return record
        }
    }

    /// Day-one CKShare on the Household root (spec locked decision §4 — share-from-birth, G9).
    /// The share is unsurfaced until the user explicitly invites a member.
    public func ensureShare(for householdRecord: CKRecord, title: String) async throws -> CKShare {
        let db = container.privateCloudDatabase
        // IDEMPOTENT (G9 day-one share, called on every launch): `CKShare(rootRecord:)` + save throws
        // serverRecordAlreadyShared once the root is already shared. Reuse the existing share instead.
        let share = CKShare(rootRecord: householdRecord)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        do {
            _ = try await db.modifyRecords(saving: [householdRecord, share], deleting: [])
            return share
        } catch let error as CKError where error.code == .alreadyShared {
            let freshRoot = try await db.record(for: householdRecord.recordID)
            guard let shareRef = freshRoot.share,
                  let existing = try await db.record(for: shareRef.recordID) as? CKShare else { throw error }
            return existing
        }
    }
}
#endif
