import Testing
import Foundation
import CloudKit
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

// The surface a user actually sees while their account is being deleted
// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md` § "UI"),
// and the universal link that hands a shared garden to a successor.
//
// The coordinator already refuses to do anything unsafe. What these tests
// defend is the other half — that the SCREEN never says something the
// coordinator has not earned:
//
//   1. TRUTHFUL COPY. Every durable phase a flow can be resumed at names
//      itself. A phase with no copy would resume into a blank spinner.
//   2. NO EARLY SUCCESS. "Deleted" appears only after both the CloudKit
//      work and `DELETE /api/me` have actually completed.
//   3. LEGAL AFFORDANCES ONLY. Retry is offered exactly when something
//      failed; Cancel exactly while the original garden still exists.
//   4. LOOK BEFORE SPENDING. A handoff link is inspected — never accepted
//      — until the user consents, and a link for a garden this device
//      cannot see is refused with the single-use token unspent.

// MARK: - Fixtures

private let ownerHouseholdID = "hh_owner"
private let ownerZone = CKRecordZone.ID(zoneName: "seedkeep-hh_owner",
                                        ownerName: CKCurrentUserDefaultName)
/// The same garden as a participant sees it: the owner's zone in the
/// shared database.
private let sharedSourceZone = CKRecordZone.ID(zoneName: "seedkeep-hh_owner",
                                               ownerName: "_owner_ck_user")
private let foreignSharedZone = CKRecordZone.ID(zoneName: "seedkeep-hh_someone_else",
                                                ownerName: "_stranger_ck_user")
private let destinationShareURL = URL(string: "https://www.icloud.com/share/0destination")!
private let successorRecordName = "_successor_ck_user"

private func zoneKey(_ zoneID: CKRecordZone.ID) -> String {
    "\(zoneID.zoneName)|\(zoneID.ownerName)"
}

private func gardenGraph(in zone: CKRecordZone.ID) -> [CKRecord] {
    let household = CKRecord(recordType: SeedkeepRecordType.household.recordTypeName,
                             recordID: CKRecord.ID(recordName: "household:hh_owner", zoneID: zone))
    household["name"] = "Finklea Garden" as CKRecordValue
    let seed = CKRecord(recordType: SeedkeepRecordType.seed.recordTypeName,
                        recordID: CKRecord.ID(recordName: "seed:s1", zoneID: zone))
    seed["customName"] = "Brandywine" as CKRecordValue
    return [household, seed]
}

// MARK: - Seams

@MainActor
private final class StubCloudKit: AccountDeletionCloudKitOperating {
    var role: AccountDeletionCloudKitRole = .noGarden
    private(set) var calls: [String] = []
    private var recordsByZone: [String: [CKRecord]] = [:]
    var absentZones: Set<String> = []

    func seed(zone: CKRecordZone.ID, records: [CKRecord]) {
        recordsByZone[zoneKey(zone)] = records
    }

    func currentRole() async throws -> AccountDeletionCloudKitRole {
        calls.append("currentRole")
        return role
    }

    func leaveSharedGarden(zoneID: CKRecordZone.ID) async throws {
        calls.append("leaveSharedGarden")
        absentZones.insert(zoneKey(zoneID))
    }

    func sharedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool {
        calls.append("sharedZoneIsAbsent")
        return absentZones.contains(zoneKey(zoneID))
    }

    func deleteOwnedZone(zoneID: CKRecordZone.ID) async throws {
        calls.append("deleteOwnedZone")
        absentZones.insert(zoneKey(zoneID))
        recordsByZone[zoneKey(zoneID)] = nil
    }

    func ownedZoneIsAbsent(zoneID: CKRecordZone.ID) async throws -> Bool {
        calls.append("ownedZoneIsAbsent")
        return absentZones.contains(zoneKey(zoneID))
    }

    func fetchRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        calls.append("fetchRecords")
        guard let records = recordsByZone[zoneKey(zoneID)] else {
            throw CKError(.zoneNotFound)
        }
        return records
    }

    func saveRecords(_ records: [CKRecord],
                     policy: CKModifyRecordsOperation.RecordSavePolicy,
                     in zoneID: CKRecordZone.ID) async throws {
        calls.append("saveRecords")
        var existing = recordsByZone[zoneKey(zoneID)] ?? []
        existing.append(contentsOf: records)
        recordsByZone[zoneKey(zoneID)] = existing
    }

    func acceptShare(at url: URL) async throws -> CKRecordZone.ID {
        calls.append("acceptShare")
        return CKRecordZone.ID(zoneName: ownerZone.zoneName, ownerName: successorRecordName)
    }

    func createDestination(householdID: String, title: String) async throws
        -> AccountDeletionDestination {
        calls.append("createDestination")
        let zone = CKRecordZone.ID(zoneName: "seedkeep-\(householdID)",
                                   ownerName: CKCurrentUserDefaultName)
        recordsByZone[zoneKey(zone)] = recordsByZone[zoneKey(zone)] ?? []
        return AccountDeletionDestination(
            zoneID: zone,
            ownerRecordName: successorRecordName,
            shareRecordName: CKRecordNameZoneWideShare,
            shareURL: destinationShareURL)
    }
}

