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

/// Complete result of a paged zone-change fetch. Gate 0b needs the page index to prove that a
/// framework-owned CKAsset from an earlier page remains readable after later pages finish.
struct ZoneChangeFetchSnapshot {
    let records: [CKRecord]
    let pageIndexByRecordID: [CKRecord.ID: Int]
    let pageCount: Int
}

struct ZoneChangeFetchAccumulator {
    enum IncompleteResult: Error { case noPages }

    private var records: [CKRecord] = []
    private var pageIndexByRecordID: [CKRecord.ID: Int] = [:]
    private var pageCount = 0

    mutating func append(_ page: ZoneChangePageBuilder.Page) {
        for record in page.records {
            records.append(record)
            pageIndexByRecordID[record.recordID] = pageCount
        }
        pageCount += 1
    }

    func finish() throws -> ZoneChangeFetchSnapshot {
        guard pageCount > 0 else { throw IncompleteResult.noPages }
        return ZoneChangeFetchSnapshot(
            records: records,
            pageIndexByRecordID: pageIndexByRecordID,
            pageCount: pageCount)
    }
}

enum Gate0bAssetEvidence {
    enum Failure: Error {
        case missingAsset(field: String)
        case unreadableAsset(field: String)
        case byteMismatch(field: String)
        case recordNotFetched(recordName: String)
        case assetWasOnFinalPage(recordName: String)
    }

    static func requireLaterPage(
        after recordID: CKRecord.ID,
        in snapshot: ZoneChangeFetchSnapshot
    ) throws -> Int {
        guard let assetPageIndex = snapshot.pageIndexByRecordID[recordID] else {
            throw Failure.recordNotFetched(recordName: recordID.recordName)
        }
        guard assetPageIndex + 1 < snapshot.pageCount else {
            throw Failure.assetWasOnFinalPage(recordName: recordID.recordName)
        }
        return assetPageIndex
    }

