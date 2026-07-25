import CloudKit
import Foundation
import SeedkeepCloudKit
import SeedkeepKit

// The two seams `AccountDeletionCoordinator` reaches the world through, plus
// their live implementations.
//
// The coordinator is a state machine over irreversible effects, so what it
// needs from CloudKit and from the server is written down here as two narrow
// protocols rather than taken directly from `CKContainer` and
// `SeedkeepClient`. That is not test decoration: the only way to prove
// "the source zone is still there after this failure" or "`DELETE /api/me`
// was never reached" is to run the whole machine against substitutes that
// can fail on demand, and the only way to prove ORDER is to record calls.
//
// Both protocols are `@MainActor`. CKRecord is not `Sendable`, so the
// coordinator and its CloudKit seam have to share one isolation domain or
// every fetched record becomes a concurrency error; main-actor isolation is
// the domain `AppEnvironment` and the deletion UI already live in. The
// actual CloudKit and network work happens inside `await`s that suspend, so
// nothing below occupies the main thread while it runs.

// MARK: - CloudKit

/// What this account's iCloud garden is, right now. Decides which flow the
/// coordinator runs, and it is read exactly once — at the start — because
/// it is a fact about the CKShare, not about progress.
enum AccountDeletionCloudKitRole: Equatable {
    /// Nothing to dispose of: CloudKit sync is off, or no household zone
    /// was ever provisioned.
    case noGarden
    /// This device accepted somebody else's zone-wide share.
    case participant(sharedZoneID: CKRecordZone.ID)
    /// Owns a household zone nobody else has accepted.
    case soloOwner(zoneID: CKRecordZone.ID)
    /// Owns a household zone other people are in, so the garden has to be
    /// handed to a successor before it can be deleted.
    case sharedOwner(zoneID: CKRecordZone.ID)
}

/// The successor-owned zone a departing owner's garden is copied into.
struct AccountDeletionDestination: Equatable {
    /// The zone as the CREATING DEVICE addresses it — in the successor's
    /// own private database, so `ownerName` is the current-user
    /// placeholder.
    let zoneID: CKRecordZone.ID
    /// The successor's CloudKit user record name. This is the ownership
    /// claim posted to the server, and it is exactly the `ownerName` the
    /// departing owner will see once they accept the share — which is what
    /// lets the owner check that the zone they are copying into is the zone
    /// the successor said they own.
    let ownerRecordName: String
    let shareRecordName: String
    let shareURL: URL
}

/// Every CloudKit fact the coordinator reads and every CloudKit effect it
/// causes. Deliberately phrased in the flow's vocabulary ("leave the shared
/// garden", "is the zone absent") rather than CloudKit's, so the state
/// machine cannot accidentally depend on a CloudKit detail it does not
/// model — most importantly the difference between "the zone is gone" and
/// "the zone could not be read".
@MainActor
protocol AccountDeletionCloudKitOperating {
    func currentRole() async throws -> AccountDeletionCloudKitRole

    /// Participant: leave the owner's shared zone and put this device back
    /// on its own garden.
    func leaveSharedGarden(zoneID: CKRecordZone.ID) async throws
    /// Participant: is the shared zone genuinely gone? A read failure that
    /// is not an absence must surface, never answer `true`.
    func sharedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool

    /// Owner: delete the household zone from the private database.
    func deleteOwnedZone(zoneID: CKRecordZone.ID) async throws
    /// Owner: is the owned zone genuinely gone?
    func ownedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool

    /// Every application record in a zone. An absent zone is an ERROR here,
    /// not an empty garden — treating it as empty during the copy would let
    /// the owner verify nothing against nothing.
    func fetchRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord]
    /// Save one cascade generation into the destination zone under the copy
    /// plan's required save policy.
    func saveRecords(
        _ records: [CKRecord],
        policy: CKModifyRecordsOperation.RecordSavePolicy,
        in zoneID: CKRecordZone.ID
    ) async throws

    /// Owner: accept the successor's destination share and report the zone
    /// it actually resolved to.
    func acceptShare(at url: URL) async throws -> CKRecordZone.ID
    /// Successor: create — or adopt, if a previous attempt got this far —
    /// the destination zone and its zone-wide share.
    func createDestination(householdID: String, title: String) async throws -> AccountDeletionDestination
}

// MARK: - Server

/// The server half: the transfer coordination routes plus the final account
/// deletion. Narrower than `SeedkeepClient` on purpose, and typed in
/// `HouseholdGraphDigest` rather than a loose (hash, counts) pair so a
/// caller cannot post a hash from one graph with the census of another.
@MainActor
protocol AccountDeletionServerOperating {
    func createTransfer() async throws -> WireResponses.AccountDeletionTransferOne
    func transfer(id: String) async throws -> AccountDeletionTransferDTO
    func acceptTransfer(id: String, token: String) async throws -> AccountDeletionTransferDTO
    func putDestination(
        id: String,
        zoneName: String,
        zoneOwnerName: String,
        shareRecordName: String,
        shareURL: String?
    ) async throws -> AccountDeletionTransferDTO
    func putOwnerVerification(id: String, digest: HouseholdGraphDigest) async throws -> AccountDeletionTransferDTO
    func putSuccessorVerification(
        id: String,
        digest: HouseholdGraphDigest,
        destinationZoneName: String,
        destinationZoneOwnerName: String
    ) async throws -> AccountDeletionTransferDTO
    func markSourceDeleted(id: String) async throws -> AccountDeletionTransferDTO
    func cancelTransfer(id: String) async throws -> AccountDeletionTransferDTO
    /// `DELETE /api/me`. The last irreversible step of every flow.
    func deleteAccount(disposition: AccountDeletionDisposition) async throws -> Bool
}

