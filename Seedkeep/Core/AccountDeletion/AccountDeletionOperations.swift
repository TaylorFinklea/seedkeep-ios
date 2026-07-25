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
    /// `POST /transfers/:id/source-deleting` — acquire the exclusive
    /// source-deletion lease. The server CAS-moves `verified` →
    /// `source_deleting`, revalidates that the successor still owns the
    /// re-homed household, and permanently closes cancellation. Nothing
    /// may delete the source zone without holding this.
    func acquireSourceDeletionLease(id: String) async throws -> AccountDeletionTransferDTO
    func markSourceDeleted(id: String) async throws -> AccountDeletionTransferDTO
    func cancelTransfer(id: String) async throws -> AccountDeletionTransferDTO

    /// `POST /transfers/:id/inspect` — read a handoff WITHOUT consuming
    /// its single-use token or binding a successor, so a device can check
    /// it is looking at the right garden before spending the one chance
    /// the rightful participant has.
    func inspectHandoff(id: String, token: String) async throws -> AccountDeletionHandoffInspection

    /// `POST /transfers/:id/handoff-token` — mint a replacement link for a
    /// transfer still waiting on a successor. The raw token exists only in
    /// memory, so a relaunch has no way to re-present the old one.
    func rotateHandoffToken(id: String) async throws -> WireResponses.AccountDeletionTransferOne

    /// `DELETE /api/me`. The last irreversible step of every flow.
    /// `receiptHash` is the SHA-256 of a nonce the caller persisted first;
    /// the server writes a receipt row inside the deletion transaction.
    func deleteAccount(disposition: AccountDeletionDisposition, receiptHash: String) async throws -> Bool

    /// `POST /receipts/lookup`, unauthenticated. `nil` means no receipt —
    /// the deletion did not commit. Any other failure throws; a missing
    /// receipt and an unreachable server must never look alike.
    func deletionReceipt(token: String) async throws -> AccountDeletionReceiptDTO?
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

    func acquireSourceDeletionLease(id: String) async throws -> AccountDeletionTransferDTO {
        try await client.acquireAccountDeletionTransferSourceDeleting(id: id)
    }

    func markSourceDeleted(id: String) async throws -> AccountDeletionTransferDTO {
        try await client.markAccountDeletionTransferSourceDeleted(id: id)
    }

    func cancelTransfer(id: String) async throws -> AccountDeletionTransferDTO {
        try await client.cancelAccountDeletionTransfer(id: id)
    }

    func inspectHandoff(id: String, token: String) async throws -> AccountDeletionHandoffInspection {
        try await client.inspectAccountDeletionTransfer(id: id, token: token)
    }

    func rotateHandoffToken(id: String) async throws -> WireResponses.AccountDeletionTransferOne {
        try await client.rotateAccountDeletionHandoffToken(id: id)
    }

    func deleteAccount(disposition: AccountDeletionDisposition, receiptHash: String) async throws -> Bool {
        try await client.deleteAccount(disposition: disposition, deletionReceiptHash: receiptHash)
    }

    func deletionReceipt(token: String) async throws -> AccountDeletionReceiptDTO? {
        do {
            return try await client.lookupAccountDeletionReceipt(token: token)
        } catch let error as SeedkeepError where error.code == "receipt_not_found" {
            // A definitive "no such receipt": the deletion did not commit.
            // Only this one code may be flattened to nil — a transport
            // failure has to stay an error, or a network blip would read
            // as proof the account survived.
            return nil
        }
    }
}
