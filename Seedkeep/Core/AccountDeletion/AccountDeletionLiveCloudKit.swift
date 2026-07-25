import CloudKit
import Foundation
import SeedkeepCloudKit
import SeedkeepKit

/// Pure reduction of the three callback streams emitted by
/// `CKFetchRecordZoneChangesOperation`.
///
/// CloudKit can finish the operation successfully after one record or the
/// requested zone failed. Keeping the streams separate until `finish()` is
/// therefore a safety boundary: no callback is allowed to turn a partial
/// zone snapshot into a page the deletion coordinator can copy and verify.
struct ZoneChangePageBuilder {
    struct Page {
        let records: [CKRecord]
        let token: CKServerChangeToken?
        let moreComing: Bool
    }

    enum IncompleteResult: Error {
        case zoneDidNotFinish
        case operationDidNotFinish
    }

    private var records: [CKRecord] = []
    private var recordFailures: [Error] = []
    private var zoneResult: Result<(CKServerChangeToken?, Data?, Bool), Error>?
    private var operationResult: Result<Void, Error>?

    mutating func recordChanged(_ result: Result<CKRecord, Error>) {
        switch result {
        case .success(let record):
            records.append(record)
        case .failure(let error):
            // Record every failure rather than only the first. The operation
            // is allowed to keep producing callbacks after a failed record,
            // and none of those later successes may erase the failure.
            recordFailures.append(error)
        }
    }

    mutating func zoneFinished(
        _ result: Result<(CKServerChangeToken?, Data?, Bool), Error>
    ) {
        zoneResult = result
    }

    mutating func operationFinished(_ result: Result<Void, Error>) {
        operationResult = result
    }

    func finish() throws -> Page {
        guard let operationResult else { throw IncompleteResult.operationDidNotFinish }

        // A zone error is the most complete explanation of a partial zone
        // read, so it deliberately wins over both record- and operation-level
        // errors when CloudKit reports more than one.
        if case .failure(let error)? = zoneResult {
            throw error
        }
        if let recordFailure = recordFailures.first {
            throw recordFailure
        }
        // Whole-operation failures sometimes arrive without any zone
        // callback. Surface the real CloudKit error rather than replacing it
        // with an internal "zone did not finish" diagnostic.
        if case .failure(let error) = operationResult {
            throw error
        }
        guard case .success(let zone)? = zoneResult else {
            throw IncompleteResult.zoneDidNotFinish
        }
        return Page(records: records, token: zone.0, moreComing: zone.2)
    }
}

// MARK: - Live CloudKit

/// The real CloudKit implementation.
///
/// Its one non-obvious job is telling absence apart from failure. CloudKit
/// reports a missing zone three different ways depending on how it went
/// missing (`unknownItem`, `zoneNotFound`, `userDeletedZone`) and wraps any
/// of them in a `partialFailure` when the operation was a batch. Everything
/// else — a network drop, a throttle, a permission error — must NOT read as
/// "already deleted", because the caller uses that answer to authorise
/// erasing the account that owns the garden.
@MainActor
struct LiveAccountDeletionCloudKit: AccountDeletionCloudKitOperating {

    enum OperationFailure: Error, CustomStringConvertible {
        case destinationShareHasNoURL
        case ambiguousSharedZones(count: Int)
        case ownedZoneMissingIdentifier

        var description: String {
            switch self {
            case .destinationShareHasNoURL:
                return "the destination share could not produce a link"
            case .ambiguousSharedZones(let count):
                return "CloudKit contains \(count) accepted shared zones and the local marker does not identify exactly one"
            case .ownedZoneMissingIdentifier:
                return "CloudKit reported an owned garden but no owned zone identifier is available"
            }
        }
    }

    private let containerID: String
    private let participantZoneID: @MainActor () -> CKRecordZone.ID?
    private let ownedHouseholdID: @MainActor () -> String?
    private let rebuildOwnGardenScope: @MainActor () async throws -> Void