@MainActor
private final class StubServer: AccountDeletionServerOperating {
    enum Call: Equatable {
        case createTransfer
        case transfer(String)
        case inspectHandoff(id: String, token: String)
        case acceptTransfer(id: String, token: String)
        case putDestination(String)
        case putOwnerVerification(String)
        case putSuccessorVerification(String)
        case acquireSourceDeletionLease(String)
        case markSourceDeleted(String)
        case cancelTransfer(String)
        case rotateHandoffToken(String)
        case deleteAccount
        case deletionReceipt
    }

    private(set) var calls: [Call] = []
    var row: AccountDeletionTransferDTO?
    var mintedToken = "handoff-token-abc"
    var rotatedToken = "handoff-token-rotated"
    var expiresAt: Int64 = 9_000_000_000_000
    var deleteAccountError: Error?
    var inspectError: Error?
    var accountDeleted = true

    func seedRow(id: String = "tr_1",
                 phase: AccountDeletionTransferPhase,
                 sourceHouseholdID: String = ownerHouseholdID,
                 destination: Bool = false) {
        row = AccountDeletionTransferDTO(
            id: id, source_household_id: sourceHouseholdID, owner_user_id: "u_owner",
            successor_user_id: phase == .pendingSuccessor ? nil : "u_succ",
            phase: phase, handoff_expires_at: expiresAt, handoff_consumed_at: nil,
            destination_zone_name: destination ? ownerZone.zoneName : nil,
            destination_zone_owner_name: destination ? successorRecordName : nil,
            destination_share_record_name: destination ? CKRecordNameZoneWideShare : nil,
            destination_share_url: destination ? destinationShareURL.absoluteString : nil,
            owner_digest: nil, successor_digest: nil,
            created_at: 1, updated_at: 1, cancelled_at: nil)
    }

    private func moved(to phase: AccountDeletionTransferPhase,
                       destination: Bool? = nil) -> AccountDeletionTransferDTO {
        let current = row!
        let hasDestination = destination ?? (current.destination_zone_name != nil)
        let next = AccountDeletionTransferDTO(
            id: current.id, source_household_id: current.source_household_id,
            owner_user_id: current.owner_user_id,
            successor_user_id: current.successor_user_id ?? "u_succ",
            phase: phase, handoff_expires_at: current.handoff_expires_at,
            handoff_consumed_at: current.handoff_consumed_at,
            destination_zone_name: hasDestination ? ownerZone.zoneName : nil,
            destination_zone_owner_name: hasDestination ? successorRecordName : nil,
            destination_share_record_name: hasDestination ? CKRecordNameZoneWideShare : nil,
            destination_share_url: hasDestination ? destinationShareURL.absoluteString : nil,
            owner_digest: current.owner_digest, successor_digest: current.successor_digest,
            created_at: current.created_at, updated_at: current.updated_at + 1,
            cancelled_at: current.cancelled_at)
        row = next
        return next
    }

    func createTransfer() async throws -> WireResponses.AccountDeletionTransferOne {
        calls.append(.createTransfer)
        if row == nil { seedRow(phase: .pendingSuccessor) }
        return .init(transfer: row!, handoff_token: mintedToken)
    }

