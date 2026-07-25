import Testing
import Foundation
import CloudKit
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

// Role-specific, resumable account deletion
// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md`
// § "Role flows" and § "Failure invariants").
//
// The coordinator is the only place in the app that can put a user in an
// unrecoverable state: it deletes CloudKit zones the user can never get
// back, and it asks the server to erase the account that owns them. Every
// test below defends one of the four invariants that make that safe:
//
//   1. ORDER. `DELETE /api/me` is last. Nothing signs out, and no token is
//      cleared, until the server confirms the account is gone.
//   2. SOURCE PRESERVATION. The owner's zone is deleted only after the
//      server holds two independently-computed digests that match, over a
//      destination the owner has proved the successor owns.
//   3. CHECKPOINT-AFTER-SUCCESS. A phase is written only once its external
//      operation has actually landed, so resuming re-attempts exactly the
//      step that did not finish — never one that did.
//   4. FAIL CLOSED. An ambiguous answer (zone still present, digests
//      absent, server phase behind the local one) stops the flow with the
//      account and the garden both intact.

// MARK: - Fixtures

private let ownerHouseholdID = "hh_owner"
private let ownerZone = CKRecordZone.ID(zoneName: "seedkeep-hh_owner", ownerName: CKCurrentUserDefaultName)
/// The destination as the DEPARTING OWNER sees it: the successor's zone in
/// the owner's shared database, whose `ownerName` is the successor's
/// CloudKit user record name.
private let successorRecordName = "_successor_ck_user"
private let destinationZoneFromOwner = CKRecordZone.ID(zoneName: "seedkeep-hh_owner",
                                                       ownerName: successorRecordName)
/// The same zone as the SUCCESSOR sees it: their own private database.
private let destinationZoneFromSuccessor = CKRecordZone.ID(zoneName: "seedkeep-hh_owner",
                                                           ownerName: CKCurrentUserDefaultName)
private let destinationShareURL = URL(string: "https://www.icloud.com/share/0destination")!

private func zoneKey(_ zoneID: CKRecordZone.ID) -> String {
    "\(zoneID.zoneName)|\(zoneID.ownerName)"
}

private func record(
    _ type: SeedkeepRecordType,
    _ recordName: String,
    in zone: CKRecordZone.ID,
    scalars: [String: CKRecordValue] = [:],
    refs: [String: CKRecord.Reference] = [:]
) -> CKRecord {
    let record = CKRecord(recordType: type.recordTypeName,
                          recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
    for (key, value) in scalars { record[key] = value }
    for (key, value) in refs { record[key] = value }
    return record
}

/// A small but structurally complete garden: a root, a plain record, a
/// record with a non-cascading reference, and a `.deleteSelf` child that
/// forces a second copy batch.
private func gardenGraph(in zone: CKRecordZone.ID = ownerZone) -> [CKRecord] {
    [
        record(.household, "household:hh_owner", in: zone,
               scalars: ["name": "Finklea Garden" as CKRecordValue,
                         "createdAt": 1 as CKRecordValue,
                         "updatedAt": 2 as CKRecordValue]),
        record(.location, "location:l1", in: zone,
               scalars: ["name": "Garage shelf" as CKRecordValue]),
        record(.seed, "seed:s1", in: zone,
               scalars: ["customName": "Brandywine" as CKRecordValue,
                         "packetCount": 3 as CKRecordValue],
               refs: ["locationID": CKRecord.Reference(
                   recordID: CKRecord.ID(recordName: "location:l1", zoneID: zone), action: .none)]),
        record(.seedPhoto, "seedPhoto:p1", in: zone,
               scalars: ["r2Key": "k/abc" as CKRecordValue],
               refs: ["seedID": CKRecord.Reference(
                   recordID: CKRecord.ID(recordName: "seed:s1", zoneID: zone), action: .deleteSelf)]),
    ]
}

private func gardenDigest(in zone: CKRecordZone.ID = ownerZone) throws -> HouseholdGraphDigest {
    try HouseholdGraphDigester.digest(of: gardenGraph(in: zone), in: zone)
}

// MARK: - CloudKit fake

/// In-memory CloudKit. Models the three behaviours the coordinator's
/// correctness rests on: a zone is present or it is not, a fetch from an
/// absent zone fails rather than returning nothing, and overwriting an
/// existing record with a freshly-built (change-tag-less) one requires
/// `.allKeys`.
@MainActor
private final class FakeCloudKit: AccountDeletionCloudKitOperating {

    enum Op: Hashable {
        case currentRole, leaveSharedGarden, sharedZoneIsAbsent
        case deleteOwnedZone, ownedZoneIsAbsent
        case fetchRecords, saveRecords, acceptShare, createDestination
    }

    enum Call: Equatable {
        case currentRole
        case leaveSharedGarden(String)
        case sharedZoneIsAbsent(String)
        case deleteOwnedZone(String)
        case ownedZoneIsAbsent(String)
        case fetchRecords(String)
        case saveRecords(zone: String, names: [String], policy: CKModifyRecordsOperation.RecordSavePolicy)
        case acceptShare(URL)
        case createDestination(householdID: String)
    }

    enum Failure: Error, Equatable { case injected(Op) }

    private(set) var calls: [Call] = []
    var role: AccountDeletionCloudKitRole = .noGarden
    var failures: [Op: Error] = [:]
    /// Zones that exist. Keyed by `zoneName|ownerName`.
    var presentZones: Set<String> = []
    /// Deletion silently does nothing — models a zone the server said it
    /// removed but that is still readable.
    var deletionIsNoop = false
    var recordsByZone: [String: [CKRecord]] = [:]
    var acceptedZoneID = destinationZoneFromOwner
    var destinationOwnerRecordName = successorRecordName

    func seed(zone: CKRecordZone.ID, records: [CKRecord] = []) {
        presentZones.insert(zoneKey(zone))
        recordsByZone[zoneKey(zone)] = records
    }

    /// Runs just as `op` is dispatched. Lets a test move the world (say,
    /// have a second window advance the checkpoint) at an exact point
    /// inside a step.
    var onCall: (@MainActor (Op) -> Void)?

    private func check(_ op: Op) throws {
        onCall?(op)
        if let error = failures[op] { throw error }
    }

    func currentRole() async throws -> AccountDeletionCloudKitRole {
        calls.append(.currentRole)
        try check(.currentRole)
        return role
    }

    func leaveSharedGarden(zoneID: CKRecordZone.ID) async throws {
        calls.append(.leaveSharedGarden(zoneKey(zoneID)))
        try check(.leaveSharedGarden)
        if !deletionIsNoop { presentZones.remove(zoneKey(zoneID)) }
    }

    func sharedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool {
        calls.append(.sharedZoneIsAbsent(zoneKey(zoneID)))
        try check(.sharedZoneIsAbsent)
        return !presentZones.contains(zoneKey(zoneID))
    }

    func deleteOwnedZone(zoneID: CKRecordZone.ID) async throws {
        calls.append(.deleteOwnedZone(zoneKey(zoneID)))
        try check(.deleteOwnedZone)
        if !deletionIsNoop { presentZones.remove(zoneKey(zoneID)) }
    }

    func ownedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool {
        calls.append(.ownedZoneIsAbsent(zoneKey(zoneID)))
        try check(.ownedZoneIsAbsent)
        return !presentZones.contains(zoneKey(zoneID))
    }

    func fetchRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        calls.append(.fetchRecords(zoneKey(zoneID)))
        try check(.fetchRecords)
        guard presentZones.contains(zoneKey(zoneID)) else {
            throw CKError(.zoneNotFound)
        }
        return recordsByZone[zoneKey(zoneID)] ?? []
    }

    func saveRecords(
        _ records: [CKRecord],
        policy: CKModifyRecordsOperation.RecordSavePolicy,
        in zoneID: CKRecordZone.ID
    ) async throws {
        calls.append(.saveRecords(zone: zoneKey(zoneID),
                                  names: records.map(\.recordID.recordName),
                                  policy: policy))
        try check(.saveRecords)
        guard presentZones.contains(zoneKey(zoneID)) else { throw CKError(.zoneNotFound) }
        var stored = recordsByZone[zoneKey(zoneID)] ?? []
        for record in records {
            if let index = stored.firstIndex(where: { $0.recordID.recordName == record.recordID.recordName }) {
                // CloudKit's optimistic concurrency: a record built from
                // scratch carries no change tag, so replacing an existing
                // one is a `serverRecordChanged` conflict unless the save
                // policy says every key wins.
                guard policy == .allKeys else { throw CKError(.serverRecordChanged) }
                stored[index] = record
            } else {
                stored.append(record)
            }
        }
        recordsByZone[zoneKey(zoneID)] = stored
    }

    func acceptShare(at url: URL) async throws -> CKRecordZone.ID {
        calls.append(.acceptShare(url))
        try check(.acceptShare)
        presentZones.insert(zoneKey(acceptedZoneID))
        return acceptedZoneID
    }

    func createDestination(householdID: String, title: String) async throws -> AccountDeletionDestination {
        calls.append(.createDestination(householdID: householdID))
        try check(.createDestination)
        let zone = CKRecordZone.ID(zoneName: SeedkeepRecordNames.zoneName(householdID: householdID),
                                   ownerName: CKCurrentUserDefaultName)
        presentZones.insert(zoneKey(zone))
        // The successor creates and shares the destination Household root
        // BEFORE the copy starts, so the copy always overwrites at least
        // one already-existing record.
        var stored = recordsByZone[zoneKey(zone)] ?? []
        if !stored.contains(where: { $0.recordID.recordName == "household:\(householdID)" }) {
            stored.append(record(.household, "household:\(householdID)", in: zone,
                                 scalars: ["name": title as CKRecordValue,
                                           "createdAt": 9 as CKRecordValue,
                                           "updatedAt": 9 as CKRecordValue]))
        }
        recordsByZone[zoneKey(zone)] = stored
        return AccountDeletionDestination(zoneID: zone,
                                          ownerRecordName: destinationOwnerRecordName,
                                          shareRecordName: CKRecordNameZoneWideShare,
                                          shareURL: destinationShareURL)
    }

    // MARK: Assertion helpers

    var savedBatches: [(names: [String], policy: CKModifyRecordsOperation.RecordSavePolicy)] {
        calls.compactMap {
            if case .saveRecords(_, let names, let policy) = $0 { return (names, policy) }
            return nil
        }
    }

    func records(in zoneID: CKRecordZone.ID) -> [CKRecord] { recordsByZone[zoneKey(zoneID)] ?? [] }
}