/// Thin pass-through to `SeedkeepClient`. Holds no state and makes no
/// decisions — everything that could be wrong is decided by the caller.
@MainActor
struct LiveAccountDeletionServer: AccountDeletionServerOperating {
    let client: SeedkeepClient

    func createTransfer() async throws -> WireResponses.AccountDeletionTransferOne {
        try await client.createAccountDeletionTransfer()
    }

    func transfer(id: String) async throws -> AccountDeletionTransferDTO {
        try await client.accountDeletionTransfer(id: id)
    }

    func acceptTransfer(id: String, token: String) async throws -> AccountDeletionTransferDTO {
        try await client.acceptAccountDeletionTransfer(id: id, token: token)
    }

    func putDestination(
        id: String,
        zoneName: String,
        zoneOwnerName: String,
        shareRecordName: String,
        shareURL: String?
    ) async throws -> AccountDeletionTransferDTO {
        try await client.putAccountDeletionTransferDestination(
            id: id, zoneName: zoneName, zoneOwnerName: zoneOwnerName,
            shareRecordName: shareRecordName, shareURL: shareURL)
    }

    func putOwnerVerification(id: String, digest: HouseholdGraphDigest) async throws -> AccountDeletionTransferDTO {
        try await client.putAccountDeletionTransferOwnerVerification(
            id: id, digest: digest.sha256, recordCounts: digest.counts)
    }

    func putSuccessorVerification(
        id: String,
        digest: HouseholdGraphDigest,
        destinationZoneName: String,
        destinationZoneOwnerName: String
    ) async throws -> AccountDeletionTransferDTO {
        try await client.putAccountDeletionTransferSuccessorVerification(
            id: id, digest: digest.sha256, recordCounts: digest.counts,
            destinationZoneName: destinationZoneName,
            destinationZoneOwnerName: destinationZoneOwnerName)
    }

    func markSourceDeleted(id: String) async throws -> AccountDeletionTransferDTO {
        try await client.markAccountDeletionTransferSourceDeleted(id: id)
    }

    func cancelTransfer(id: String) async throws -> AccountDeletionTransferDTO {
        try await client.cancelAccountDeletionTransfer(id: id)
    }

    func deleteAccount(disposition: AccountDeletionDisposition) async throws -> Bool {
        try await client.deleteAccount(disposition: disposition)
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
        var description: String {
            switch self {
            case .destinationShareHasNoURL:
                return "the destination share could not produce a link"
            }
        }
    }

    private let containerID: String
    private let container: CKContainer
    private let isEnabled: @MainActor () -> Bool
    private let participantZoneID: @MainActor () -> CKRecordZone.ID?
    private let ownedHouseholdID: @MainActor () -> String?
    private let rebuildOwnGardenScope: @MainActor () async -> Void

    init(
        containerIdentifier: String = "iCloud.app.seedkeep",
        isEnabled: @escaping @MainActor () -> Bool,
        participantZoneID: @escaping @MainActor () -> CKRecordZone.ID?,
        ownedHouseholdID: @escaping @MainActor () -> String?,
        rebuildOwnGardenScope: @escaping @MainActor () async -> Void
    ) {
        self.containerID = containerIdentifier
        self.container = CKContainer(identifier: containerIdentifier)
        self.isEnabled = isEnabled
        self.participantZoneID = participantZoneID
        self.ownedHouseholdID = ownedHouseholdID
        self.rebuildOwnGardenScope = rebuildOwnGardenScope
    }

    // MARK: Role

    func currentRole() async throws -> AccountDeletionCloudKitRole {
        guard isEnabled() else { return .noGarden }
        // Participant first: a device that adopted somebody else's garden
        // must never be mistaken for the owner of a zone it merely reads.
        if let zoneID = participantZoneID() { return .participant(sharedZoneID: zoneID) }
        guard let householdID = ownedHouseholdID() else { return .noGarden }

        let zoneID = CKRecordZone.ID(zoneName: SeedkeepZoneProvisioner.zoneName(householdID: householdID),
                                     ownerName: CKCurrentUserDefaultName)
        do {
            _ = try await container.privateCloudDatabase.recordZone(for: zoneID)
        } catch let error where Self.meansAbsent(error) {
            return .noGarden
        }

        // Only an ACCEPTED participant makes this a shared garden. A
        // dangling invitation nobody took up leaves nothing behind when the
        // zone goes, so it must not force the whole transfer flow on a user
        // who is really deleting a solo garden.
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let share: CKShare?
        do {
            share = try await container.privateCloudDatabase.record(for: shareID) as? CKShare
        } catch let error where Self.meansAbsent(error) {
            share = nil
        }
        let others = share?.participants.filter {
            $0.role != .owner && $0.acceptanceStatus == .accepted
        } ?? []
        return others.isEmpty ? .soloOwner(zoneID: zoneID) : .sharedOwner(zoneID: zoneID)
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
        await rebuildOwnGardenScope()
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

    private struct Page {
        var records: [CKRecord]
        var token: CKServerChangeToken?
        var moreComing: Bool
    }

    private static func fetchPage(
        database: CKDatabase,
        zoneID: CKRecordZone.ID,
        token: CKServerChangeToken?
    ) async throws -> Page {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = token
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
            operation.fetchAllChanges = false
            var page = Page(records: [], token: token, moreComing: false)
            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result { page.records.append(record) }
            }
            operation.recordZoneChangeTokensUpdatedBlock = { _, newToken, _ in
                page.token = newToken
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (newToken, _, moreComing)):
                    page.token = newToken
                    page.moreComing = moreComing
                case .failure:
                    break   // reported by fetchRecordZoneChangesResultBlock
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: continuation.resume(returning: page)
                case .failure(let error): continuation.resume(throwing: error)
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