    func transfer(id: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.transfer(id))
        return row!
    }

    func acceptTransfer(id: String, token: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.acceptTransfer(id: id, token: token))
        return moved(to: .successorBound)
    }

    func putDestination(id: String, zoneName: String, zoneOwnerName: String,
                        shareRecordName: String, shareURL: String?) async throws
        -> AccountDeletionTransferDTO {
        calls.append(.putDestination(id))
        return moved(to: .destinationReady, destination: true)
    }

    func putOwnerVerification(id: String, digest: HouseholdGraphDigest) async throws
        -> AccountDeletionTransferDTO {
        calls.append(.putOwnerVerification(id))
        return moved(to: .ownerVerified)
    }

    func putSuccessorVerification(id: String, digest: HouseholdGraphDigest,
                                  destinationZoneName: String,
                                  destinationZoneOwnerName: String) async throws
        -> AccountDeletionTransferDTO {
        calls.append(.putSuccessorVerification(id))
        return moved(to: .verified)
    }

    func acquireSourceDeletionLease(id: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.acquireSourceDeletionLease(id))
        return moved(to: .sourceDeleting)
    }

    func markSourceDeleted(id: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.markSourceDeleted(id))
        return moved(to: .sourceDeleted)
    }

    func cancelTransfer(id: String) async throws -> AccountDeletionTransferDTO {
        calls.append(.cancelTransfer(id))
        return moved(to: .cancelled)
    }

    func inspectHandoff(id: String, token: String) async throws
        -> AccountDeletionHandoffInspection {
        calls.append(.inspectHandoff(id: id, token: token))
        if let inspectError { throw inspectError }
        let current = row ?? {
            seedRow(id: id, phase: .pendingSuccessor)
            return row!
        }()
        return AccountDeletionHandoffInspection(
            transfer_id: current.id,
            source_household_id: current.source_household_id,
            phase: current.phase,
            handoff_expires_at: current.handoff_expires_at)
    }

    func rotateHandoffToken(id: String) async throws
        -> WireResponses.AccountDeletionTransferOne {
        calls.append(.rotateHandoffToken(id))
        return .init(transfer: row!, handoff_token: rotatedToken)
    }

    func deleteAccount(disposition: AccountDeletionDisposition,
                       receiptHash: String) async throws -> Bool {
        calls.append(.deleteAccount)
        if let deleteAccountError { throw deleteAccountError }
        return accountDeleted
    }

    func deletionReceipt(token: String) async throws -> AccountDeletionReceiptDTO? {
        calls.append(.deletionReceipt)
        return nil
    }

    var acceptedTransfer: Bool {
        calls.contains { if case .acceptTransfer = $0 { return true }; return false }
    }

    var inspected: Bool {
        calls.contains { if case .inspectHandoff = $0 { return true }; return false }
    }

    var deletedAccount: Bool { calls.contains(.deleteAccount) }
}

@MainActor
private final class SignOutRecorder { var count = 0 }

@MainActor
private final class Harness {
    let store: AccountDeletionCheckpointStore
    let cloudKit = StubCloudKit()
    let server = StubServer()
    let signOut = SignOutRecorder()
    let coordinator: AccountDeletionCoordinator
    let model: AccountDeletionFlowModel
    let userID: String
    private var signedIn: Bool

    init(userID: String = "u_owner", signedIn: Bool = true) {
        self.userID = userID
        self.signedIn = signedIn
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountDeletionFlowViewState-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AccountDeletionCheckpointStore(directory: directory)
        let recorder = signOut
        let isSignedIn = { signedIn }
        coordinator = AccountDeletionCoordinator(
            store: store,
            cloudKit: cloudKit,
            server: server,
            session: AccountDeletionSession(
                identity: {
                    isSignedIn()
                        ? AccountDeletionSession.Identity(userID: userID,
                                                          householdID: ownerHouseholdID)
                        : nil
                },
                localStoreOwnerID: { userID },
                signOut: { recorder.count += 1 }
            ),
            now: { 1_700_000_000_000 },
            newReceipt: { "receipt-nonce-fixed" })
        model = AccountDeletionFlowModel(coordinator: coordinator)
    }

    var stored: AccountDeletionCheckpoint? { try? store.load(userID: userID)?.checkpoint }

    func seedCheckpoint(role: AccountDeletionCheckpoint.Role,
                        phase: AccountDeletionCheckpoint.Phase,
                        transferID: String? = "tr_1",
                        sourceZone: CKRecordZone.ID? = ownerZone,
                        destinationZone: CKRecordZone.ID? = nil,
                        receipt: String? = nil) throws {
        try store.save(AccountDeletionCheckpoint(
            userID: userID, role: role, phase: phase, transferID: transferID,
            sourceZoneName: sourceZone?.zoneName,
            sourceZoneOwnerName: sourceZone?.ownerName,
            destinationZoneName: destinationZone?.zoneName,
            destinationZoneOwnerName: destinationZone?.ownerName,
            deletionReceipt: receipt,
            updatedAt: 1))
    }
}