// MARK: - Server fake

/// A faithful-enough stand-in for `account-deletion-transfers.ts`: it
/// enforces the real phase order and answers an out-of-order call with the
/// same 409 `phase_conflict` (carrying the durable phase) the server does.
/// A coordinator that guesses instead of reloading fails here.
@MainActor
private final class FakeDeletionServer: AccountDeletionServerOperating {

    enum Op: Hashable {
        case createTransfer, transfer, acceptTransfer, putDestination
        case putOwnerVerification, putSuccessorVerification
        case markSourceDeleted, cancelTransfer, deleteAccount
    }

    enum Call: Equatable {
        case createTransfer
        case transfer(String)
        case acceptTransfer(id: String, token: String)
        case putDestination(id: String, zoneName: String, ownerName: String, shareRecordName: String, shareURL: String?)
        case putOwnerVerification(id: String, digest: String, counts: [String: Int])
        case putSuccessorVerification(id: String, digest: String, counts: [String: Int],
                                      zoneName: String, ownerName: String)
        case markSourceDeleted(String)
        case cancelTransfer(String)
        case deleteAccount(AccountDeletionDisposition)
    }

    private(set) var calls: [Call] = []
    var failures: [Op: Error] = [:]
    var row: AccountDeletionTransferDTO?
    var mintedToken: String? = "handoff-token-abc"
    var handoffExpiresAt: Int64 = 9_000_000_000_000
    var accountDeleted = true
    /// Lets a test hand back a transfer whose digests disagree even though
    /// the phase claims verification succeeded.
    var allowMismatchedVerification = false

    private static func blank(id: String, phase: AccountDeletionTransferPhase,
                              expiresAt: Int64) -> AccountDeletionTransferDTO {
        AccountDeletionTransferDTO(
            id: id, source_household_id: ownerHouseholdID, owner_user_id: "u_owner",
            successor_user_id: nil, phase: phase,
            handoff_expires_at: expiresAt, handoff_consumed_at: nil,
            destination_zone_name: nil, destination_zone_owner_name: nil,
            destination_share_record_name: nil, destination_share_url: nil,
            owner_digest: nil, successor_digest: nil,
            created_at: 1, updated_at: 1, cancelled_at: nil)
    }

    private func updated(
        phase: AccountDeletionTransferPhase? = nil,
        successor: String?? = nil,
        destinationZoneName: String?? = nil,
        destinationZoneOwnerName: String?? = nil,
        destinationShareRecordName: String?? = nil,
        destinationShareURL: String?? = nil,
        ownerDigest: AccountDeletionDigestDTO?? = nil,
        successorDigest: AccountDeletionDigestDTO?? = nil
    ) -> AccountDeletionTransferDTO {
        let current = row!
        let next = AccountDeletionTransferDTO(
            id: current.id,
            source_household_id: current.source_household_id,
            owner_user_id: current.owner_user_id,
            successor_user_id: successor ?? current.successor_user_id,
            phase: phase ?? current.phase,
            handoff_expires_at: current.handoff_expires_at,
            handoff_consumed_at: current.handoff_consumed_at,
            destination_zone_name: destinationZoneName ?? current.destination_zone_name,
            destination_zone_owner_name: destinationZoneOwnerName ?? current.destination_zone_owner_name,
            destination_share_record_name: destinationShareRecordName ?? current.destination_share_record_name,
            destination_share_url: destinationShareURL ?? current.destination_share_url,
            owner_digest: ownerDigest ?? current.owner_digest,
            successor_digest: successorDigest ?? current.successor_digest,
            created_at: current.created_at, updated_at: current.updated_at + 1,
            cancelled_at: current.cancelled_at)
        row = next
        return next
    }

    private func conflict() -> SeedkeepError {
        SeedkeepError(code: "phase_conflict",
                      message: "Transfer is in phase '\(row!.phase.rawValue)'.",
                      conflictPhase: row!.phase.rawValue,
                      httpStatus: 409)
    }

    private func check(_ op: Op) throws {
        if let error = failures[op] { throw error }
    }

    // MARK: Test-side drivers (stand in for the other device)

    /// Seed a durable row in an arbitrary phase, as a relaunched device
    /// would find it.
    func seedRow(id: String = "tr_1", phase: AccountDeletionTransferPhase,
                 ownerDigest: HouseholdGraphDigest? = nil,
                 successorDigest: HouseholdGraphDigest? = nil,
                 destination: Bool = true) {
        row = Self.blank(id: id, phase: phase, expiresAt: handoffExpiresAt)
        _ = updated(
            successor: .some("u_succ"),
            destinationZoneName: .some(destination ? destinationZoneFromOwner.zoneName : nil),
            destinationZoneOwnerName: .some(destination ? successorRecordName : nil),
            destinationShareRecordName: .some(destination ? CKRecordNameZoneWideShare : nil),
            destinationShareURL: .some(destination ? destinationShareURL.absoluteString : nil),
            ownerDigest: .some(ownerDigest.map {
                AccountDeletionDigestDTO(digest: $0.sha256, record_counts: $0.counts, submitted_at: 5)
            }),
            successorDigest: .some(successorDigest.map {
                AccountDeletionDigestDTO(digest: $0.sha256, record_counts: $0.counts, submitted_at: 6)
            }))
    }