    static func requireExactAsset(
        in record: CKRecord,
        field: String,
        expectedBytes: Data
    ) throws -> CKAsset {
        guard let asset = record[field] as? CKAsset, let url = asset.fileURL else {
            throw Failure.missingAsset(field: field)
        }
        let actual: Data
        do { actual = try Data(contentsOf: url) }
        catch { throw Failure.unreadableAsset(field: field) }
        guard actual == expectedBytes else { throw Failure.byteMismatch(field: field) }
        return asset
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
        case assetExceedsSaveByteBudget(recordName: String)

        var description: String {
            switch self {
            case .destinationShareHasNoURL:
                return "the destination share could not produce a link"
            case .ambiguousSharedZones(let count):
                return "CloudKit contains \(count) accepted shared zones and the local marker does not identify exactly one"
            case .ownedZoneMissingIdentifier:
                return "CloudKit reported an owned garden but no owned zone identifier is available"
            case .assetExceedsSaveByteBudget(let recordName):
                return "photo \(recordName) exceeds the CloudKit transfer save budget"
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

    func fetchRecords(in zoneID: CKRecordZone.ID) async throws -> AccountDeletionRecordSnapshot {
        let records = try await fetchRecordsSnapshot(in: zoneID).records
        let householdID = SeedkeepRecordNames.householdID(fromZoneName: zoneID.zoneName)
        return try AccountDeletionTransferAssetStager(householdID: householdID).snapshot(records)
    }

    func fetchRecordsSnapshot(in zoneID: CKRecordZone.ID) async throws -> ZoneChangeFetchSnapshot {
        let database = database(for: zoneID)
        var accumulator = ZoneChangeFetchAccumulator()
        var token: CKServerChangeToken?
        // A nil token asks for the zone's entire contents; the loop exists
        // only because CloudKit pages large zones.
        while true {
            let page = try await Self.fetchPage(
                database: database,
                zoneID: zoneID,
                token: token)
            accumulator.append(page)
            token = page.token
            guard page.moreComing else { break }
        }
        return try accumulator.finish()
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
    nonisolated private static let scalarSaveChunkSize = 300
    nonisolated private static let assetSaveChunkSize = 25
    nonisolated private static let assetSaveByteBudget: UInt64 = 32 * 1_024 * 1_024

    nonisolated static func saveChunks(for records: [CKRecord]) throws -> [[CKRecord]] {
        guard !records.isEmpty else { return [] }
        var chunks: [[CKRecord]] = []
        var chunk: [CKRecord] = []
        var chunkAssetBytes: UInt64 = 0
        var chunkContainsAsset = false

        for record in records {
            let recordAssetBytes = try assetByteCount(in: record)
            if let recordAssetBytes, recordAssetBytes > assetSaveByteBudget {
                throw OperationFailure.assetExceedsSaveByteBudget(
                    recordName: record.recordID.recordName)
            }
            let candidateContainsAsset = chunkContainsAsset || recordAssetBytes != nil
            let candidateRecordLimit = candidateContainsAsset
                ? assetSaveChunkSize
                : scalarSaveChunkSize
            let (candidateAssetBytes, overflowed) = chunkAssetBytes.addingReportingOverflow(
                recordAssetBytes ?? 0)
            if !chunk.isEmpty && (
                chunk.count + 1 > candidateRecordLimit
                    || overflowed
                    || candidateAssetBytes > assetSaveByteBudget
            ) {
                chunks.append(chunk)
                chunk = []
                chunkAssetBytes = 0
                chunkContainsAsset = false
            }
            chunk.append(record)
            if let recordAssetBytes {
                chunkAssetBytes += recordAssetBytes
                chunkContainsAsset = true
            }
        }
        if !chunk.isEmpty {
            chunks.append(chunk)
        }
        return chunks
    }

    nonisolated private static func assetByteCount(in record: CKRecord) throws -> UInt64? {
        var total: UInt64 = 0
        var foundAsset = false
        for key in record.allKeys() {
            guard let asset = record[key] as? CKAsset else { continue }
            foundAsset = true
            guard let url = asset.fileURL else {
                throw PhotoAssetSyncError.fetchedAssetUnavailable(
                    recordName: record.recordID.recordName)
            }
            let size: UInt64
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                size = try handle.seekToEnd()
            } catch {
                throw PhotoAssetSyncError.fetchedAssetUnavailable(
                    recordName: record.recordID.recordName)
            }
            let (newTotal, overflowed) = total.addingReportingOverflow(size)
            guard !overflowed else {
                throw PhotoAssetSyncError.fetchedAssetUnavailable(
                    recordName: record.recordID.recordName)
            }
            total = newTotal
        }
        return foundAsset ? total : nil
    }

    func saveRecords(
        _ records: [CKRecord],
        policy: CKModifyRecordsOperation.RecordSavePolicy,
        in zoneID: CKRecordZone.ID
    ) async throws {
        let database = database(for: zoneID)
        for chunk in try Self.saveChunks(for: records) {
            try await Self.save(chunk, policy: policy, to: database)
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

#if DEBUG
enum Gate0bTransferEvidence {
    enum Failure: Error, CustomStringConvertible {
        case missingAccountStamp
        case sameAccount
        case destinationIsPrivate
        case destinationZoneMismatch(expected: String, actual: String)
        case destinationOwnerMismatch(expected: String, actual: String)
        case invalidHandoff(field: String)
        case unsafeHandoff(householdID: String)
        case recordNotFetched(recordName: String)
        case paginationNotObserved(pageCount: Int)
        case destinationPublishFailedAndCleanupFailed(publish: String, cleanup: String)

        var description: String {
            switch self {
            case .missingAccountStamp:
                return "CloudKit returned an empty account stamp"
            case .sameAccount:
                return "source and successor have the same CloudKit account stamp"
            case .destinationIsPrivate:
                return "accepted destination still uses the current-user owner placeholder"
            case .destinationZoneMismatch(let expected, let actual):
                return "accepted destination zone mismatch: expected \(expected), got \(actual)"
            case .destinationOwnerMismatch(let expected, let actual):
                return "accepted destination owner mismatch: expected \(expected), got \(actual)"
            case .invalidHandoff(let field):
                return "Gate 0b handoff is missing or invalid field \(field)"
            case .unsafeHandoff(let householdID):
                return "refusing to touch non-Gate-0b household \(householdID)"
            case .recordNotFetched(let recordName):
                return "record \(recordName) was not returned by the production fetch path"
            case .paginationNotObserved(let pageCount):
                return "CloudKit returned \(pageCount) page(s); Gate 0b requires a later page after the asset"
            case .destinationPublishFailedAndCleanupFailed(let publish, let cleanup):
                return "handoff publish failed (\(publish)); destination cleanup also failed (\(cleanup))"
            }
        }
    }

    static let householdPrefix = "spike-gate0b-destination-"

    static func requireBoundHandoff(
        runID: String,
        householdID: String,
        destinationZoneName: String
    ) throws {
        let expectedHouseholdID = householdPrefix + runID
        guard !runID.isEmpty, householdID == expectedHouseholdID else {
            throw Failure.unsafeHandoff(householdID: householdID)
        }
        let expectedZoneName = SeedkeepZoneProvisioner.zoneName(
            householdID: expectedHouseholdID)
        guard destinationZoneName == expectedZoneName else {
            throw Failure.unsafeHandoff(householdID: householdID)
        }
    }

    static func requireDifferentAccounts(source: String, successor: String) throws {
        guard !source.isEmpty, !successor.isEmpty else { throw Failure.missingAccountStamp }
        guard source != successor else { throw Failure.sameAccount }
    }

    static func requireSharedDestination(
        _ zoneID: CKRecordZone.ID,
        zoneName: String,
        ownerRecordName: String
    ) throws {
        guard zoneID.ownerName != CKCurrentUserDefaultName else {
            throw Failure.destinationIsPrivate
        }
        guard zoneID.zoneName == zoneName else {
            throw Failure.destinationZoneMismatch(
                expected: zoneName, actual: zoneID.zoneName)
        }
        guard zoneID.ownerName == ownerRecordName else {
            throw Failure.destinationOwnerMismatch(
                expected: ownerRecordName, actual: zoneID.ownerName)
        }
    }

    static func expectedBytes(runID: String) -> Data {
        Data("seedkeep-gate0b-exact-asset-\(runID)".utf8)
    }
}

private struct Gate0bTransferHandoff {
    static let recordName = "seedkeep-gate0b-asset-handoff"
    static let householdPrefix = Gate0bTransferEvidence.householdPrefix

    let runID: String
    let householdID: String
    let destinationZoneName: String
    let successorStamp: String
    let shareURL: URL

    init(
        runID: String,
        householdID: String,
        destinationZoneName: String,
        successorStamp: String,
        shareURL: URL
    ) throws {
        try Gate0bTransferEvidence.requireBoundHandoff(
            runID: runID,
            householdID: householdID,
            destinationZoneName: destinationZoneName)
        self.runID = runID
        self.householdID = householdID
        self.destinationZoneName = destinationZoneName
        self.successorStamp = successorStamp
        self.shareURL = shareURL
    }

    init(record: CKRecord) throws {
        guard let runID = record["runID"] as? String, !runID.isEmpty else {
            throw Gate0bTransferEvidence.Failure.invalidHandoff(field: "runID")
        }
        guard let householdID = record["householdID"] as? String else {
            throw Gate0bTransferEvidence.Failure.invalidHandoff(field: "householdID")
        }
        guard let destinationZoneName = record["destinationZoneName"] as? String,
              !destinationZoneName.isEmpty else {
            throw Gate0bTransferEvidence.Failure.invalidHandoff(field: "destinationZoneName")
        }
        guard let successorStamp = record["successorStamp"] as? String,
              !successorStamp.isEmpty else {
            throw Gate0bTransferEvidence.Failure.invalidHandoff(field: "successorStamp")
        }
        guard let urlString = record["url"] as? String,
              let shareURL = URL(string: urlString) else {
            throw Gate0bTransferEvidence.Failure.invalidHandoff(field: "url")
        }
        try Gate0bTransferEvidence.requireBoundHandoff(
            runID: runID,
            householdID: householdID,
            destinationZoneName: destinationZoneName)
        self.runID = runID
        self.householdID = householdID
        self.destinationZoneName = destinationZoneName
        self.successorStamp = successorStamp
        self.shareURL = shareURL
    }
}

private struct Gate0bSourceResult {
    let pageCount: Int
    let assetPageIndex: Int
    let fillerCount: Int
}

private final class Gate0bResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Value, Never>, with value: Value) {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()
        if shouldResume { continuation.resume(returning: value) }
    }
}

/// DEBUG-only execution harness for Photos-on-CloudKit Gate 0b. Every CloudKit object it creates
/// has a unique `spike-gate0b-*` identity, and both owner-side modes validate that prefix before
/// deletion. The tracked app entitlement stays Production; live runs override it with a temporary
/// Development entitlement at build time.
@MainActor
enum AccountDeletionGate0bSpike {
    private static let containerID = "iCloud.app.seedkeep"
    private static let destinationMode = "asset-transfer-destination"
    private static let sourceMode = "asset-transfer-source"
    private static let cleanupMode = "asset-transfer-cleanup"
    private static let fillerBatchCount = 600
    private static let maxFillerRounds = 3

    static func handles(_ mode: String) -> Bool {
        [destinationMode, sourceMode, cleanupMode].contains(mode)
    }

    static func run(mode: String) async -> String {
        let container = CKContainer(identifier: containerID)
        guard let status = await boundedAccountStatus(container) else {
            return "❌ Gate 0b timed out checking the CloudKit account"
        }
        guard status == .available else {
            return "❌ Gate 0b CloudKit account unavailable: \(describe(status))"
        }

        return await boundedRun(seconds: 300) {
            do {
                switch mode {
                case destinationMode:
                    return try await prepareDestination(container: container)
                case sourceMode:
                    return await runSource(container: container)
                case cleanupMode:
                    return await verifyAndCleanupDestination(container: container)
                default:
                    return "❌ unknown Gate 0b mode \(mode)"
                }
            } catch {
                return "❌ Gate 0b \(mode) failed: \(error)"
            }
        }
    }

    private static func makeAdapter() -> LiveAccountDeletionCloudKit {
        LiveAccountDeletionCloudKit(
            containerIdentifier: containerID,
            participantZoneID: { nil },
            ownedHouseholdID: { nil },
            rebuildOwnGardenScope: {})
    }

    private static func prepareDestination(container: CKContainer) async throws -> String {
        if let existing = try await fetchOptionalHandoff(container: container) {
            throw Gate0bTransferEvidence.Failure.invalidHandoff(
                field: "outstanding run \(existing.runID); run cleanup first")
        }

        let runID = String(UUID().uuidString.lowercased().prefix(8))
        let householdID = Gate0bTransferHandoff.householdPrefix + runID
        let adapter = makeAdapter()
        let destination = try await adapter.createDestination(
            householdID: householdID, title: "Gate 0b temporary destination")
        let handoff = try Gate0bTransferHandoff(
            runID: runID,
            householdID: householdID,
            destinationZoneName: destination.zoneID.zoneName,
            successorStamp: destination.ownerRecordName,
            shareURL: destination.shareURL)
        do {
            try await publish(handoff: handoff, container: container)
        } catch let publishError {
            do {
                try await adapter.deleteOwnedZone(zoneID: destination.zoneID)
            } catch let cleanupError {
                throw Gate0bTransferEvidence.Failure
                    .destinationPublishFailedAndCleanupFailed(
                        publish: String(describing: publishError),
                        cleanup: String(describing: cleanupError))
            }
            throw publishError
        }

        return """
        ✅ Gate 0b DESTINATION READY: unique successor-owned zone + zone-wide share published internally
        run = \(runID)
        successor userRecordID = \(destination.ownerRecordName)
        → run asset-transfer-source on the other simulator/account
        """
    }

    private static func runSource(container: CKContainer) async -> String {
        let adapter = makeAdapter()
        var sourceZoneID: CKRecordZone.ID?
        do {
            let handoff = try await fetchHandoff(container: container)
            let sourceStamp = try await container.userRecordID().recordName
            try Gate0bTransferEvidence.requireDifferentAccounts(
                source: sourceStamp, successor: handoff.successorStamp)

            let destinationZoneID = try await adapter.acceptShare(at: handoff.shareURL)
            try Gate0bTransferEvidence.requireSharedDestination(
                destinationZoneID,
                zoneName: handoff.destinationZoneName,
                ownerRecordName: handoff.successorStamp)

            let sourceHouseholdID = "spike-gate0b-source-\(handoff.runID)"
            let sourceZone = try await SeedkeepZoneProvisioner(
                containerIdentifier: containerID).ensureZone(householdID: sourceHouseholdID)
            sourceZoneID = sourceZone.zoneID
            let evidence = try await copyAssetAcrossPages(
                handoff: handoff,
                sourceZoneID: sourceZone.zoneID,
                destinationZoneID: destinationZoneID,
                adapter: adapter)

            try await adapter.deleteOwnedZone(zoneID: sourceZone.zoneID)
            guard try await adapter.ownedZoneIsAbsent(zoneID: sourceZone.zoneID) else {
                throw Gate0bTransferEvidence.Failure.unsafeHandoff(
                    householdID: "temporary source zone was not deleted")
            }
            return """
            ✅ Gate 0b SOURCE: production CKFetchRecordZoneChangesOperation delivered exact asset bytes before a later page
            source userRecordID = \(sourceStamp)
            successor userRecordID = \(handoff.successorStamp)
            pages = \(evidence.pageCount); asset page = \(evidence.assetPageIndex + 1); temporary fillers = \(evidence.fillerCount)
            ✅ fetched CKAsset stayed readable through later pages and after sharedCloudDatabase save returned
            ✅ destination refetch from sharedCloudDatabase matched the original bytes exactly
            ✅ source temporary zone deleted
            → run asset-transfer-cleanup on the successor simulator/account
            """
        } catch {
            var cleanup = "no source zone had been created"
            if let sourceZoneID {
                do {
                    try await adapter.deleteOwnedZone(zoneID: sourceZoneID)
                    cleanup = "source temporary zone deleted"
                } catch {
                    cleanup = "source cleanup ALSO failed: \(error)"
                }
            }
            return "❌ Gate 0b SOURCE failed: \(error) (\(cleanup))"
        }
    }

    private static func copyAssetAcrossPages(
        handoff: Gate0bTransferHandoff,
        sourceZoneID: CKRecordZone.ID,
        destinationZoneID: CKRecordZone.ID,
        adapter: LiveAccountDeletionCloudKit
    ) async throws -> Gate0bSourceResult {
        let expectedBytes = Gate0bTransferEvidence.expectedBytes(runID: handoff.runID)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedkeep-gate0b-\(handoff.runID).bin")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try expectedBytes.write(to: temporaryURL, options: .atomic)

        let sourceRecordName = SeedkeepRecordNames.seedPhoto("gate0b-\(handoff.runID)")
        let sourceRecordID = CKRecord.ID(
            recordName: sourceRecordName, zoneID: sourceZoneID)
        let sourcePhoto = CKRecord(
            recordType: SeedkeepRecordType.seedPhoto.recordTypeName,
            recordID: sourceRecordID)
        sourcePhoto["asset"] = CKAsset(fileURL: temporaryURL)
        sourcePhoto["assetSHA256"] = "deliberately-untrusted" as CKRecordValue
        try await adapter.saveRecords([sourcePhoto], policy: .allKeys, in: sourceZoneID)
        try FileManager.default.removeItem(at: temporaryURL)

        var snapshot: ZoneChangeFetchSnapshot?
        var assetPageIndex: Int?
        var fillerCount = 0
        for round in 0..<maxFillerRounds {
            let fillers = makeFillers(
                runID: handoff.runID,
                zoneID: sourceZoneID,
                offset: round * fillerBatchCount,
                count: fillerBatchCount)
            try await adapter.saveRecords(fillers, policy: .allKeys, in: sourceZoneID)
            fillerCount += fillers.count
            let fetched = try await adapter.fetchRecordsSnapshot(in: sourceZoneID)
            snapshot = fetched
            guard fetched.pageIndexByRecordID[sourceRecordID] != nil else {
                throw Gate0bTransferEvidence.Failure.recordNotFetched(
                    recordName: sourceRecordName)
            }
            if let pageIndex = try? Gate0bAssetEvidence.requireLaterPage(
                after: sourceRecordID, in: fetched) {
                assetPageIndex = pageIndex
                break
            }
        }
        guard let snapshot else {
            throw Gate0bTransferEvidence.Failure.paginationNotObserved(pageCount: 0)
        }
        guard let assetPageIndex else {
            throw Gate0bTransferEvidence.Failure.paginationNotObserved(
                pageCount: snapshot.pageCount)
        }
        guard let fetchedSource = snapshot.records.first(where: {
            $0.recordID == sourceRecordID
        }) else {
            throw Gate0bTransferEvidence.Failure.recordNotFetched(
                recordName: sourceRecordName)
        }
        let fetchedAsset = try Gate0bAssetEvidence.requireExactAsset(
            in: fetchedSource, field: "asset", expectedBytes: expectedBytes)

        let destinationRecordName = SeedkeepRecordNames.seedPhoto(
            "gate0b-destination-\(handoff.runID)")
        let destinationRecordID = CKRecord.ID(
            recordName: destinationRecordName, zoneID: destinationZoneID)
        let destinationPhoto = CKRecord(
            recordType: SeedkeepRecordType.seedPhoto.recordTypeName,
            recordID: destinationRecordID)
        destinationPhoto["asset"] = fetchedAsset
        destinationPhoto["assetSHA256"] = "copied-field-is-not-evidence" as CKRecordValue
        try await adapter.saveRecords(
            [destinationPhoto], policy: .allKeys, in: destinationZoneID)

        _ = try Gate0bAssetEvidence.requireExactAsset(
            in: fetchedSource, field: "asset", expectedBytes: expectedBytes)
        let destinationSnapshot = try await adapter.fetchRecordsSnapshot(
            in: destinationZoneID)
        guard let fetchedDestination = destinationSnapshot.records.first(where: {
            $0.recordID == destinationRecordID
        }) else {
            throw Gate0bTransferEvidence.Failure.recordNotFetched(
                recordName: destinationRecordName)
        }
        _ = try Gate0bAssetEvidence.requireExactAsset(
            in: fetchedDestination, field: "asset", expectedBytes: expectedBytes)

        return Gate0bSourceResult(
            pageCount: snapshot.pageCount,
            assetPageIndex: assetPageIndex,
            fillerCount: fillerCount)
    }

    private static func makeFillers(
        runID: String,
        zoneID: CKRecordZone.ID,
        offset: Int,
        count: Int
    ) -> [CKRecord] {
        let payload = String(repeating: "0123456789abcdef", count: 1_024)
        return (offset..<(offset + count)).map { index in
            let id = CKRecord.ID(
                recordName: SeedkeepRecordNames.seed("gate0b-\(runID)-\(index)"),
                zoneID: zoneID)
            let record = CKRecord(
                recordType: SeedkeepRecordType.seed.recordTypeName,
                recordID: id)
            record["customName"] = "Gate 0b filler \(index)" as CKRecordValue
            record["notes"] = payload as CKRecordValue
            return record
        }
    }

    private static func verifyAndCleanupDestination(container: CKContainer) async -> String {
        let adapter = makeAdapter()
        do {
            let handoff = try await fetchHandoff(container: container)
            let currentStamp = try await container.userRecordID().recordName
            guard currentStamp == handoff.successorStamp else {
                throw Gate0bTransferEvidence.Failure.destinationOwnerMismatch(
                    expected: handoff.successorStamp, actual: currentStamp)
            }
            let zoneID = CKRecordZone.ID(
                zoneName: handoff.destinationZoneName,
                ownerName: CKCurrentUserDefaultName)
            let expectedRecordID = CKRecord.ID(
                recordName: SeedkeepRecordNames.seedPhoto(
                    "gate0b-destination-\(handoff.runID)"),
                zoneID: zoneID)

            var verificationError: Error?
            do {
                let snapshot = try await adapter.fetchRecordsSnapshot(in: zoneID)
                guard let record = snapshot.records.first(where: {
                    $0.recordID == expectedRecordID
                }) else {
                    throw Gate0bTransferEvidence.Failure.recordNotFetched(
                        recordName: expectedRecordID.recordName)
                }
                _ = try Gate0bAssetEvidence.requireExactAsset(
                    in: record,
                    field: "asset",
                    expectedBytes: Gate0bTransferEvidence.expectedBytes(runID: handoff.runID))
            } catch {
                verificationError = error
            }

            do {
                try await adapter.deleteOwnedZone(zoneID: zoneID)
                guard try await adapter.ownedZoneIsAbsent(zoneID: zoneID) else {
                    throw Gate0bTransferEvidence.Failure.unsafeHandoff(
                        householdID: "temporary destination zone was not deleted")
                }
                try await deleteHandoff(container: container)
            } catch {
                return "❌ Gate 0b destination cleanup failed: \(error)"
            }

            if let verificationError {
                return "❌ Gate 0b successor verification failed: \(verificationError) (temporary destination and handoff deleted)"
            }
            return """
            ✅ Gate 0b COMPLETE: successor refetched the transferred CKAsset from privateCloudDatabase and matched the original bytes exactly
            successor userRecordID = \(currentStamp)
            ✅ source and successor stamps were distinct; source used sharedCloudDatabase
            ✅ temporary destination zone and public handoff deleted
            """
        } catch {
            return "❌ Gate 0b CLEANUP failed before safe deletion: \(error)"
        }
    }

    private static func publish(
        handoff: Gate0bTransferHandoff,
        container: CKContainer
    ) async throws {
        let id = CKRecord.ID(recordName: Gate0bTransferHandoff.recordName)
        let record = (try? await container.publicCloudDatabase.record(for: id))
            ?? CKRecord(recordType: "ShareHandoff", recordID: id)
        record["runID"] = handoff.runID as CKRecordValue
        record["householdID"] = handoff.householdID as CKRecordValue
        record["destinationZoneName"] = handoff.destinationZoneName as CKRecordValue
        record["successorStamp"] = handoff.successorStamp as CKRecordValue
        record["url"] = handoff.shareURL.absoluteString as CKRecordValue
        _ = try await container.publicCloudDatabase.modifyRecords(
            saving: [record], deleting: [])
    }

    private static func fetchHandoff(container: CKContainer) async throws -> Gate0bTransferHandoff {
        let record = try await container.publicCloudDatabase.record(
            for: CKRecord.ID(recordName: Gate0bTransferHandoff.recordName))
        return try Gate0bTransferHandoff(record: record)
    }

    private static func fetchOptionalHandoff(
        container: CKContainer
    ) async throws -> Gate0bTransferHandoff? {
        do {
            return try await fetchHandoff(container: container)
        } catch let error where LiveAccountDeletionCloudKit.meansAbsent(error) {
            return nil
        }
    }

    private static func deleteHandoff(container: CKContainer) async throws {
        let id = CKRecord.ID(recordName: Gate0bTransferHandoff.recordName)
        do {
            _ = try await container.publicCloudDatabase.modifyRecords(
                saving: [], deleting: [id])
        } catch let error where LiveAccountDeletionCloudKit.meansAbsent(error) {
            // An interrupted retry may find the exact temporary handoff already gone.
        }
    }

    private static func boundedAccountStatus(
        _ container: CKContainer,
        seconds: UInt64 = 15
    ) async -> CKAccountStatus? {
        let box = Gate0bResumeOnce<CKAccountStatus?>()
        return await withCheckedContinuation { continuation in
            Task.detached {
                box.resume(continuation, with: try? await container.accountStatus())
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                box.resume(continuation, with: nil)
            }
        }
    }

    private static func boundedRun(
        seconds: UInt64,
        operation: @escaping @MainActor () async -> String
    ) async -> String {
        let box = Gate0bResumeOnce<String>()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                box.resume(continuation, with: await operation())
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                box.resume(
                    continuation,
                    with: "❌ Gate 0b timed out after \(seconds)s; inspect CloudKit auth before retrying")
            }
        }
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "no account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could not determine"
        case .temporarilyUnavailable: return "temporarily unavailable"
        @unknown default: return "unknown"
        }
    }
}
#endif