/// Every (role, phase) pair the coordinator's state machine can actually
/// be resumed at. Anything outside this table is unreachable, and copy for
/// it would be copy nobody can ever see.
private let reachablePhases: [AccountDeletionCheckpoint.Role: Set<AccountDeletionCheckpoint.Phase>] = [
    .noCloudKitGarden: [.deletingAccount],
    .participant: [.participantLeaving, .deletingAccount],
    .soloOwner: [.ownerDeletingZone, .deletingAccount],
    .sharedOwner: [.transferPending, .successorBound, .destinationReady,
                   .destinationShareAccepted, .copyComplete, .ownerVerified, .verified,
                   .sourceZoneDeleting, .sourceZoneDeleted, .sourceDeleted, .deletingAccount],
    .successor: [.successorBound, .destinationZoneCreated, .destinationReady,
                 .ownerVerified, .verified, .sourceDeleted],
]

// MARK: - Copy

@MainActor
@Suite("Account-deletion flow copy")
struct AccountDeletionFlowCopyTests {

    @Test("every phase a flow can resume at names itself, and nothing else does")
    func everyReachablePhaseHasCopy() {
        for role in AccountDeletionCheckpoint.Role.allCases {
            let reachable = reachablePhases[role] ?? []
            for phase in AccountDeletionCheckpoint.Phase.allCases {
                let steps = AccountDeletionFlowCopy.steps(role: role, phase: phase, waiting: false)
                guard reachable.contains(phase) else {
                    #expect(steps == nil,
                            "\(role.rawValue)/\(phase.rawValue) is unreachable but has copy")
                    continue
                }
                let rows = try? #require(steps)
                guard let rows else { continue }
                #expect(!rows.isEmpty)
                let active = rows.filter { $0.state == .active }
                #expect(active.count == 1,
                        "\(role.rawValue)/\(phase.rawValue) must mark exactly one active step, got \(active.count)")
                #expect(active.first?.title.isEmpty == false)
                #expect(Set(rows.map(\.id)).count == rows.count, "step ids must be unique")
            }
        }
    }

    @Test("the shared owner sees the seven steps the spec names, in order")
    func sharedOwnerStepTitles() throws {
        let rows = try #require(AccountDeletionFlowCopy.steps(
            role: .sharedOwner, phase: .transferPending, waiting: false))
        #expect(rows.map(\.title) == [
            "Invite a successor",
            "Waiting for acceptance",
            "Preparing successor garden",
            "Copying garden",
            "Verifying both copies",
            "Deleting original garden",
            "Deleting account",
        ])
    }

    @Test("participant and solo owner each see their two steps")
    func shortFlowTitles() throws {
        let participant = try #require(AccountDeletionFlowCopy.steps(
            role: .participant, phase: .participantLeaving, waiting: false))
        #expect(participant.map(\.title) == ["Leaving shared garden", "Deleting account"])

        let solo = try #require(AccountDeletionFlowCopy.steps(
            role: .soloOwner, phase: .ownerDeletingZone, waiting: false))
        #expect(solo.map(\.title) == ["Deleting iCloud garden", "Deleting account"])
    }

    @Test("a link that is out but unopened reads as waiting, not as inviting")
    func waitingSplitsTheFirstOwnerStep() throws {
        let inviting = try #require(AccountDeletionFlowCopy.steps(
            role: .sharedOwner, phase: .transferPending, waiting: false))
        #expect(inviting.first(where: { $0.state == .active })?.title == "Invite a successor")

        let waiting = try #require(AccountDeletionFlowCopy.steps(
            role: .sharedOwner, phase: .transferPending, waiting: true))
        #expect(waiting.first(where: { $0.state == .active })?.title == "Waiting for acceptance")
        // The step that is already behind us stays behind us.
        #expect(waiting.first?.state == .done)
    }

    @Test("steps behind the active one are done and steps ahead are upcoming")
    func stepStatesAdvanceMonotonically() throws {
        let rows = try #require(AccountDeletionFlowCopy.steps(
            role: .sharedOwner, phase: .copyComplete, waiting: false))
        let activeIndex = try #require(rows.firstIndex { $0.state == .active })
        #expect(rows.prefix(activeIndex).allSatisfy { $0.state == .done })
        #expect(rows.dropFirst(activeIndex + 1).allSatisfy { $0.state == .upcoming })
        #expect(rows[activeIndex].title == "Verifying both copies")
    }

    @Test("the last owner step is only active once the account itself is going")
    func deletingAccountIsTheFinalStep() throws {
        let rows = try #require(AccountDeletionFlowCopy.steps(
            role: .sharedOwner, phase: .deletingAccount, waiting: false))
        #expect(rows.last?.state == .active)
        #expect(rows.last?.title == "Deleting account")
        #expect(rows.dropLast().allSatisfy { $0.state == .done })
    }
}