    // MARK: AccountDeletionServerOperating

    func createTransfer() async throws -> WireResponses.AccountDeletionTransferOne {
        calls.append(.createTransfer)
        try check(.createTransfer)
        if let existing = row {
            // Only a still-pending transfer whose token expired gets a new
            // one; a plain resume returns the row with no token.
            if existing.phase == .pendingSuccessor, existing.handoff_expires_at <= 1_000 {
                row = Self.blank(id: existing.id, phase: .pendingSuccessor, expiresAt: handoffExpiresAt)
                return .init(transfer: row!, handoff_token: mintedToken)
            }
            return .init(transfer: existing, handoff_token: nil)
        }
        row = Self.blank(id: "tr_1", phase: .pendingSuccessor, expiresAt: handoffExpiresAt)
        return .init(transfer: row!, handoff_token: mintedToken)
    }

    func transfer(id: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.transfer(id))
        try check(.transfer)
        guard let row, row.id == id else { throw SeedkeepError(code: "not_found", message: "no transfer") }
        return row
    }

    func acceptTransfer(id: String, token: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.acceptTransfer(id: id, token: token))
        try check(.acceptTransfer)
        guard let current = row, current.id == id else {
            throw SeedkeepError(code: "not_found", message: "no transfer")
        }
        if current.phase == .successorBound { return current }   // idempotent re-accept
        guard current.phase == .pendingSuccessor else { throw conflict() }
        return updated(phase: .successorBound, successor: .some("u_succ"))
    }

    func putDestination(id: String, zoneName: String, zoneOwnerName: String,
                        shareRecordName: String, shareURL: String?) async throws -> AccountDeletionTransferDTO {
        calls.append(.putDestination(id: id, zoneName: zoneName, ownerName: zoneOwnerName,
                                     shareRecordName: shareRecordName, shareURL: shareURL))
        try check(.putDestination)
        guard let current = row, current.id == id else {
            throw SeedkeepError(code: "not_found", message: "no transfer")
        }
        guard current.phase == .successorBound || current.phase == .destinationReady else { throw conflict() }
        return updated(phase: .destinationReady,
                       destinationZoneName: .some(zoneName),
                       destinationZoneOwnerName: .some(zoneOwnerName),
                       destinationShareRecordName: .some(shareRecordName),
                       destinationShareURL: .some(shareURL))
    }

    func putOwnerVerification(id: String, digest: HouseholdGraphDigest) async throws -> AccountDeletionTransferDTO {
        calls.append(.putOwnerVerification(id: id, digest: digest.sha256, counts: digest.counts))
        try check(.putOwnerVerification)
        guard let current = row, current.id == id else {
            throw SeedkeepError(code: "not_found", message: "no transfer")
        }
        guard current.phase == .destinationReady || current.phase == .ownerVerified else { throw conflict() }
        return updated(phase: .ownerVerified,
                       ownerDigest: .some(AccountDeletionDigestDTO(
                           digest: digest.sha256, record_counts: digest.counts, submitted_at: 5)))
    }

    func putSuccessorVerification(id: String, digest: HouseholdGraphDigest,
                                  destinationZoneName: String,
                                  destinationZoneOwnerName: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.putSuccessorVerification(id: id, digest: digest.sha256, counts: digest.counts,
                                               zoneName: destinationZoneName,
                                               ownerName: destinationZoneOwnerName))
        try check(.putSuccessorVerification)
        guard let current = row, current.id == id else {
            throw SeedkeepError(code: "not_found", message: "no transfer")
        }
        guard current.phase == .ownerVerified else { throw conflict() }
        guard current.destination_zone_name == destinationZoneName,
              current.destination_zone_owner_name == destinationZoneOwnerName else {
            throw SeedkeepError(code: "destination_mismatch", message: "different zone", httpStatus: 409)
        }
        let successorDocument = AccountDeletionDigestDTO(digest: digest.sha256,
                                                         record_counts: digest.counts, submitted_at: 6)
        guard allowMismatchedVerification ||
                (current.owner_digest?.digest == digest.sha256 &&
                 current.owner_digest?.record_counts == digest.counts) else {
            _ = updated(successorDigest: .some(successorDocument))
            throw SeedkeepError(code: "digest_mismatch", message: "copies differ", httpStatus: 409)
        }
        return updated(phase: .verified, successorDigest: .some(successorDocument))
    }

    func markSourceDeleted(id: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.markSourceDeleted(id))
        try check(.markSourceDeleted)
        guard let current = row, current.id == id else {
            throw SeedkeepError(code: "not_found", message: "no transfer")
        }
        if current.phase == .sourceDeleted { return current }
        guard current.phase == .verified else { throw conflict() }
        return updated(phase: .sourceDeleted)
    }

    func cancelTransfer(id: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.cancelTransfer(id))
        try check(.cancelTransfer)
        guard let current = row, current.id == id else {
            throw SeedkeepError(code: "not_found", message: "no transfer")
        }
        if current.phase == .cancelled { return current }
        guard current.phase != .sourceDeleted else { throw conflict() }
        return updated(phase: .cancelled)
    }

    func deleteAccount(disposition: AccountDeletionDisposition) async throws -> Bool {
        calls.append(.deleteAccount(disposition))
        try check(.deleteAccount)
        if case .transferSourceDeleted(let id) = disposition {
            guard let current = row, current.id == id, current.phase == .sourceDeleted else {
                throw SeedkeepError(code: "cloudkit_transfer_required",
                                    message: "no source-deleted transfer", httpStatus: 409)
            }
        }
        return accountDeleted
    }
}

// MARK: - Harness

@MainActor
private final class SignOutRecorder { var count = 0 }

@MainActor
private final class Harness {
    let directory: URL
    let store: AccountDeletionCheckpointStore
    let cloudKit = FakeCloudKit()
    let server = FakeDeletionServer()
    let signOut = SignOutRecorder()
    let coordinator: AccountDeletionCoordinator
    let userID: String

    init(userID: String = "u_owner", householdID: String = ownerHouseholdID, nowMillis: Int64 = 1_700_000_000_000) {
        self.userID = userID
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountDeletionCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AccountDeletionCheckpointStore(directory: directory)
        let recorder = signOut
        coordinator = AccountDeletionCoordinator(
            store: store,
            cloudKit: cloudKit,
            server: server,
            session: AccountDeletionSession(
                identity: { AccountDeletionSession.Identity(userID: userID, householdID: householdID) },
                signOut: { recorder.count += 1 }
            ),
            now: { nowMillis }
        )
    }

    var stored: AccountDeletionCheckpoint? {
        try? store.load(userID: userID)?.checkpoint
    }

    /// Write a checkpoint the way a previous launch would have left it.
    func seedCheckpoint(role: AccountDeletionCheckpoint.Role,
                        phase: AccountDeletionCheckpoint.Phase,
                        transferID: String? = "tr_1",
                        sourceZone: CKRecordZone.ID? = ownerZone,
                        destinationZone: CKRecordZone.ID? = nil,
                        destinationOwnerRecordName: String? = nil) throws {
        try store.save(AccountDeletionCheckpoint(
            userID: userID, role: role, phase: phase, transferID: transferID,
            sourceZoneName: sourceZone?.zoneName,
            sourceZoneOwnerName: sourceZone?.ownerName,
            destinationZoneName: destinationZone?.zoneName,
            destinationZoneOwnerName: destinationOwnerRecordName ?? destinationZone?.ownerName,
            updatedAt: 1))
    }

