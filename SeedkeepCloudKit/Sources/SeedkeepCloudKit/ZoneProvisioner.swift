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
public struct SeedkeepZoneProvisioner: Sendable {
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

    /// The private-database zone ID of a household's garden. Pure: nothing is sent to CloudKit.
    public static func zoneID(householdID: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName(householdID: householdID), ownerName: CKCurrentUserDefaultName)
    }

    /// Idempotent: saving an existing zone is a no-op success.
    ///
    /// N2-E: a garden zone is created only through a creation grant (`createGarden`). This stays
    /// for the DEBUG spike checks (`seedkeep-spike-*` zones, which are not gardens). No garden path
    /// calls it: `fetchHousehold`, share preparation and the sync engine all leave the zone alone.
    @discardableResult
    public func ensureZone(householdID: String) async throws -> CKRecordZone {
        let zone = CKRecordZone(zoneID: Self.zoneID(householdID: householdID))
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
        return zone
    }

    /// Fetches the `Household` root record (recordName = `household:<householdID>`), which is also
    /// the CKShare root.
    ///
    /// N2-E: this never creates anything. A root that is confirmed missing in an existing zone means
    /// the garden is gone (or was never completed), and a missing zone throws `zoneNotFound`: neither
    /// is brought back by a start-up that merely wants its root. Only a creation candidate with a
    /// grant saves a root, through `createGarden`.
    public func fetchHousehold(householdID: String) async throws -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: SeedkeepRecordNames.household(householdID),
            zoneID: Self.zoneID(householdID: householdID))
        return try await Self.fetchRoot(recordID) { try await container.privateCloudDatabase.record(for: $0) }
    }

    /// The fetch-only read behind `fetchHousehold`. There is no save parameter: a missing root
    /// surfaces as the error it is, and nothing is written.
    public static func fetchRoot(
        _ recordID: CKRecord.ID,
        fetch: (CKRecord.ID) async throws -> CKRecord
    ) async throws -> CKRecord {
        try await fetch(recordID)
    }

    /// Reads the root straight from `database` and reports what it found (the batch check's read,
    /// and the start check's). Never creates anything.
    public static func readRoot(
        _ recordID: CKRecord.ID,
        fetch: (CKRecord.ID) async throws -> CKRecord
    ) async -> GardenRootRead {
        do {
            let record = try await fetchRoot(recordID, fetch: fetch)
            return .present(GardenRootSnapshot(record: record))
        } catch {
            return GardenRootRead.classify(error)
        }
    }

    private static func makeRoot(recordID: CKRecord.ID, name: String) -> CKRecord {
        let record = CKRecord(recordType: SeedkeepRecordType.household.recordTypeName, recordID: recordID)
        let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
        record["name"]      = name as CKRecordValue
        record["createdAt"] = nowMillis as CKRecordValue   // INT64 millis (manifest: createdAt .int)
        record["updatedAt"] = nowMillis as CKRecordValue
        return record
    }

    // MARK: - Creation grant (N2-E)

    /// Creates a brand-new garden: the zone, then the `Household` root. Called only for a household
    /// holding a creation grant (`attempting`), never for an existing garden.
    ///
    /// Only a confirmed success counts: the zone save's own per-item result succeeded, and the
    /// root save's per-item result returned a record with a non-nil server `creationDate` (the
    /// garden's generation). The app's own `createdAt` is never substituted.
    ///
    /// A request that was never dispatched (`isUndispatched`) is `.notDispatched`: the grant stays
    /// `pending`. Everything else that is not a confirmed success is `.abandoned`: an error after
    /// dispatch, a per-item failure, a missing result or missing metadata. A failure of the ROOT
    /// request is always `.abandoned`, because the zone request was already dispatched.
    public func createGarden(householdID: String, name: String) async -> GardenCreationOutcome {
        let db = container.privateCloudDatabase
        let zoneID = Self.zoneID(householdID: householdID)
        let zoneSaves: [CKRecordZone.ID: Result<CKRecordZone, Error>]
        do {
            zoneSaves = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []).saveResults
        } catch {
            return GardenCreation.isUndispatched(error) ? .notDispatched(error) : .abandoned(reason: "zone request failed: \(error)")
        }
        switch zoneSaves[zoneID] {
        case .success: break
        case .failure(let error): return .abandoned(reason: "zone save failed: \(error)")
        case nil: return .abandoned(reason: "zone save returned no result")
        }

        let rootID = CKRecord.ID(recordName: SeedkeepRecordNames.household(householdID), zoneID: zoneID)
        let root = Self.makeRoot(recordID: rootID, name: name)
        let rootSaves: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            rootSaves = try await db.modifyRecords(saving: [root], deleting: []).saveResults
        } catch {
            return .abandoned(reason: "root request failed: \(error)")
        }
        switch rootSaves[rootID] {
        case .success(let saved):
            guard let creationDate = saved.creationDate else {
                return .abandoned(reason: "root save returned no creationDate")
            }
            return .created(root: saved, creationDate: creationDate)
        case .failure(let error): return .abandoned(reason: "root save failed: \(error)")
        case nil: return .abandoned(reason: "root save returned no result")
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

/// How a garden creation ended (`SeedkeepZoneProvisioner.createGarden`).
public enum GardenCreationOutcome: @unchecked Sendable {
    /// The zone and the root were saved and confirmed; `creationDate` is the server-returned
    /// root's `creationDate`, the garden's generation.
    case created(root: CKRecord, creationDate: Date)
    /// The request was never dispatched (offline, account unavailable): the grant stays `pending`.
    case notDispatched(Error)
    /// Dispatched, and not confirmed: the ID is abandoned and its rows move to a fresh ID.
    case abandoned(reason: String)
}

/// A garden's root as read: the record and its server `creationDate` (the generation).
public struct GardenRootSnapshot: @unchecked Sendable {
    public let record: CKRecord
    public let creationDate: Date?
    public init(record: CKRecord) {
        self.record = record
        self.creationDate = record.creationDate
    }
    /// For a double of the server: a `CKRecord` built off-device has no `creationDate` to read.
    public init(record: CKRecord, creationDate: Date?) {
        self.record = record
        self.creationDate = creationDate
    }
}

/// What a direct read of a garden's root found. Only `unknownItem` confirms the root absent and
/// only `zoneNotFound`/`userDeletedZone` confirm the zone absent; everything else (timeouts,
/// network, account, service errors) is a failure, never "gone".
public enum GardenRootRead: Sendable {
    case present(GardenRootSnapshot)
    case zoneMissing
    case rootMissing
    case failed(GardenCheckFailure)

    public static func classify(_ error: Error) -> GardenRootRead {
        if error is CancellationError { return .failed(.timedOut) }
        guard let ck = error as? CKError else { return .failed(.unavailable) }
        switch ck.code {
        case .unknownItem: return .rootMissing
        case .zoneNotFound, .userDeletedZone: return .zoneMissing
        default: return .failed(.cloudKit(ck.code.rawValue))
        }
    }
}

public enum GardenCreation {
    /// Whether a thrown error means CloudKit never received the request. Only these keep a grant
    /// `pending`; `networkFailure` and the like can happen after the server acted, so they abandon.
    public static func isUndispatched(_ error: Error) -> Bool {
        guard let code = (error as? CKError)?.code else { return false }
        return isUndispatched(code: code)
    }

    public static func isUndispatched(code: CKError.Code) -> Bool {
        switch code {
        case .networkUnavailable, .notAuthenticated, .accountTemporarilyUnavailable:
            return true
        default:
            return false
        }
    }
}
#endif