    /// Resolved on use, never in `init`.
    ///
    /// Constructing a `CKContainer` is not free and, in a process without
    /// the iCloud entitlement, it is actively hostile — CloudKit logs a
    /// significant issue and the process can die on the spot. This adapter
    /// is now built during app launch (the deletion-receipt sweep needs it
    /// in scope before anything is signed in), and that sweep touches no
    /// CloudKit at all, so the container must not exist until a method
    /// that genuinely needs CloudKit asks for it.
    private var container: CKContainer { CKContainer(identifier: containerID) }

    init(
        containerIdentifier: String = "iCloud.app.seedkeep",
        participantZoneID: @escaping @MainActor () -> CKRecordZone.ID?,
        ownedHouseholdID: @escaping @MainActor () -> String?,
        rebuildOwnGardenScope: @escaping @MainActor () async throws -> Void
    ) {
        self.containerID = containerIdentifier
        self.participantZoneID = participantZoneID
        self.ownedHouseholdID = ownedHouseholdID
        self.rebuildOwnGardenScope = rebuildOwnGardenScope
    }

    // MARK: Role

    func currentRole() async throws -> AccountDeletionCloudKitRole {
        // Deletion deliberately ignores the runtime sync kill switch. The
        // flag controls whether ordinary sync runs; it cannot erase accepted
        // CKShares or owned zones, and account deletion must inspect those
        // account-wide facts even after the flag is turned off.
        let sharedZoneIDs = try await Self.fetchAllZoneIDs(
            in: container.sharedCloudDatabase)
        let markerZoneID = participantZoneID()

        let ownedZoneID = ownedHouseholdID().map {
            CKRecordZone.ID(
                zoneName: SeedkeepZoneProvisioner.zoneName(householdID: $0),
                ownerName: CKCurrentUserDefaultName)
        }
        var ownedZoneExists = false
        var acceptedShareParticipants = 0
        if let ownedZoneID {
            do {
                _ = try await container.privateCloudDatabase.recordZone(for: ownedZoneID)
                ownedZoneExists = true
            } catch let error where Self.meansAbsent(error) {
                ownedZoneExists = false
            }

            if ownedZoneExists {
                // Only an ACCEPTED participant makes this a shared garden. A
                // dangling invitation nobody took up leaves nothing behind
                // when the zone goes, so it must not force the transfer flow.
                let shareID = CKRecord.ID(
                    recordName: CKRecordNameZoneWideShare,
                    zoneID: ownedZoneID)
                let share: CKShare?
                do {
                    share = try await container.privateCloudDatabase.record(for: shareID) as? CKShare
                } catch let error where Self.meansAbsent(error) {
                    share = nil
                }
                acceptedShareParticipants = share?.participants.filter {
                    $0.role != .owner && $0.acceptanceStatus == .accepted
                }.count ?? 0
            }
        }

        return try Self.resolveRole(
            sharedZoneIDs: sharedZoneIDs,
            ownedZoneExists: ownedZoneExists,
            ownedZoneID: ownedZoneID,
            acceptedShareParticipants: acceptedShareParticipants,
            markerZoneID: markerZoneID)
    }