    /// The full owner set-up: a live source garden and a bound successor
    /// who has already published their destination.
    func stageSharedOwner(serverPhase: AccountDeletionTransferPhase,
                          ownerDigest: HouseholdGraphDigest? = nil,
                          successorDigest: HouseholdGraphDigest? = nil,
                          checkpointPhase: AccountDeletionCheckpoint.Phase? = nil) throws {
        cloudKit.role = .sharedOwner(zoneID: ownerZone)
        cloudKit.seed(zone: ownerZone, records: gardenGraph())
        server.seedRow(phase: serverPhase, ownerDigest: ownerDigest, successorDigest: successorDigest)
        if let checkpointPhase {
            try seedCheckpoint(role: .sharedOwner, phase: checkpointPhase)
        }
    }
}

// MARK: - Owner failure matrix

/// The shared-owner steps that reach outside the device. Each one is
/// broken in turn to prove the same three things: the session survives,
/// the garden survives, and the flow stays resumable at that exact step.
let ownerFailureStepNames = [
    "create transfer",
    "reload while waiting",
    "accept destination share",
    "copy batch",
    "post owner verification",
    "delete source zone",
]

/// Stages `step`'s failure and returns the phase its checkpoint must hold.
@MainActor
private func stageOwnerFailure(_ step: String, in harness: Harness) throws -> AccountDeletionCheckpoint.Phase {
    let boom = SeedkeepError(code: "server_error", message: "boom")
    switch step {
    case "create transfer":
        harness.cloudKit.role = .sharedOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())
        harness.server.failures[.createTransfer] = boom
        try harness.seedCheckpoint(role: .sharedOwner, phase: .transferPending, transferID: nil)
        return .transferPending

    case "reload while waiting":
        try harness.stageSharedOwner(serverPhase: .successorBound)
        harness.server.failures[.transfer] = boom
        try harness.seedCheckpoint(role: .sharedOwner, phase: .successorBound)
        return .successorBound

    case "accept destination share":
        try harness.stageSharedOwner(serverPhase: .destinationReady)
        harness.cloudKit.failures[.acceptShare] = FakeCloudKit.Failure.injected(.acceptShare)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .destinationReady)
        return .destinationReady

    case "copy batch":
        try harness.stageSharedOwner(serverPhase: .destinationReady)
        harness.cloudKit.seed(zone: destinationZoneFromOwner)
        harness.cloudKit.failures[.saveRecords] = FakeCloudKit.Failure.injected(.saveRecords)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .destinationShareAccepted,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)
        return .destinationShareAccepted

    case "post owner verification":
        try harness.stageSharedOwner(serverPhase: .destinationReady)
        harness.cloudKit.seed(zone: destinationZoneFromOwner,
                              records: gardenGraph(in: destinationZoneFromOwner))
        harness.server.failures[.putOwnerVerification] = boom
        try harness.seedCheckpoint(role: .sharedOwner, phase: .copyComplete,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)
        return .copyComplete

    case "delete source zone":
        let digest = try gardenDigest()
        try harness.stageSharedOwner(serverPhase: .verified, ownerDigest: digest, successorDigest: digest)
        harness.cloudKit.failures[.deleteOwnedZone] = FakeCloudKit.Failure.injected(.deleteOwnedZone)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .verified,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)
        return .verified

    default:
        Issue.record("unknown owner failure step \(step)")
        return .transferPending
    }
}

// MARK: - Tests

@MainActor
@Suite("Account-deletion coordinator")
struct AccountDeletionCoordinatorTests {

    // MARK: Role routing

    @Test("no iCloud garden: deletes the account and signs out, nothing CloudKit")
    func noGardenFlow() async throws {
        let harness = Harness()
        harness.cloudKit.role = .noGarden

        let outcome = try await harness.coordinator.start()

        #expect(outcome == .deleted)
        #expect(harness.server.calls == [.deleteAccount(.noCloudKitGarden)])
        #expect(harness.cloudKit.calls == [.currentRole])
        #expect(harness.signOut.count == 1)
        #expect(harness.stored == nil)
    }