// MARK: - Flow model

@MainActor
@Suite("Account-deletion flow model", .serialized)
struct AccountDeletionFlowModelTests {

    // MARK: Presenting is not deleting

    @Test("opening the flow asks the user first and touches neither CloudKit nor the server")
    func presentingDoesNoWork() async {
        let harness = Harness()
        harness.cloudKit.role = .noGarden

        await harness.model.prepare()

        #expect(harness.model.stage == .confirming)
        #expect(harness.server.calls.isEmpty, "presenting must not reach the server")
        #expect(harness.cloudKit.calls.isEmpty, "presenting must not reach CloudKit")
        #expect(harness.stored == nil, "presenting must not start a deletion")
    }

    @Test("confirming an account with no iCloud garden deletes it and signs out")
    func confirmDeletesSimpleAccount() async {
        let harness = Harness()
        harness.cloudKit.role = .noGarden

        await harness.model.prepare()
        await harness.model.confirm()

        #expect(harness.model.stage == .deleted)
        #expect(harness.model.isComplete)
        #expect(harness.signOut.count == 1)
        #expect(harness.server.deletedAccount)
    }

    @Test("a participant's flow reads as leaving the share before deleting the account")
    func participantCopyFollowsTheFlow() async throws {
        let harness = Harness()
        harness.cloudKit.role = .participant(sharedZoneID: sharedSourceZone)
        harness.server.deleteAccountError = SeedkeepError(code: "server_error", message: "boom")

        await harness.model.prepare()
        await harness.model.confirm()

        // The share was left; only the account call failed, so the flow
        // stops on the last step and says so.
        #expect(harness.cloudKit.calls.contains("leaveSharedGarden"))
        let rows = try #require(harness.model.steps)
        #expect(rows.map(\.title) == ["Leaving shared garden", "Deleting account"])
        #expect(rows.last?.state == .active)
        #expect(!harness.model.isComplete)
    }

    @Test("a solo owner's flow reads as deleting the iCloud garden first")
    func soloOwnerCopyFollowsTheFlow() async throws {
        let harness = Harness()
        harness.cloudKit.role = .soloOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph(in: ownerZone))

        await harness.model.prepare()
        await harness.model.confirm()