    /// Chooses the deletion flow from already-observed CloudKit facts.
    ///
    /// MORE THAN ONE ACCEPTED SHARE IS ALWAYS AMBIGUOUS, marker or not.
    ///
    /// The marker used to be allowed to pick a winner here, which was
    /// wrong in a way that mattered: this device is a live participant of
    /// EVERY accepted share, and the participant flow leaves exactly one.
    /// Picking one and deleting the account would silently abandon the
    /// others — the user's account disappears while their name stays on
    /// somebody else's garden, which is precisely the outcome the whole
    /// role-inspection step exists to prevent. A marker can say which zone
    /// this device is currently *viewing*; it cannot say that the other
    /// shares stopped existing.
    ///
    /// So the marker's only remaining job is diagnostic, and the honest
    /// answer for two or more shares is to stop and say so.
    nonisolated static func resolveRole(
        sharedZoneIDs: [CKRecordZone.ID],
        ownedZoneExists: Bool,
        ownedZoneID: CKRecordZone.ID?,
        acceptedShareParticipants: Int,
        markerZoneID: CKRecordZone.ID?
    ) throws -> AccountDeletionCloudKitRole {
        let defaultZoneName = CKRecordZone.default().zoneID.zoneName
        let acceptedSharedZoneIDs = sharedZoneIDs.filter {
            $0.zoneName != defaultZoneName
        }
        switch acceptedSharedZoneIDs.count {
        case 0:
            break
        case 1:
            // A missing marker is normal after a reinstall or on a second
            // device, and irrelevant when there is only one candidate.
            return .participant(sharedZoneID: acceptedSharedZoneIDs[0])
        default:
            throw OperationFailure.ambiguousSharedZones(count: acceptedSharedZoneIDs.count)
        }

        guard ownedZoneExists else { return .noGarden }
        guard let ownedZoneID else { throw OperationFailure.ownedZoneMissingIdentifier }
        return acceptedShareParticipants == 0
            ? .soloOwner(zoneID: ownedZoneID)
            : .sharedOwner(zoneID: ownedZoneID)
    }

    private static func fetchAllZoneIDs(
        in database: CKDatabase
    ) async throws -> [CKRecordZone.ID] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            var zoneIDs: [CKRecordZone.ID] = []
            var perZoneFailure: Error?
            operation.perRecordZoneResultBlock = { zoneID, result in
                switch result {
                case .success:
                    zoneIDs.append(zoneID)
                case .failure(let error):
                    // Enumeration itself is security-sensitive too. A
                    // successful operation envelope cannot make one failed
                    // zone disappear from role inspection.
                    if perZoneFailure == nil { perZoneFailure = error }
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                if let perZoneFailure {
                    continuation.resume(throwing: perZoneFailure)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: zoneIDs)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    // MARK: Participant

    func leaveSharedGarden(zoneID: CKRecordZone.ID) async throws {
        // A participant leaves by deleting the share record out of THEIR
        // shared database; CloudKit drops them from the share and the zone
        // stops being visible. Idempotent, because a retry after a partial
        // failure finds it already gone.
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            _ = try await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: [shareID])
        } catch let error where Self.meansAbsent(error) {
            // Already left.
        }
        // Clearing the participant marker and rebuilding the user's own
        // garden scope is app state, not CloudKit state, but it belongs to
        // the same step: a device that left the share while still marked as
        // a participant would relaunch pointed at a zone it can no longer
        // read.
        try await rebuildOwnGardenScope()
    }

    func sharedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool {
        try await zoneIsAbsent(zoneID, in: container.sharedCloudDatabase)
    }

    // MARK: Owner

    func deleteOwnedZone(zoneID: CKRecordZone.ID) async throws {
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch let error where Self.meansAbsent(error) {
            // A retry after a delete that actually landed.
        }
    }

    func ownedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool {
        try await zoneIsAbsent(zoneID, in: container.privateCloudDatabase)
    }

    private func zoneIsAbsent(_ zoneID: CKRecordZone.ID, in database: CKDatabase) async throws -> Bool {
        do {
            _ = try await database.recordZone(for: zoneID)
            return false
        } catch let error where Self.meansAbsent(error) {
            return true
        }
    }

    // MARK: Records