    @Test("participant: leaves the share, verifies absence, then deletes the account")
    func participantFlow() async throws {
        let harness = Harness()
        harness.cloudKit.role = .participant(sharedZoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone)

        let outcome = try await harness.coordinator.start()

        #expect(outcome == .deleted)
        #expect(harness.cloudKit.calls == [
            .currentRole,
            .leaveSharedGarden(zoneKey(ownerZone)),
            .sharedZoneIsAbsent(zoneKey(ownerZone)),
        ])
        #expect(harness.server.calls == [.deleteAccount(.participantLeftShare)])
        #expect(harness.signOut.count == 1)
        #expect(harness.stored == nil)
    }

    @Test("solo owner: deletes the zone, verifies absence, then deletes the account")
    func soloOwnerFlow() async throws {
        let harness = Harness()
        harness.cloudKit.role = .soloOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())

        let outcome = try await harness.coordinator.start()

        #expect(outcome == .deleted)
        #expect(harness.cloudKit.calls == [
            .currentRole,
            .deleteOwnedZone(zoneKey(ownerZone)),
            .ownedZoneIsAbsent(zoneKey(ownerZone)),
        ])
        #expect(harness.server.calls == [.deleteAccount(.ownerZoneDeleted)])
        #expect(harness.signOut.count == 1)
    }

    @Test("shared owner: start only opens the transfer and waits for a successor")
    func sharedOwnerStartsTransfer() async throws {
        let harness = Harness()
        harness.cloudKit.role = .sharedOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())

        let outcome = try await harness.coordinator.start()

        #expect(outcome == .waiting(.transferPending))
        #expect(harness.server.calls == [.createTransfer])
        #expect(harness.coordinator.handoff?.transferID == "tr_1")
        #expect(harness.coordinator.handoff?.token == "handoff-token-abc")
        // The token is a live capability; it must never reach the disk.
        let checkpoint = try #require(harness.stored)
        #expect(checkpoint.role == .sharedOwner)
        #expect(checkpoint.phase == .transferPending)
        #expect(checkpoint.transferID == "tr_1")
        #expect(checkpoint.sourceZoneName == ownerZone.zoneName)
        let raw = try String(contentsOf: harness.store.url(forUserID: harness.userID), encoding: .utf8)
        #expect(!raw.contains("handoff-token-abc"))
        // Nothing irreversible, and nothing that ends the session.
        #expect(harness.signOut.count == 0)
        #expect(harness.cloudKit.calls == [.currentRole])
    }

    @Test("start persists the checkpoint before the first irreversible CloudKit step")
    func checkpointPrecedesCloudKitWork() async throws {
        let harness = Harness()
        harness.cloudKit.role = .participant(sharedZoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone)
        harness.cloudKit.failures[.leaveSharedGarden] = FakeCloudKit.Failure.injected(.leaveSharedGarden)

        await #expect(throws: FakeCloudKit.Failure.injected(.leaveSharedGarden)) {
            try await harness.coordinator.start()
        }

        let checkpoint = try #require(harness.stored)
        #expect(checkpoint.role == .participant)
        #expect(checkpoint.phase == .participantLeaving)
        #expect(checkpoint.lastFailure?.phase == .participantLeaving)
        #expect(harness.server.calls.isEmpty)
        #expect(harness.signOut.count == 0)
    }

    @Test("an already-running deletion resumes instead of re-deciding its role")
    func startResumesExistingCheckpoint() async throws {
        let harness = Harness()
        try harness.seedCheckpoint(role: .soloOwner, phase: .deletingAccount, transferID: nil)

        let outcome = try await harness.coordinator.start()

        #expect(outcome == .deleted)
        // No role inspection and — critically — no second zone deletion.
        #expect(harness.cloudKit.calls.isEmpty)
        #expect(harness.server.calls == [.deleteAccount(.ownerZoneDeleted)])
    }

    // MARK: Fail-closed CloudKit verification

    @Test("participant: a share that is still readable stops the flow before the server call")
    func participantZoneStillPresent() async throws {
        let harness = Harness()
        harness.cloudKit.role = .participant(sharedZoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone)
        harness.cloudKit.deletionIsNoop = true

        await #expect(throws: AccountDeletionCoordinatorError.zoneStillPresent(zoneName: ownerZone.zoneName)) {
            try await harness.coordinator.start()
        }

        #expect(harness.server.calls.isEmpty)
        #expect(harness.signOut.count == 0)
        #expect(harness.stored?.phase == .participantLeaving)
    }

    @Test("solo owner: a zone that survives deletion stops the flow before the server call")
    func soloOwnerZoneStillPresent() async throws {
        let harness = Harness()
        harness.cloudKit.role = .soloOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())
        harness.cloudKit.deletionIsNoop = true

        await #expect(throws: AccountDeletionCoordinatorError.zoneStillPresent(zoneName: ownerZone.zoneName)) {
            try await harness.coordinator.start()
        }

        #expect(harness.server.calls.isEmpty)
        #expect(harness.signOut.count == 0)
        #expect(harness.stored?.phase == .ownerDeletingZone)
    }

    // MARK: Shared-owner transfer

    @Test("shared owner: accept, copy, verify, delete source, delete account — in that order")
    func sharedOwnerFullSequence() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .destinationReady, checkpointPhase: .destinationReady)

        // 1. Accept the destination share and copy the garden into it.
        let afterCopy = try await harness.coordinator.resume()
        #expect(afterCopy == .waiting(.ownerVerified))

        let expected = try gardenDigest()
        #expect(harness.server.calls.contains(
            .putOwnerVerification(id: "tr_1", digest: expected.sha256, counts: expected.counts)))
        #expect(harness.stored?.phase == .ownerVerified)
        #expect(harness.stored?.destinationZoneName == destinationZoneFromOwner.zoneName)
        #expect(harness.stored?.destinationZoneOwnerName == successorRecordName)
        // Source still intact — nothing verified on the other side yet.
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))

        // 2. The successor posts a matching digest; the server re-homes.
        let destinationDigest = try HouseholdGraphDigester.digest(
            of: harness.cloudKit.records(in: destinationZoneFromOwner), in: destinationZoneFromOwner)
        #expect(destinationDigest == expected)
        _ = try await harness.server.putSuccessorVerification(
            id: "tr_1", digest: destinationDigest,
            destinationZoneName: destinationZoneFromOwner.zoneName,
            destinationZoneOwnerName: successorRecordName)

        // 3. Now — and only now — the source may go.
        let outcome = try await harness.coordinator.resume()
        #expect(outcome == .deleted)

        #expect(harness.cloudKit.calls == [
            .acceptShare(destinationShareURL),
            .fetchRecords(zoneKey(ownerZone)),
            .saveRecords(zone: zoneKey(destinationZoneFromOwner),
                         names: ["household:hh_owner", "location:l1", "seed:s1"], policy: .allKeys),
            .saveRecords(zone: zoneKey(destinationZoneFromOwner),
                         names: ["seedPhoto:p1"], policy: .allKeys),
            .fetchRecords(zoneKey(destinationZoneFromOwner)),
            .deleteOwnedZone(zoneKey(ownerZone)),
            .ownedZoneIsAbsent(zoneKey(ownerZone)),
        ])
        #expect(harness.server.calls.last == .deleteAccount(.transferSourceDeleted(transferID: "tr_1")))
        #expect(harness.server.calls.dropLast().contains(.markSourceDeleted("tr_1")))
        #expect(harness.signOut.count == 1)
        #expect(harness.stored == nil)
    }

    @Test("copy batches are saved parents-first and always with the all-keys policy")
    func copyOrderingAndSavePolicy() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .destinationReady, checkpointPhase: .destinationReady)

        _ = try await harness.coordinator.resume()

        let batches = harness.cloudKit.savedBatches
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.policy == .allKeys })
        // The cascade child cannot be saved before the parent it deletes with.
        #expect(batches[0].names == ["household:hh_owner", "location:l1", "seed:s1"])
        #expect(batches[1].names == ["seedPhoto:p1"])
    }

    @Test("copy overwrites the successor's pre-existing Household root")
    func copyOverwritesExistingRoot() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .destinationReady, checkpointPhase: .destinationReady)
        // The successor's own root, already in the destination zone.
        harness.cloudKit.seed(zone: destinationZoneFromOwner, records: [
            record(.household, "household:hh_owner", in: destinationZoneFromOwner,
                   scalars: ["name": "Successor's placeholder" as CKRecordValue,
                             "createdAt": 7 as CKRecordValue, "updatedAt": 7 as CKRecordValue])
        ])

        _ = try await harness.coordinator.resume()

        let copied = harness.cloudKit.records(in: destinationZoneFromOwner)
        let root = try #require(copied.first { $0.recordID.recordName == "household:hh_owner" })
        #expect(root["name"] as? String == "Finklea Garden")
        #expect(copied.count == 4)
    }

    @Test("owner refuses to copy into a zone the server did not record as the destination")
    func destinationOwnershipMismatchBeforeCopy() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .destinationReady, checkpointPhase: .destinationReady)
        // The accepted share resolves to somebody else's zone.
        harness.cloudKit.acceptedZoneID = CKRecordZone.ID(zoneName: "seedkeep-hh_owner",
                                                          ownerName: "_impostor")

        await #expect(throws: AccountDeletionCoordinatorError.destinationOwnershipMismatch(
            expected: "\(destinationZoneFromOwner.zoneName)|\(successorRecordName)",
            found: "seedkeep-hh_owner|_impostor")) {
            try await harness.coordinator.resume()
        }

        #expect(harness.cloudKit.savedBatches.isEmpty)
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))
        #expect(harness.signOut.count == 0)
    }

    @Test("owner refuses to proceed when the successor never published a share URL")
    func destinationShareURLMissing() async throws {
        let harness = Harness()
        harness.cloudKit.role = .sharedOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())
        harness.server.seedRow(phase: .destinationReady, destination: false)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .destinationReady)

        await #expect(throws: AccountDeletionCoordinatorError.destinationUnavailable) {
            try await harness.coordinator.resume()
        }
        #expect(harness.cloudKit.calls.isEmpty)
    }

    @Test("a source zone that has vanished mid-copy is an error, never a completed deletion")
    func absentSourceDuringCopyIsNotDeletion() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .destinationReady, checkpointPhase: .destinationReady)
        harness.cloudKit.presentZones.remove(zoneKey(ownerZone))   // zone gone before the copy

        await #expect(throws: CKError.self) {
            try await harness.coordinator.resume()
        }

        #expect(!harness.server.calls.contains(.markSourceDeleted("tr_1")))
        #expect(!harness.server.calls.contains(where: {
            if case .deleteAccount = $0 { return true }
            return false
        }))
        #expect(harness.signOut.count == 0)
        #expect(harness.stored?.phase == .destinationShareAccepted)
    }

    // MARK: Source-preservation guards

    @Test("owner will not delete the source while only its own digest is on file")
    func sourceKeptUntilBothDigests() async throws {
        let harness = Harness()
        let digest = try gardenDigest()
        try harness.stageSharedOwner(serverPhase: .ownerVerified, ownerDigest: digest)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .verified,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        let outcome = try await harness.coordinator.resume()

        // The server is behind the local checkpoint: reload, do not guess.
        #expect(outcome == .waiting(.ownerVerified))
        #expect(harness.stored?.phase == .ownerVerified)
        #expect(!harness.cloudKit.calls.contains(.deleteOwnedZone(zoneKey(ownerZone))))
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))
    }

    @Test("owner will not delete the source when the two digests disagree")
    func sourceKeptWhenDigestsDiffer() async throws {
        let harness = Harness()
        let ownerDigest = try gardenDigest()
        let otherDigest = HouseholdGraphDigest(sha256: String(repeating: "a", count: 64),
                                               counts: ["Seed": 1])
        try harness.stageSharedOwner(serverPhase: .verified,
                                 ownerDigest: ownerDigest, successorDigest: otherDigest)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .verified,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        await #expect(throws: AccountDeletionCoordinatorError.digestMismatch(
            owner: ownerDigest.sha256, successor: otherDigest.sha256)) {
            try await harness.coordinator.resume()
        }

        #expect(!harness.cloudKit.calls.contains(.deleteOwnedZone(zoneKey(ownerZone))))
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))
        #expect(harness.signOut.count == 0)
    }

    @Test("owner will not delete the source when the per-type counts disagree")
    func sourceKeptWhenCountsDiffer() async throws {
        let harness = Harness()
        let ownerDigest = try gardenDigest()
        let sameHashFewerRecords = HouseholdGraphDigest(sha256: ownerDigest.sha256, counts: ["Seed": 1])
        try harness.stageSharedOwner(serverPhase: .verified,
                                 ownerDigest: ownerDigest, successorDigest: sameHashFewerRecords)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .verified,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        await #expect(throws: AccountDeletionCoordinatorError.recordCountMismatch(
            owner: ownerDigest.counts, successor: sameHashFewerRecords.counts)) {
            try await harness.coordinator.resume()
        }
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))
    }

    @Test("owner will not delete the source when the recorded destination moved")
    func sourceKeptWhenDestinationChanged() async throws {
        let harness = Harness()
        let digest = try gardenDigest()
        try harness.stageSharedOwner(serverPhase: .verified, ownerDigest: digest, successorDigest: digest)
        // The checkpoint remembers a destination the server no longer names.
        try harness.seedCheckpoint(role: .sharedOwner, phase: .verified,
                                   destinationZone: CKRecordZone.ID(zoneName: "seedkeep-hh_owner",
                                                                    ownerName: "_someone_else"),
                                   destinationOwnerRecordName: "_someone_else")

        await #expect(throws: AccountDeletionCoordinatorError.destinationOwnershipMismatch(
            expected: "\(destinationZoneFromOwner.zoneName)|\(successorRecordName)",
            found: "seedkeep-hh_owner|_someone_else")) {
            try await harness.coordinator.resume()
        }
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))
    }

    // MARK: Resume from every checkpoint

    @Test("resume at destination-share-accepted copies without re-accepting the share")
    func resumeFromShareAccepted() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .destinationReady)
        harness.cloudKit.seed(zone: destinationZoneFromOwner)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .destinationShareAccepted,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        _ = try await harness.coordinator.resume()

        #expect(!harness.cloudKit.calls.contains(.acceptShare(destinationShareURL)))
        #expect(harness.cloudKit.savedBatches.count == 2)
        #expect(harness.stored?.phase == .ownerVerified)
    }

    @Test("resume at copy-complete re-posts the digest instead of recopying the garden")
    func resumeFromCopyComplete() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .destinationReady)
        harness.cloudKit.seed(zone: destinationZoneFromOwner, records: gardenGraph(in: destinationZoneFromOwner))
        try harness.seedCheckpoint(role: .sharedOwner, phase: .copyComplete,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .waiting(.ownerVerified))
        #expect(harness.cloudKit.savedBatches.isEmpty)
        #expect(harness.cloudKit.calls == [.fetchRecords(zoneKey(destinationZoneFromOwner))])
    }

    @Test("resume at source-zone-deleted skips CloudKit and finishes on the server")
    func resumeFromSourceZoneDeleted() async throws {
        let harness = Harness()
        let digest = try gardenDigest()
        try harness.stageSharedOwner(serverPhase: .verified, ownerDigest: digest, successorDigest: digest)
        harness.cloudKit.presentZones.remove(zoneKey(ownerZone))   // it really is gone
        try harness.seedCheckpoint(role: .sharedOwner, phase: .sourceZoneDeleted,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .deleted)
        #expect(harness.cloudKit.calls.isEmpty)
        #expect(harness.server.calls == [
            .markSourceDeleted("tr_1"),
            .deleteAccount(.transferSourceDeleted(transferID: "tr_1")),
        ])
        #expect(harness.signOut.count == 1)
    }

    @Test("resume at deleting-account only calls DELETE /api/me")
    func resumeFromDeletingAccount() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .sourceDeleted)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .deletingAccount)

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .deleted)
        #expect(harness.cloudKit.calls.isEmpty)
        #expect(harness.server.calls == [.deleteAccount(.transferSourceDeleted(transferID: "tr_1"))])
    }

    @Test("resume with no checkpoint does nothing at all")
    func resumeWithoutCheckpoint() async throws {
        let harness = Harness()
        #expect(try await harness.coordinator.resume() == .idle)
        #expect(harness.cloudKit.calls.isEmpty)
        #expect(harness.server.calls.isEmpty)
    }

    @Test("an expired handoff is re-issued rather than left dead")
    func expiredHandoffIsReissued() async throws {
        let harness = Harness(nowMillis: 2_000)
        harness.cloudKit.role = .sharedOwner(zoneID: ownerZone)
        harness.server.handoffExpiresAt = 1_000
        harness.server.seedRow(phase: .pendingSuccessor, destination: false)
        harness.server.handoffExpiresAt = 9_000_000_000_000
        try harness.seedCheckpoint(role: .sharedOwner, phase: .transferPending)

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .waiting(.transferPending))
        #expect(harness.server.calls == [.transfer("tr_1"), .createTransfer])
        #expect(harness.coordinator.handoff?.token == "handoff-token-abc")
    }

    // MARK: Server phase conflicts

    @Test("a phase conflict adopts the durable server phase instead of guessing")
    func phaseConflictReloads() async throws {
        let harness = Harness()
        let digest = try gardenDigest()
        // Local state says "post source-deleted", but another device already
        // did — the server is at source_deleted.
        try harness.stageSharedOwner(serverPhase: .sourceDeleted, ownerDigest: digest, successorDigest: digest)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .verified,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .deleted)
        // The source zone is already gone server-side; nothing re-deletes it.
        #expect(!harness.cloudKit.calls.contains(.deleteOwnedZone(zoneKey(ownerZone))))
        #expect(harness.server.calls.last == .deleteAccount(.transferSourceDeleted(transferID: "tr_1")))
    }

    @Test("a conflict that rewinds the flow rewrites the checkpoint to the durable phase")
    func phaseConflictRewinds() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .successorBound)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .copyComplete,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)
        harness.cloudKit.seed(zone: destinationZoneFromOwner, records: gardenGraph(in: destinationZoneFromOwner))

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .waiting(.successorBound))
        #expect(harness.stored?.phase == .successorBound)
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))
        #expect(harness.signOut.count == 0)
    }

    @Test("a transfer cancelled after the source zone is gone fails closed, credentials intact")
    func cancelledAfterSourceDeletionFailsClosed() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .cancelled)
        harness.cloudKit.presentZones.remove(zoneKey(ownerZone))
        try harness.seedCheckpoint(role: .sharedOwner, phase: .sourceZoneDeleted,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        await #expect(throws: AccountDeletionCoordinatorError.transferCancelledAfterSourceDeletion(
            transferID: "tr_1")) {
            try await harness.coordinator.resume()
        }

        #expect(harness.signOut.count == 0)
        #expect(harness.stored?.phase == .sourceZoneDeleted)
        #expect(!harness.server.calls.contains(where: {
            if case .deleteAccount = $0 { return true }
            return false
        }))
    }

    @Test("a transfer cancelled while the source is intact clears the checkpoint and stops")
    func cancelledBeforeSourceDeletionEndsFlow() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .cancelled)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .copyComplete,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)
        harness.cloudKit.seed(zone: destinationZoneFromOwner, records: gardenGraph(in: destinationZoneFromOwner))

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .idle)
        #expect(harness.stored == nil)
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))
        #expect(harness.signOut.count == 0)
    }

    // MARK: Cancellation

    @Test("cancel before source deletion cancels the transfer and clears the checkpoint")
    func cancelBeforeSourceDeletion() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .ownerVerified)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .ownerVerified,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        try await harness.coordinator.cancel()

        #expect(harness.server.calls == [.cancelTransfer("tr_1")])
        #expect(harness.stored == nil)
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)))
        #expect(harness.signOut.count == 0)
    }

    @Test("cancel is refused once the source zone is gone")
    func cancelRefusedAfterSourceDeletion() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .verified)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .sourceZoneDeleted,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        await #expect(throws: AccountDeletionCoordinatorError.cancelAfterSourceDeletion) {
            try await harness.coordinator.cancel()
        }

        #expect(harness.server.calls.isEmpty)
        #expect(harness.stored?.phase == .sourceZoneDeleted)
    }

    @Test("a cancelled task stops before any external work and leaves the checkpoint alone")
    func taskCancellationStopsBeforeSideEffects() async throws {
        let harness = Harness()
        try harness.stageSharedOwner(serverPhase: .destinationReady)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .destinationReady)

        let task = Task { try await harness.coordinator.resume() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(harness.cloudKit.calls.isEmpty)
        #expect(harness.server.calls.isEmpty)
        #expect(harness.stored?.phase == .destinationReady)
    }

    // MARK: Successor handoff

    @Test("successor: proves participation, accepts, builds the destination, posts it")
    func successorAcceptsAndPublishesDestination() async throws {
        let harness = Harness(userID: "u_succ", householdID: "hh_succ")
        harness.cloudKit.role = .participant(sharedZoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())
        harness.server.seedRow(phase: .pendingSuccessor, destination: false)

        let outcome = try await harness.coordinator.acceptHandoff(transferID: "tr_1", token: "tok")

        #expect(outcome == .waiting(.destinationReady))
        #expect(harness.cloudKit.calls == [
            .currentRole,
            .createDestination(householdID: ownerHouseholdID),
        ])
        #expect(harness.server.calls == [
            .acceptTransfer(id: "tr_1", token: "tok"),
            .putDestination(id: "tr_1", zoneName: destinationZoneFromSuccessor.zoneName,
                            ownerName: successorRecordName,
                            shareRecordName: CKRecordNameZoneWideShare,
                            shareURL: destinationShareURL.absoluteString),
        ])
        let checkpoint = try #require(harness.stored)
        #expect(checkpoint.role == .successor)
        #expect(checkpoint.phase == .destinationReady)
        #expect(checkpoint.transferID == "tr_1")
        #expect(checkpoint.destinationZoneName == destinationZoneFromSuccessor.zoneName)
        #expect(checkpoint.destinationZoneOwnerName == successorRecordName)
        #expect(checkpoint.disposition == nil)
        #expect(harness.signOut.count == 0)
    }

    @Test("successor: a device with no accepted share cannot spend the handoff token")
    func successorMustBeAParticipant() async throws {
        let harness = Harness(userID: "u_succ", householdID: "hh_succ")
        harness.cloudKit.role = .soloOwner(zoneID: CKRecordZone.ID(zoneName: "seedkeep-hh_succ",
                                                                   ownerName: CKCurrentUserDefaultName))

        await #expect(throws: AccountDeletionCoordinatorError.notASourceParticipant) {
            try await harness.coordinator.acceptHandoff(transferID: "tr_1", token: "tok")
        }

        #expect(harness.server.calls.isEmpty)
        #expect(harness.stored == nil)
    }

    @Test("successor: a handoff for a garden this device cannot see builds nothing")
    func successorRejectsForeignSourceHousehold() async throws {
        let harness = Harness(userID: "u_succ", householdID: "hh_succ")
        // Participant of a DIFFERENT owner's garden than the transfer names.
        let otherZone = CKRecordZone.ID(zoneName: "seedkeep-hh_stranger", ownerName: "_stranger")
        harness.cloudKit.role = .participant(sharedZoneID: otherZone)
        harness.cloudKit.seed(zone: otherZone)
        harness.server.seedRow(phase: .pendingSuccessor, destination: false)

        await #expect(throws: AccountDeletionCoordinatorError.sourceHouseholdMismatch(
            expected: ownerHouseholdID, found: "hh_stranger")) {
            try await harness.coordinator.acceptHandoff(transferID: "tr_1", token: "tok")
        }

        #expect(!harness.cloudKit.calls.contains(.createDestination(householdID: ownerHouseholdID)))
        #expect(harness.stored == nil)
    }

    @Test("successor: resume digests the destination and posts verification once the owner has")
    func successorVerifiesAfterOwner() async throws {
        let harness = Harness(userID: "u_succ", householdID: "hh_succ")
        let digest = try gardenDigest(in: destinationZoneFromSuccessor)
        harness.cloudKit.seed(zone: destinationZoneFromSuccessor,
                              records: gardenGraph(in: destinationZoneFromSuccessor))
        harness.server.seedRow(phase: .ownerVerified, ownerDigest: digest)
        try harness.seedCheckpoint(role: .successor, phase: .destinationReady,
                                   sourceZone: ownerZone,
                                   destinationZone: destinationZoneFromSuccessor,
                                   destinationOwnerRecordName: successorRecordName)

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .handoffComplete)
        #expect(harness.server.calls == [
            .transfer("tr_1"),
            .putSuccessorVerification(id: "tr_1", digest: digest.sha256, counts: digest.counts,
                                      zoneName: destinationZoneFromSuccessor.zoneName,
                                      ownerName: successorRecordName),
        ])
        #expect(harness.server.row?.phase == .verified)
        #expect(harness.stored == nil)
        // The successor is finishing somebody else's handoff.
        #expect(harness.signOut.count == 0)
    }

    @Test("successor: waits while the owner is still copying")
    func successorWaitsForOwner() async throws {
        let harness = Harness(userID: "u_succ", householdID: "hh_succ")
        harness.cloudKit.seed(zone: destinationZoneFromSuccessor,
                              records: gardenGraph(in: destinationZoneFromSuccessor))
        harness.server.seedRow(phase: .destinationReady)
        try harness.seedCheckpoint(role: .successor, phase: .destinationReady,
                                   destinationZone: destinationZoneFromSuccessor,
                                   destinationOwnerRecordName: successorRecordName)

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .waiting(.destinationReady))
        #expect(harness.server.calls == [.transfer("tr_1")])
        #expect(harness.cloudKit.calls.isEmpty)
        #expect(harness.stored?.phase == .destinationReady)
    }

    @Test("successor: resume at destination-zone-created adopts the same zone and re-posts it")
    func successorResumesFromZoneCreated() async throws {
        let harness = Harness(userID: "u_succ", householdID: "hh_succ")
        harness.cloudKit.seed(zone: destinationZoneFromSuccessor)
        harness.server.seedRow(phase: .successorBound, destination: false)
        try harness.seedCheckpoint(role: .successor, phase: .destinationZoneCreated,
                                   destinationZone: destinationZoneFromSuccessor,
                                   destinationOwnerRecordName: successorRecordName)

        let outcome = try await harness.coordinator.resume()

        #expect(outcome == .waiting(.destinationReady))
        // The share URL is a capability and is never written to disk, so a
        // cold resume re-derives the destination. That must ADOPT the zone
        // the interrupted attempt built, never fork a second one.
        #expect(harness.server.calls == [
            .putDestination(id: "tr_1", zoneName: destinationZoneFromSuccessor.zoneName,
                            ownerName: successorRecordName,
                            shareRecordName: CKRecordNameZoneWideShare,
                            shareURL: destinationShareURL.absoluteString),
        ])
        #expect(harness.cloudKit.presentZones == [zoneKey(destinationZoneFromSuccessor)])
        #expect(harness.stored?.destinationZoneName == destinationZoneFromSuccessor.zoneName)
    }

    @Test("successor: a re-derived destination in a different zone is refused")
    func successorRefusesForkedDestination() async throws {
        let harness = Harness(userID: "u_succ", householdID: "hh_succ")
        harness.server.seedRow(phase: .successorBound, destination: false)
        // The checkpoint remembers a zone `createDestination` will not
        // reproduce — a forked destination the owner would never see.
        try harness.seedCheckpoint(role: .successor, phase: .destinationZoneCreated,
                                   destinationZone: CKRecordZone.ID(zoneName: "seedkeep-hh_elsewhere",
                                                                    ownerName: CKCurrentUserDefaultName),
                                   destinationOwnerRecordName: successorRecordName)

        await #expect(throws: AccountDeletionCoordinatorError.destinationOwnershipMismatch(
            expected: "seedkeep-hh_elsewhere|\(successorRecordName)",
            found: "\(destinationZoneFromSuccessor.zoneName)|\(successorRecordName)")) {
            try await harness.coordinator.resume()
        }
        #expect(!harness.server.calls.contains(where: {
            if case .putDestination = $0 { return true }
            return false
        }))
    }

    @Test("successor: mismatched digests keep the handoff open for a retry")
    func successorDigestMismatchIsRetryable() async throws {
        let harness = Harness(userID: "u_succ", householdID: "hh_succ")
        let wrongOwnerDigest = HouseholdGraphDigest(sha256: String(repeating: "b", count: 64),
                                                    counts: ["Seed": 99])
        harness.cloudKit.seed(zone: destinationZoneFromSuccessor,
                              records: gardenGraph(in: destinationZoneFromSuccessor))
        harness.server.seedRow(phase: .ownerVerified, ownerDigest: wrongOwnerDigest)
        try harness.seedCheckpoint(role: .successor, phase: .destinationReady,
                                   destinationZone: destinationZoneFromSuccessor,
                                   destinationOwnerRecordName: successorRecordName)

        await #expect(throws: SeedkeepError.self) {
            try await harness.coordinator.resume()
        }

        let checkpoint = try #require(harness.stored)
        #expect(checkpoint.phase == .ownerVerified)
        #expect(checkpoint.lastFailure?.phase == .ownerVerified)
        #expect(harness.server.row?.phase == .ownerVerified)
    }

    // MARK: Credentials survive every failure

    /// Every externally-failing shared-owner step, named by the step it
    /// breaks. None of them may reach `DELETE /api/me` or sign the user
    /// out, and all of them must leave a resumable checkpoint behind.
    ///
    /// Parameterized by name rather than by a case struct so the argument
    /// type stays as visible as the test that consumes it; `stageOwnerFailure`
    /// maps the name onto the set-up and the phase the checkpoint must hold.
    @Test("credentials and checkpoint survive a failure at any shared-owner step",
          arguments: ownerFailureStepNames)
    func credentialsSurviveOwnerFailures(_ step: String) async throws {
        let harness = Harness()
        let phase = try stageOwnerFailure(step, in: harness)

        await #expect(throws: (any Error).self) {
            try await harness.coordinator.resume()
        }

        #expect(harness.signOut.count == 0, "sign-out must never run before the server confirms deletion")
        #expect(!harness.server.calls.contains(where: {
            if case .deleteAccount = $0 { return true }
            return false
        }), "DELETE /api/me must be last, and this step never got there")
        let checkpoint = try #require(harness.stored, "the flow must stay resumable")
        #expect(checkpoint.phase == phase)
        #expect(checkpoint.lastFailure?.phase == phase)
        #expect(harness.cloudKit.presentZones.contains(zoneKey(ownerZone)),
                "the source garden must still exist")
    }

    @Test("a failure to record source deletion keeps the account alive and resumable")
    func markSourceDeletedFailureKeepsAccount() async throws {
        let harness = Harness()
        let digest = try gardenDigest()
        try harness.stageSharedOwner(serverPhase: .verified, ownerDigest: digest, successorDigest: digest)
        harness.cloudKit.presentZones.remove(zoneKey(ownerZone))
        harness.server.failures[.markSourceDeleted] = SeedkeepError(code: "server_error", message: "boom")
        try harness.seedCheckpoint(role: .sharedOwner, phase: .sourceZoneDeleted,
                                   destinationZone: destinationZoneFromOwner,
                                   destinationOwnerRecordName: successorRecordName)

        await #expect(throws: SeedkeepError.self) { try await harness.coordinator.resume() }

        #expect(harness.signOut.count == 0)
        #expect(harness.stored?.phase == .sourceZoneDeleted)
    }

    @Test("a failed DELETE /api/me leaves the session signed in and the checkpoint in place")
    func deleteAccountFailureKeepsSession() async throws {
        let harness = Harness()
        harness.cloudKit.role = .soloOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())
        harness.server.failures[.deleteAccount] = SeedkeepError(code: "server_error", message: "boom")

        await #expect(throws: SeedkeepError.self) { try await harness.coordinator.start() }

        #expect(harness.signOut.count == 0)
        #expect(harness.stored?.phase == .deletingAccount)
        #expect(harness.stored?.lastFailure?.phase == .deletingAccount)
    }

    @Test("a server that declines to delete the account does not sign the user out")
    func deleteAccountDeclinedKeepsSession() async throws {
        let harness = Harness()
        harness.cloudKit.role = .noGarden
        harness.server.accountDeleted = false

        await #expect(throws: AccountDeletionCoordinatorError.accountDeletionNotConfirmed) {
            try await harness.coordinator.start()
        }

        #expect(harness.signOut.count == 0)
        #expect(harness.stored?.phase == .deletingAccount)
    }

    // MARK: Store failures

    @Test("an unreadable checkpoint stops the flow rather than starting a fresh one")
    func unreadableCheckpointFailsClosed() async throws {
        let harness = Harness()
        harness.cloudKit.role = .soloOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())
        try Data("{not json".utf8).write(to: harness.store.url(forUserID: harness.userID))

        await #expect(throws: AccountDeletionCheckpointStore.Failure.unreadable(userID: harness.userID)) {
            try await harness.coordinator.start()
        }

        #expect(harness.cloudKit.calls.isEmpty)
        #expect(harness.server.calls.isEmpty)
        #expect(harness.signOut.count == 0)
    }

    @Test("a checkpoint another writer moved on is surfaced, not overwritten")
    func staleLeaseIsSurfaced() async throws {
        let harness = Harness()
        harness.cloudKit.role = .soloOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph())
        // A second window advances the same record mid-step, after this
        // coordinator took its lease and before it writes the next phase.
        harness.cloudKit.onCall = { [store = harness.store, userID = harness.userID] op in
            guard op == .ownedZoneIsAbsent, let loaded = try? store.load(userID: userID) else { return }
            var moved = loaded.checkpoint
            moved.updatedAt += 1
            _ = try? store.save(moved, lease: loaded.lease)
        }

        await #expect(throws: AccountDeletionCheckpointStore.Failure.staleSave(userID: harness.userID)) {
            try await harness.coordinator.start()
        }

        // Last-writer-wins here would rewind a phase or resurrect a finished
        // flow, so the write is refused — and refusing it must not carry the
        // flow forward into the account deletion.
        #expect(harness.signOut.count == 0)
        #expect(!harness.server.calls.contains(where: {
            if case .deleteAccount = $0 { return true }
            return false
        }))
    }

    @Test("no signed-in user means no deletion to run")
    func requiresIdentity() async throws {
        let harness = Harness()
        let coordinator = AccountDeletionCoordinator(
            store: harness.store,
            cloudKit: harness.cloudKit,
            server: harness.server,
            session: AccountDeletionSession(identity: { nil }, signOut: {}),
            now: { 0 }
        )

        await #expect(throws: AccountDeletionCoordinatorError.notSignedIn) {
            try await coordinator.start()
        }
        #expect(harness.cloudKit.calls.isEmpty)
    }
}