        #expect(harness.cloudKit.calls.contains("deleteOwnedZone"))
        #expect(harness.model.stage == .deleted)
    }

    // MARK: No early success

    @Test("a shared owner waiting for a successor is never shown as deleted")
    func sharedOwnerNeverClaimsSuccessEarly() async throws {
        let harness = Harness()
        harness.cloudKit.role = .sharedOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph(in: ownerZone))

        await harness.model.prepare()
        await harness.model.confirm()

        #expect(harness.model.stage == .waiting(.transferPending))
        #expect(!harness.model.isComplete)
        #expect(!harness.server.deletedAccount, "nothing may ask the server to delete the account yet")
        #expect(harness.signOut.count == 0)
        let rows = try #require(harness.model.steps)
        #expect(rows.first(where: { $0.state == .active })?.title == "Waiting for acceptance")
        #expect(rows.last?.state == .upcoming)
    }

    @Test("a failed account deletion is a failure, not a completion")
    func failedDeletionIsNotCompletion() async {
        let harness = Harness()
        harness.cloudKit.role = .noGarden
        harness.server.deleteAccountError = SeedkeepError(code: "server_error", message: "boom")

        await harness.model.prepare()
        await harness.model.confirm()

        guard case .failed(let phase, let message) = harness.model.stage else {
            Issue.record("expected a failure, got \(harness.model.stage)")
            return
        }
        #expect(phase == .deletingAccount)
        #expect(!message.isEmpty)
        #expect(!harness.model.isComplete)
        #expect(harness.signOut.count == 0)
    }

    // MARK: Retry

    @Test("retry is offered only after a failure, and it finishes the job")
    func retryOnlyAfterFailure() async {
        let harness = Harness()
        harness.cloudKit.role = .noGarden
        harness.server.deleteAccountError = SeedkeepError(code: "server_error", message: "boom")

        await harness.model.prepare()
        #expect(!harness.model.canRetry, "nothing has failed yet")

        await harness.model.confirm()
        #expect(harness.model.canRetry)

        harness.server.deleteAccountError = nil
        await harness.model.retry()

        #expect(harness.model.stage == .deleted)
        #expect(!harness.model.canRetry)
    }

    @Test("a waiting flow offers no retry — nothing failed")
    func waitingOffersNoRetry() async {
        let harness = Harness()
        harness.cloudKit.role = .sharedOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph(in: ownerZone))

        await harness.model.prepare()
        await harness.model.confirm()

        #expect(!harness.model.canRetry)
    }

    // MARK: Cancel

    @Test("cancel is offered while the original garden is intact and withdrawn once it is not")
    func cancelOfferedOnlyWhileTheGardenSurvives() async throws {
        for phase in [AccountDeletionCheckpoint.Phase.transferPending, .successorBound,
                      .destinationReady, .destinationShareAccepted, .copyComplete,
                      .ownerVerified, .verified] {
            let harness = Harness()
            try harness.seedCheckpoint(role: .sharedOwner, phase: phase)
            harness.model.reload()
            #expect(harness.model.canCancel, "\(phase.rawValue) must still be cancellable")
        }

        for phase in [AccountDeletionCheckpoint.Phase.sourceZoneDeleting, .sourceZoneDeleted,
                      .sourceDeleted, .deletingAccount] {
            let harness = Harness()
            try harness.seedCheckpoint(role: .sharedOwner, phase: phase)
            harness.model.reload()
            #expect(!harness.model.canCancel, "\(phase.rawValue) must not offer cancel")
        }
    }

    @Test("a successor is never offered a cancel — it is not their account")
    func successorHasNoCancel() throws {
        let harness = Harness()
        try harness.seedCheckpoint(role: .successor, phase: .destinationReady)
        harness.model.reload()
        #expect(!harness.model.canCancel)
    }

    @Test("cancelling before the source is gone withdraws the transfer and forgets the deletion")
    func cancelBeforeSourceDeletion() async throws {
        let harness = Harness()
        harness.server.seedRow(phase: .pendingSuccessor)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .transferPending)
        harness.model.reload()

        await harness.model.cancel()

        #expect(harness.model.stage == .cancelled)
        #expect(harness.server.calls.contains(.cancelTransfer("tr_1")))
        #expect(harness.stored == nil)
        #expect(harness.signOut.count == 0, "cancelling a deletion must not sign anybody out")
    }

    @Test("cancelling after the source is gone is refused and the deletion stays resumable")
    func cancelAfterSourceDeletionIsRefused() async throws {
        let harness = Harness()
        harness.server.seedRow(phase: .sourceDeleted, destination: true)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .sourceZoneDeleted)
        harness.model.reload()

        await harness.model.cancel()

        guard case .failed = harness.model.stage else {
            Issue.record("expected the refusal to surface, got \(harness.model.stage)")
            return
        }
        #expect(!harness.server.calls.contains(.cancelTransfer("tr_1")))
        #expect(harness.stored?.phase == .sourceZoneDeleted, "the deletion must stay resumable")
    }

    // MARK: Owner handoff link

    @Test("the departing owner is given a shareable handoff link that parses back")
    func ownerSeesAShareableLink() async throws {
        let harness = Harness()
        harness.cloudKit.role = .sharedOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph(in: ownerZone))

        await harness.model.prepare()
        await harness.model.confirm()

        let url = try #require(harness.model.handoffLink)
        let parsed = try #require(AccountDeletionHandoffLink(url: url))
        #expect(parsed.transferID == "tr_1")
        #expect(parsed.token == harness.server.mintedToken)
    }

    @Test("only the departing owner is shown a raw handoff link")
    func handoffLinkIsOwnerOnly() async throws {
        let harness = Harness()
        harness.server.seedRow(phase: .destinationReady, destination: true)
        try harness.seedCheckpoint(role: .successor, phase: .destinationReady,
                                   sourceZone: sharedSourceZone)
        harness.model.reload()

        #expect(harness.model.handoffLink == nil)
    }

    @Test("a relaunch with no link in memory rotates the token and shows the new link")
    func coldResumeRotatesTheLink() async throws {
        let harness = Harness()
        harness.cloudKit.role = .sharedOwner(zoneID: ownerZone)
        harness.cloudKit.seed(zone: ownerZone, records: gardenGraph(in: ownerZone))
        harness.server.seedRow(phase: .pendingSuccessor)
        try harness.seedCheckpoint(role: .sharedOwner, phase: .transferPending)

        await harness.model.prepare()

        #expect(harness.server.calls.contains(.rotateHandoffToken("tr_1")))
        let url = try #require(harness.model.handoffLink)
        let parsed = try #require(AccountDeletionHandoffLink(url: url))
        #expect(parsed.token == harness.server.rotatedToken)
        #expect(harness.model.stage == .waiting(.transferPending))
    }

    // MARK: Relaunch

    @Test("a relaunch picks a half-finished deletion back up without asking again")
    func relaunchResumesInsteadOfConfirming() async throws {
        let harness = Harness()
        harness.cloudKit.role = .noGarden
        try harness.seedCheckpoint(role: .noCloudKitGarden, phase: .deletingAccount,
                                   transferID: nil, sourceZone: nil)

        await harness.model.prepare()

        #expect(harness.model.stage == .deleted)
        #expect(harness.model.stage != .confirming, "a deletion in flight must not re-ask")
        #expect(harness.server.deletedAccount)
        #expect(harness.cloudKit.calls.isEmpty, "the CloudKit work was already done")
    }

    // MARK: Successor acceptance

    @Test("a handoff link opened while signed out waits for sign-in and spends nothing")
    func signedOutHandoffDefers() async {
        let harness = Harness(userID: "u_succ", signedIn: false)
        let link = AccountDeletionHandoffLink(transferID: "tr_1", token: "handoff-token-abc")

        await harness.model.open(link)

        #expect(harness.model.stage == .signInRequired)
        #expect(harness.server.calls.isEmpty, "a signed-out device must not reach the server")
        #expect(harness.cloudKit.calls.isEmpty)
    }

    @Test("a handoff is inspected and shown before the token is ever spent")
    func handoffIsInspectedBeforeAccepting() async throws {
        let harness = Harness(userID: "u_succ")
        harness.cloudKit.role = .participant(sharedZoneID: sharedSourceZone)
        harness.server.seedRow(phase: .pendingSuccessor)
        let link = AccountDeletionHandoffLink(transferID: "tr_1", token: "handoff-token-abc")

        await harness.model.open(link)

        guard case .handoffOffered(let preview) = harness.model.stage else {
            Issue.record("expected an offer, got \(harness.model.stage)")
            return
        }
        #expect(preview.transferID == "tr_1")
        #expect(preview.sourceHouseholdID == ownerHouseholdID)
        #expect(harness.server.inspected)
        #expect(!harness.server.acceptedTransfer, "the token must survive being looked at")
        #expect(harness.stored == nil, "nothing durable until the user consents")
    }

    @Test("accepting the offer binds the successor and starts building the destination")
    func acceptingBindsTheSuccessor() async throws {
        let harness = Harness(userID: "u_succ")
        harness.cloudKit.role = .participant(sharedZoneID: sharedSourceZone)
        harness.server.seedRow(phase: .pendingSuccessor)
        let link = AccountDeletionHandoffLink(transferID: "tr_1", token: "handoff-token-abc")

        await harness.model.open(link)
        await harness.model.acceptOffer()

        #expect(harness.server.acceptedTransfer)
        #expect(harness.cloudKit.calls.contains("createDestination"))
        #expect(harness.server.calls.contains(.putDestination("tr_1")))
        #expect(harness.model.stage == .waiting(.destinationReady))
        #expect(harness.stored?.role == .successor)
    }

    @Test("a handoff for a garden this device cannot see is refused with the token unspent")
    func wrongGardenDoesNotSpendTheToken() async throws {
        let harness = Harness(userID: "u_succ")
        // Signed in and a participant — but of somebody else's garden.
        harness.cloudKit.role = .participant(sharedZoneID: foreignSharedZone)
        harness.server.seedRow(phase: .pendingSuccessor)
        let link = AccountDeletionHandoffLink(transferID: "tr_1", token: "handoff-token-abc")

        await harness.model.open(link)

        guard case .handoffRefused(let message) = harness.model.stage else {
            Issue.record("expected a refusal, got \(harness.model.stage)")
            return
        }
        #expect(!message.isEmpty)
        #expect(!message.contains("handoff-token-abc"), "never echo the token")
        #expect(harness.server.inspected, "the refusal must come from a non-consuming read")
        #expect(!harness.server.acceptedTransfer, "the token must still be worth something")
        #expect(harness.stored == nil)
    }

    @Test("a device in no shared garden at all cannot accept a handoff")
    func nonParticipantCannotAccept() async {
        let harness = Harness(userID: "u_succ")
        harness.cloudKit.role = .noGarden
        harness.server.seedRow(phase: .pendingSuccessor)
        let link = AccountDeletionHandoffLink(transferID: "tr_1", token: "handoff-token-abc")

        await harness.model.open(link)

        guard case .handoffRefused = harness.model.stage else {
            Issue.record("expected a refusal, got \(harness.model.stage)")
            return
        }
        #expect(!harness.server.acceptedTransfer)
    }

    @Test("re-opening the link of a handoff already under way resumes it rather than re-spending")
    func reopeningAnAcceptedHandoffResumes() async throws {
        let harness = Harness(userID: "u_succ")
        harness.cloudKit.role = .participant(sharedZoneID: sharedSourceZone)
        harness.server.seedRow(phase: .destinationReady, destination: true)
        try harness.seedCheckpoint(role: .successor, phase: .destinationReady,
                                   sourceZone: sharedSourceZone)
        let link = AccountDeletionHandoffLink(transferID: "tr_1", token: "handoff-token-abc")

        await harness.model.open(link)

        #expect(!harness.server.acceptedTransfer)
        #expect(!harness.server.inspected, "a bound successor has nothing left to inspect")
        #expect(harness.model.stage == .waiting(.destinationReady))
    }
}