    func fetchRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        let database = database(for: zoneID)
        var collected: [CKRecord] = []
        var token: CKServerChangeToken?
        // A nil token asks for the zone's entire contents; the loop exists
        // only because CloudKit pages large zones.
        while true {
            let page = try await Self.fetchPage(database: database, zoneID: zoneID, token: token)
            collected.append(contentsOf: page.records)
            token = page.token
            guard page.moreComing else { break }
        }
        return collected
    }


    private static func fetchPage(
        database: CKDatabase,
        zoneID: CKRecordZone.ID,
        token: CKServerChangeToken?
    ) async throws -> ZoneChangePageBuilder.Page {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = token
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
            operation.fetchAllChanges = false
            var builder = ZoneChangePageBuilder()
            operation.recordWasChangedBlock = { _, result in
                builder.recordChanged(result)
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (newToken, clientChangeTokenData, moreComing)):
                    builder.zoneFinished(.success(
                        (newToken, clientChangeTokenData, moreComing)))
                case .failure(let error):
                    builder.zoneFinished(.failure(error))
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                builder.operationFinished(result)
                do {
                    continuation.resume(returning: try builder.finish())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    /// CloudKit refuses oversized modify operations, and a cascade
    /// generation can be arbitrarily large. Chunking inside one generation
    /// is safe: records in the same generation never depend on each other.
    private static let saveChunkSize = 300

    func saveRecords(
        _ records: [CKRecord],
        policy: CKModifyRecordsOperation.RecordSavePolicy,
        in zoneID: CKRecordZone.ID
    ) async throws {
        let database = database(for: zoneID)
        var index = 0
        while index < records.count {
            let chunk = Array(records[index..<min(index + Self.saveChunkSize, records.count)])
            try await Self.save(chunk, policy: policy, to: database)
            index += chunk.count
        }
    }

    private static func save(
        _ records: [CKRecord],
        policy: CKModifyRecordsOperation.RecordSavePolicy,
        to database: CKDatabase
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = policy
            // All-or-nothing: a half-saved generation would let the next one
            // reference records that are not there.
            operation.isAtomic = true
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    // MARK: Shares

    func acceptShare(at url: URL) async throws -> CKRecordZone.ID {
        let flow = SeedkeepShareFlow(containerIdentifier: containerID)
        let metadata = try await flow.fetchMetadata(url: url)
        return try await flow.acceptZoneWideShare(metadata)
    }

    func createDestination(householdID: String, title: String) async throws -> AccountDeletionDestination {
        let provisioner = SeedkeepZoneProvisioner(containerIdentifier: containerID)
        let zone = try await provisioner.ensureZone(householdID: householdID)
        // The root has to exist before the zone can be shared; the copy
        // overwrites it moments later under an all-keys policy.
        _ = try await provisioner.ensureHousehold(householdID: householdID, name: title)

        let flow = SeedkeepShareFlow(containerIdentifier: containerID)
        let share = try await flow.makeOrFetchZoneWideShare(householdID: householdID, title: title)
        if share.publicPermission != .readWrite {
            // The departing owner has to gain write access without the
            // successor knowing their Apple ID, so the share is joinable by
            // link. The link is a capability, and it only ever travels
            // inside the authenticated transfer row, readable by the two
            // bound parties.
            share.publicPermission = .readWrite
            _ = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
        }
        guard let url = share.url else { throw OperationFailure.destinationShareHasNoURL }

        return AccountDeletionDestination(
            zoneID: zone.zoneID,
            ownerRecordName: try await container.userRecordID().recordName,
            shareRecordName: share.recordID.recordName,
            shareURL: url)
    }

    // MARK: Plumbing

    private func database(for zoneID: CKRecordZone.ID) -> CKDatabase {
        zoneID.ownerName == CKCurrentUserDefaultName
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
    }

    /// The three ways CloudKit says "that zone or record is not there", and
    /// nothing else. `partialFailure` is unwrapped because a batch
    /// operation buries the real code one level down.
    static func meansAbsent(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .unknownItem, .zoneNotFound, .userDeletedZone:
            return true
        case .partialFailure:
            let partials = ckError.partialErrorsByItemID?.values ?? [:].values
            return !partials.isEmpty && partials.allSatisfy { meansAbsent($0) }
        default:
            return false
        }
    }
}