// MARK: - Universal-link routing

@Suite("Deletion handoff link routing")
struct AccountDeletionHandoffLinkTests {

    @Test("https://seedkeep.app/garden-handoff/<id>?token=<token> parses")
    func universalLinkParses() throws {
        let url = URL(string: "https://seedkeep.app/garden-handoff/tr_42?token=abc-123_XY")!
        let link = try #require(AccountDeletionHandoffLink(url: url))
        #expect(link.transferID == "tr_42")
        #expect(link.token == "abc-123_XY")
    }

    @Test("the custom development scheme parses the same way")
    func customSchemeParses() throws {
        let url = URL(string: "seedkeep://garden-handoff/tr_42?token=abc-123_XY")!
        let link = try #require(AccountDeletionHandoffLink(url: url))
        #expect(link.transferID == "tr_42")
        #expect(link.token == "abc-123_XY")
    }

    @Test("a link with no token is not a handoff")
    func missingTokenIsNotALink() {
        #expect(AccountDeletionHandoffLink(
            url: URL(string: "https://seedkeep.app/garden-handoff/tr_42")!) == nil)
        #expect(AccountDeletionHandoffLink(
            url: URL(string: "https://seedkeep.app/garden-handoff/tr_42?token=")!) == nil)
    }

    @Test("a link with no transfer id is not a handoff")
    func missingTransferIsNotALink() {
        #expect(AccountDeletionHandoffLink(
            url: URL(string: "https://seedkeep.app/garden-handoff?token=abc")!) == nil)
    }

    @Test("another host's look-alike link is refused")
    func foreignHostIsRefused() {
        #expect(AccountDeletionHandoffLink(
            url: URL(string: "https://evil.example/garden-handoff/tr_42?token=abc")!) == nil)
    }

    @Test("a base64url token survives the round trip through the shareable link")
    func tokenRoundTrips() throws {
        let original = AccountDeletionHandoffLink(transferID: "tr_42",
                                                  token: "aZ0-_9abcDEF")
        let parsed = try #require(AccountDeletionHandoffLink(url: original.universalLink))
        #expect(parsed == original)
        #expect(original.universalLink.host == "seedkeep.app")
        #expect(original.universalLink.scheme == "https")
    }

    @Test("an invite link is not a handoff and a handoff is not an invite")
    func theTwoDeepLinksDoNotShadowEachOther() {
        let invite = URL(string: "https://seedkeep.app/invite/code99")!
        let handoff = URL(string: "https://seedkeep.app/garden-handoff/tr_42?token=abc")!
        #expect(AccountDeletionHandoffLink(url: invite) == nil)
        #expect(InviteURLRouter.invitationCode(from: handoff) == nil)
    }

    @Test("the incoming-link router tells the two apart and ignores everything else")
    func incomingLinkRouting() throws {
        let handoff = IncomingLink(url: URL(string:
            "https://seedkeep.app/garden-handoff/tr_42?token=abc")!)
        #expect(handoff == .gardenHandoff(
            AccountDeletionHandoffLink(transferID: "tr_42", token: "abc")))

        #expect(IncomingLink(url: URL(string: "https://seedkeep.app/invite/code99")!)
            == .invite(code: "code99"))
        #expect(IncomingLink(url: URL(string: "https://seedkeep.app/")!) == nil)
        #expect(IncomingLink(url: URL(string: "https://www.icloud.com/share/0abc")!) == nil)
    }
}
