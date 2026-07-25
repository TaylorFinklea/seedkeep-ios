import CloudKit
import CryptoKit
import Foundation
import Observation
import SeedkeepCloudKit
import SeedkeepKit

/// Runs account deletion: the role-specific CloudKit work first, then
/// `DELETE /api/me`, then sign-out — resumably, one checkpointed step at a
/// time.
///
/// The problem this type exists to solve is that deleting a Seedkeep
/// account is not one operation and the pieces are not equally reversible.
/// A CloudKit zone, once deleted, is gone. A server account, once deleted,
/// takes the credentials needed to finish anything else with it. Between
/// those two there is a window in which a crash leaves a user signed in to
/// an account whose garden no longer exists — or, worse, signed out of an
/// account that still does. So the flow is written as a state machine over
/// a durable checkpoint
/// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md`
/// § "Role flows"), with four rules it never breaks:
///
///   1. **`DELETE /api/me` is last.** Nothing clears a token, erases local
///      data, or signs out until the server has confirmed the account is
///      gone. Every failure anywhere earlier leaves a fully working,
///      signed-in app pointed at an intact garden.
///   2. **A checkpoint is written after its step lands, never before.** The
///      phase on disk names the step to run NEXT, and it only moves once
///      the previous step's external effect has actually happened. Resuming
///      therefore re-attempts exactly the operation that did not finish.
///      Every such operation is idempotent, which is what makes re-running
///      it safe. (The single exception is the first checkpoint of a flow:
///      it precedes all external work precisely so a crash during the first
///      irreversible step is still recoverable.)
///   3. **The source garden outlives every doubt.** The owner's zone is
///      deleted only when the server holds two independently computed
///      digests — the owner's and the successor's — that agree on both the
///      hash and the per-type census, over a destination zone the owner has
///      separately confirmed the successor owns.
///   4. **Ambiguity stops the flow.** A zone that is still readable after
///      being deleted, a verified transfer with a digest missing, a server
///      phase behind the local one: none of these are guessed at. The
///      coordinator reloads durable state or fails, and the account and the
///      garden both survive.
///
/// The flow is driven, not scheduled: `start`, `resume` and `acceptHandoff`
/// each advance as far as they can and then return — either `deleted`,
/// `handoffComplete`, or `waiting(phase)` when the next move belongs to the
/// other device. Nothing here polls; the surface that owns the UI decides
/// when to call again.
@MainActor
@Observable
final class AccountDeletionCoordinator {

    /// Where a drive stopped.
    enum Outcome: Equatable, Sendable {
        /// No deletion is in progress. Also the answer when a transfer was
        /// cancelled out from under this device before anything
        /// irreversible happened.
        case idle
        /// Everything this device can do is done; `phase` names what the
        /// other device (or the person opening the handoff link) owes.
        case waiting(AccountDeletionCheckpoint.Phase)
        /// A successor finished building and verifying the destination
        /// garden. Their own account is untouched.
        case handoffComplete
        /// The account is gone and the session has been signed out.
        case deleted
    }

    /// The single-use handoff credential for a shared-owner transfer, held
    /// in memory only.
    ///
    /// It is deliberately absent from `AccountDeletionCheckpoint`: writing a
    /// live capability into an unencrypted JSON file in Application Support
    /// for the days-long lifetime of a transfer is a worse failure mode than
    /// having to re-issue a link. The server re-issues on demand for a
    /// transfer still waiting for a successor, which is the documented
    /// recovery path.
    struct Handoff: Equatable, Sendable {
        let transferID: String
        let token: String
        /// Epoch milliseconds.
        let expiresAt: Int64
    }

    private let store: AccountDeletionCheckpointStore
    private let cloudKit: any AccountDeletionCloudKitOperating
    private let server: any AccountDeletionServerOperating
    private let session: AccountDeletionSession
    private let now: @MainActor () -> Int64
    private let newReceipt: @MainActor () -> String

    /// The durable state as this coordinator last saw it. Observable so a
    /// progress surface can render the current phase and last failure.
    private(set) var checkpoint: AccountDeletionCheckpoint?
    /// Non-nil only between minting a handoff and the successor accepting.
    private(set) var handoff: Handoff?

    /// The handoff only while it is still worth sending.
    ///
    /// A token lives 72 hours. Nothing in a long-running app forces that
    /// deadline into view, so without this an owner who left the sheet
    /// open over a weekend would keep sharing a link the server will
    /// reject — and `openOrResumeTransfer` would never rotate it, because
    /// it only rotates when it holds NO link for the transfer. Expiry is
    /// therefore treated as absence: the stale token is not shareable, and
    /// the next resume mints a fresh one.
    var liveHandoff: Handoff? {
        guard let handoff, handoff.expiresAt > now() else { return nil }
        return handoff
    }

    /// The right to replace the checkpoint file exactly once. Dropped on any
    /// rejected write so the next attempt has to reload rather than fight
    /// another writer for the file.
    @ObservationIgnored private var lease: AccountDeletionCheckpointStore.Lease?
    /// The destination this process created, kept so the happy path does not
    /// ask CloudKit for it twice. A cold resume re-derives it instead.
    @ObservationIgnored private var pendingDestination: AccountDeletionDestination?

    init(
        store: AccountDeletionCheckpointStore,
        cloudKit: any AccountDeletionCloudKitOperating,
        server: any AccountDeletionServerOperating,
        session: AccountDeletionSession,
        now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        newReceipt: @escaping @MainActor () -> String = AccountDeletionCoordinator.randomReceiptNonce
    ) {
        self.store = store
        self.cloudKit = cloudKit
        self.server = server
        self.session = session
        self.now = now
        self.newReceipt = newReceipt
    }

    /// 256 bits from the system CSPRNG. Only ever presented to the server
    /// as a SHA-256, so its only job is to be unguessable.
    static func randomReceiptNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // The system RNG does not fail in practice, and a predictable
            // nonce here would only weaken a lookup that reveals nothing
            // but "was this deletion committed" — still, prefer entropy we
            // can account for over a fixed value.
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
    }

    static func receiptHash(of nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Entry points

    /// Begin deleting this account, or pick up a deletion already under way.
    ///
    /// The role is decided once, here, and only when there is no checkpoint:
    /// a flow that has already deleted a zone must not re-inspect CloudKit
    /// and conclude it is a different kind of user now.
    @discardableResult
    func start() async throws -> Outcome {
        try Task.checkCancellation()
        let identity = try requireIdentity()
        if try reload(userID: identity.userID) != nil { return try await drive() }

        let initial: AccountDeletionCheckpoint
        switch try await cloudKit.currentRole() {
        case .noGarden:
            initial = makeCheckpoint(identity, role: .noCloudKitGarden, phase: .deletingAccount, source: nil)
        case .participant(let zoneID):
            initial = makeCheckpoint(identity, role: .participant, phase: .participantLeaving, source: zoneID)
        case .soloOwner(let zoneID):
            initial = makeCheckpoint(identity, role: .soloOwner, phase: .ownerDeletingZone, source: zoneID)
        case .sharedOwner(let zoneID):
            initial = makeCheckpoint(identity, role: .sharedOwner, phase: .transferPending, source: zoneID)
        }
        // The one write that precedes its external step. Without it a crash
        // during the first CloudKit operation would leave no evidence that a
        // deletion was ever started.
        try persist(initial)
        return try await drive()
    }

    /// Continue whatever this user's checkpoint says is unfinished. Safe to
    /// call at launch, on foreground, and after a failure.
    @discardableResult
    func resume() async throws -> Outcome {
        try Task.checkCancellation()
        let identity = try requireIdentity()
        guard try reload(userID: identity.userID) != nil else { return .idle }
        return try await drive()
    }

    /// What a handoff link is offering, without spending it.
    ///
    /// Everything here is safe to render: the token is deliberately absent
    /// so a preview cannot be logged, screenshotted, or forwarded into a
    /// capability.
    struct HandoffPreview: Equatable, Sendable {
        let transferID: String
        let sourceHouseholdID: String
        /// The durable server phase, so the surface can tell a live offer
        /// from one that was already taken or withdrawn.
        let phase: AccountDeletionTransferPhase
        /// Epoch milliseconds.
        let expiresAt: Int64
    }

    /// Look at a handoff link without consuming it, and prove this device
    /// can actually receive the garden it names.
    ///
    /// The token is single-use and binding is irreversible, so a user who
    /// happens to participate in a DIFFERENT garden must not be able to
    /// burn the one chance the rightful successor has just by opening the
    /// link. Inspection is the non-consuming read that makes the check
    /// possible before the fact rather than after it — which is also what
    /// lets the UI show somebody what they are about to take on and wait
    /// for them to say yes.
    ///
    /// The offer must also still BE an offer. The inspection route is
    /// deliberately non-consuming and keeps answering for a transfer that
    /// has moved on, so a second participant opening a link somebody else
    /// already accepted would otherwise be shown a live invitation and an
    /// enabled Accept button, and learn the truth only from the failure.
    /// The durable phase is the only thing that can say so up front.
    ///
    /// Acceptance does NOT apply this guard: a successor whose accept
    /// response was lost is legitimately looking at a `successor_bound`
    /// row and must still be able to replay their own idempotent accept.
    func previewHandoff(transferID: String, token: String) async throws -> HandoffPreview {
        do {
            let preview = try await inspectHandoff(transferID: transferID, token: token).preview
            guard preview.expiresAt > now() else {
                throw AccountDeletionCoordinatorError.handoffExpired
            }
            switch preview.phase {
            case .pendingSuccessor: return preview
            case .cancelled: throw AccountDeletionCoordinatorError.handoffWithdrawn
            default: throw AccountDeletionCoordinatorError.handoffAlreadyUsed
            }
        } catch let error as SeedkeepError where error.code == "handoff_expired" {
            // The server's own answer, not this build's expiry read —
            // still means the same thing. Canonicalized here so every
            // caller of `previewHandoff` has exactly one expiry shape to
            // recognise, whether this device's clock or the server's
            // caught it first.
            throw AccountDeletionCoordinatorError.handoffExpired
        }
    }

    /// `previewHandoff` plus the zone the proof was made against, which
    /// only `acceptHandoff` needs. One CloudKit role read and one
    /// non-consuming server read serve both callers.
    private func inspectHandoff(
        transferID: String, token: String
    ) async throws -> (preview: HandoffPreview, sourceZoneID: CKRecordZone.ID) {
        let proof = try await proveParticipation()
        let inspection = try await server.inspectHandoff(id: transferID, token: token)
        guard inspection.source_household_id == proof.householdID else {
            throw AccountDeletionCoordinatorError.sourceHouseholdMismatch(
                expected: inspection.source_household_id, found: proof.householdID)
        }
        return (HandoffPreview(transferID: inspection.transfer_id,
                               sourceHouseholdID: inspection.source_household_id,
                               phase: inspection.phase,
                               expiresAt: inspection.handoff_expires_at),
                proof.zoneID)
    }

    /// The one local fact that stands in for participant identity: this
    /// device can currently read the share it claims to. Split out so
    /// `acceptHandoff` can still make it BEFORE spending a token whose
    /// inspection has expired — inspection and acceptance ask the server
    /// two different questions, and only inspection's answer goes stale.
    private func proveParticipation() async throws
        -> (zoneID: CKRecordZone.ID, householdID: String) {
        try Task.checkCancellation()
        _ = try requireIdentity()
        guard case .participant(let sharedZoneID) = try await cloudKit.currentRole() else {
            throw AccountDeletionCoordinatorError.notASourceParticipant
        }
        return (sharedZoneID, SeedkeepRecordNames.householdID(fromZoneName: sharedZoneID.zoneName))
    }

    /// Take over a departing owner's garden. Called with the id and token
    /// carried by a handoff link.
    ///
    /// The participant proof happens BEFORE the token is spent — see
    /// `inspectHandoff`, which this runs first for exactly that reason.
    ///
    /// One deliberate exception. Inspection's `handoff_expired` answer
    /// covers "nobody has used this yet" and "somebody used it days ago
    /// and the reply never arrived" identically, because inspection and
    /// acceptance ask the server two different questions with two
    /// different clocks — `/accept` gates expiry only on the un-accepted
    /// phase and keeps honouring a BOUND successor's replay past it
    /// (`account-deletion-transfers.ts`, "single use" note). Refusing the
    /// replay here on inspection's answer would strand exactly the person
    /// this recovery path exists for: someone whose accept landed on the
    /// server, whose reply was lost, and who came back after 72 hours to
    /// find their own progress unreachable. So an EXPIRED inspection does
    /// not end the flow — it skips straight to presenting the same local
    /// participation proof to `/accept`, which is the only party that can
    /// still tell "nobody" from "already me" apart.
    @discardableResult
    func acceptHandoff(transferID: String, token: String) async throws -> Outcome {
        try Task.checkCancellation()
        let identity = try requireIdentity()

        if let existing = try reload(userID: identity.userID) {
            // Never spend a second token on top of work already in flight —
            // and never let a handoff link hijack an account deletion.
            guard existing.role == .successor, existing.transferID == transferID else {
                throw AccountDeletionCoordinatorError.deletionAlreadyInProgress(phase: existing.phase)
            }
            return try await drive()
        }

        let sharedZoneID: CKRecordZone.ID
        let expectedHouseholdID: String
        do {
            let (preview, zoneID) = try await inspectHandoff(transferID: transferID, token: token)
            sharedZoneID = zoneID
            expectedHouseholdID = preview.sourceHouseholdID
        } catch let error as SeedkeepError where error.code == "handoff_expired" {
            let proof = try await proveParticipation()
            sharedZoneID = proof.zoneID
            expectedHouseholdID = proof.householdID
        }

        let transfer = try await server.acceptTransfer(id: transferID, token: token)
        // The row could in principle have moved between the two calls.
        guard transfer.source_household_id == expectedHouseholdID else {
            throw AccountDeletionCoordinatorError.sourceHouseholdMismatch(
                expected: transfer.source_household_id, found: expectedHouseholdID)
        }

        try persist(AccountDeletionCheckpoint(
            userID: identity.userID,
            role: .successor,
            phase: AccountDeletionCheckpoint.Phase(transferPhase: transfer.phase) ?? .successorBound,
            transferID: transfer.id,
            sourceZoneName: sharedZoneID.zoneName,
            sourceZoneOwnerName: sharedZoneID.ownerName,
            updatedAt: now()))
        return try await drive()
    }

    /// Read the durable record for the signed-in user, doing no external
    /// work at all.
    ///
    /// The progress surface calls this the moment it appears, to decide
    /// between asking for confirmation and picking a half-finished
    /// deletion back up. It has to be able to tell those apart WITHOUT
    /// touching CloudKit or the server: opening a screen is not consent,
    /// and a sheet that reaches for the network to render itself would
    /// make "I only wanted to look" indistinguishable from "delete my
    /// account".
    @discardableResult
    func refreshCheckpoint() throws -> AccountDeletionCheckpoint? {
        guard let identity = session.identity() else {
            checkpoint = nil
            return nil
        }
        return try reload(userID: identity.userID)
    }

    /// Finish a deletion that already committed on the server but whose
    /// response never arrived. Call this at launch, BEFORE and INDEPENDENTLY
    /// of session restore.
    ///
    /// This is the one path that must work with no signed-in user, because
    /// the situation it exists for is defined by not having one: the
    /// deletion cascaded the session that authorised it, so the next launch
    /// gets a 401 from `restoreSession`, lands in signed-out or failed, and
    /// `resume()` — which needs an identity — can never run. Without this
    /// sweep the receipt written in C4 is unreachable and the user is left
    /// staring at a sign-in screen with a checkpoint and a local garden
    /// belonging to an account that no longer exists.
    ///
    /// Only checkpoints that reached `.deletingAccount` carrying a receipt
    /// are considered, and each is resolved by the unauthenticated receipt
    /// lookup — never by the absence of a session, never by a status code.
    /// No receipt means the account is still there and the ordinary
    /// signed-in flow owns it.
    @discardableResult
    func recoverCommittedDeletions() async throws -> Outcome {
        try Task.checkCancellation()
        // Who owns the SwiftData store on this device RIGHT NOW. Erasing is
        // scoped to them and nobody else.
        //
        // The sweep has to enumerate every checkpoint, because before sign-in
        // it cannot know which one matters. But "this file's account is
        // provably deleted" and "this device's data belongs to that account"
        // are different claims, and only the second licenses destruction. A
        // stale record from an account deleted on this device months ago
        // would otherwise sign out — and wipe the garden of — whoever is
        // signed in today. Confirming a foreign receipt retires that dead
        // record and nothing else.
        let localStoreOwner = session.localStoreOwnerID()
        var ownDeletionConfirmed = false

        for candidate in store.allCheckpoints() {
            let checkpoint = candidate.checkpoint
            guard checkpoint.deletesOwnAccount,
                  checkpoint.phase == .deletingAccount,
                  let receipt = checkpoint.deletionReceipt else { continue }
            // A lookup failure proves nothing either way, so it leaves the
            // record exactly where it is for the next attempt.
            guard let confirmed = (try? await server.deletionReceipt(token: receipt)).flatMap({ $0 }),
                  confirmed.deleted else { continue }
            self.checkpoint = checkpoint
            lease = candidate.lease
            try? clear(userID: checkpoint.userID)
            // A nil owner is NOT a match. The identity cache is the only
            // record of who this store belongs to; without it, refusing to
            // erase leaves stale data behind, which is the recoverable
            // failure. Erasing on a guess is not.
            if let localStoreOwner, checkpoint.userID == localStoreOwner {
                ownDeletionConfirmed = true
            }
        }

        guard ownDeletionConfirmed else { return .idle }
        handoff = nil
        pendingDestination = nil
        // Erases local data and returns the app to signed out. Safe to run
        // from an already-signed-out state — it is the only way the garden
        // of a deleted account gets removed from this device.
        await session.signOut()
        return .deleted
    }

    /// Abandon a transfer and forget the local deletion.
    ///
    /// Legal for a SHARED OWNER only, and only while the original garden is
    /// still there. Two separate refusals, for two separate reasons:
    ///
    ///   - Once the source zone is gone the user is committed: cancelling
    ///     would leave them with no garden, an account the server refuses
    ///     to delete, and no way back.
    ///   - Every other role has already begun — or may already have
    ///     finished — an irreversible CloudKit step by the time it has a
    ///     checkpoint at all. `participantLeaving` is written BEFORE the
    ///     share is left and stays put if leaving succeeds but the absence
    ///     check fails; `ownerDeletingZone` is the same over a zone that
    ///     may already be deleted. Nothing here can tell those apart from
    ///     "not started", and clearing the checkpoint would throw away the
    ///     only record that the work is owed. A successor, meanwhile, has
    ///     no deletion of their own to abandon.
    func cancel() async throws {
        let identity = try requireIdentity()
        guard let current = try reload(userID: identity.userID) else { return }
        guard current.role == .sharedOwner else {
            throw AccountDeletionCoordinatorError.cancelNotAvailable(role: current.role)
        }
        guard !current.phase.sourceIsGone else {
            throw AccountDeletionCoordinatorError.cancelAfterSourceDeletion
        }
        if let transferID = current.transferID {
            _ = try await server.cancelTransfer(id: transferID)
        }
        try clear(userID: identity.userID)
    }

    // MARK: - The machine

    private enum StepResult {
        /// The phase moved; run the next step now.
        case again
        /// Nothing more this device can do right now.
        case settled(Outcome)
    }

    /// Upper bound on steps in one drive. Every step either advances the
    /// phase, settles, or throws, so this can only trip on a seam that keeps
    /// reporting a phase it never leaves — in which case spinning forever
    /// against CloudKit and the server is the worse outcome.
    private static let maximumSteps = 24

    private func drive() async throws -> Outcome {
        var steps = 0
        while true {
            try Task.checkCancellation()
            guard let current = checkpoint else { return .idle }
            steps += 1
            guard steps <= Self.maximumSteps else {
                throw AccountDeletionCoordinatorError.stalled(phase: current.phase)
            }

            do {
                switch try await step(current) {
                case .again: continue
                case .settled(let outcome): return outcome
                }
            } catch {
                var surfaced = error
                if let durable = Self.durablePhase(in: error) {
                    do {
                        switch try adopt(durable, at: current) {
                        case .retry: continue
                        case .settled(let outcome): return outcome
                        case .unhandled: break
                        }
                    } catch let adoptionError {
                        surfaced = adoptionError
                    }
                }
                noteFailure(surfaced, at: current.phase)
                throw surfaced
            }
        }
    }

    private func step(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        switch (current.role, current.phase) {

        // ── Participant ────────────────────────────────────────────────
        case (.participant, .participantLeaving):
            let zoneID = try sourceZoneID(current)
            try await cloudKit.leaveSharedGarden(zoneID: zoneID)
            guard try await cloudKit.sharedZoneIsAbsent(zoneID: zoneID) else {
                // The share is still readable. Asking the server to delete
                // the account now would strand the user inside somebody
                // else's garden with no account to leave it from.
                throw AccountDeletionCoordinatorError.zoneStillPresent(zoneName: zoneID.zoneName)
            }
            try advance(current, to: .deletingAccount)
            return .again

        // ── Solo owner ─────────────────────────────────────────────────
        case (.soloOwner, .ownerDeletingZone):
            let zoneID = try sourceZoneID(current)
            try await cloudKit.deleteOwnedZone(zoneID: zoneID)
            guard try await cloudKit.ownedZoneIsAbsent(zoneID: zoneID) else {
                throw AccountDeletionCoordinatorError.zoneStillPresent(zoneName: zoneID.zoneName)
            }
            try advance(current, to: .deletingAccount)
            return .again

        // ── Shared owner ───────────────────────────────────────────────
        case (.sharedOwner, .transferPending):
            return try await openOrResumeTransfer(current)

        case (.sharedOwner, .successorBound), (.sharedOwner, .ownerVerified):
            // Nothing to do but read the durable phase; the successor moves
            // it next.
            let transferID = try transferID(current)
            return try follow(current, try await server.transfer(id: transferID))

        case (.sharedOwner, .destinationReady):
            return try await acceptDestinationShare(current)

        case (.sharedOwner, .destinationShareAccepted):
            return try await copyGraphToDestination(current)

        case (.sharedOwner, .copyComplete):
            return try await postOwnerVerification(current)

        case (.sharedOwner, .verified):
            return try await deleteSourceZone(current)

        case (.sharedOwner, .sourceZoneDeleting):
            return try await deleteLeasedSourceZone(current)

        case (.sharedOwner, .sourceZoneDeleted):
            let transferID = try transferID(current)
            _ = try await server.markSourceDeleted(id: transferID)
            try advance(current, to: .deletingAccount)
            return .again

        case (.sharedOwner, .sourceDeleted):
            // The durable row already records the source as gone — reached
            // by reloading after a crash between the two. The only work left
            // is the account itself.
            try advance(current, to: .deletingAccount)
            return .again

        // ── Successor ──────────────────────────────────────────────────
        case (.successor, .successorBound):
            return try await createDestination(current)

        case (.successor, .destinationZoneCreated):
            return try await publishDestination(current)

        case (.successor, .destinationReady):
            let transferID = try transferID(current)
            return try follow(current, try await server.transfer(id: transferID))

        case (.successor, .ownerVerified):
            return try await postSuccessorVerification(current)

        case (.successor, .verified), (.successor, .sourceDeleted):
            // Both digests matched server-side. The garden is not actually
            // theirs until this device stops pointing at the departing
            // owner's shared zone, and the owner is about to delete it —
            // so the debt is written down before it is paid.
            try advance(current, to: .successorAdopting)
            return .again

        case (.successor, .successorAdopting):
            try await session.adoptTransferredGarden(try sourceHouseholdID(current))
            try clear(userID: current.userID)
            return .settled(.handoffComplete)

        // ── Every deleting role ────────────────────────────────────────
        case (_, .deletingAccount):
            return try await deleteAccount(current)

        default:
            throw AccountDeletionCoordinatorError.unexpectedPhase(current.phase, role: current.role)
        }
    }

    // MARK: - Shared-owner steps

    private func openOrResumeTransfer(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let transfer: AccountDeletionTransferDTO
        if let existingID = current.transferID {
            var durable = try await server.transfer(id: existingID)
            if durable.phase == .pendingSuccessor, liveHandoff?.transferID != durable.id {
                // No link in memory. The raw token was never written down —
                // the server keeps only its hash — so a relaunch, or an
                // expiry, leaves the owner with a transfer and nothing to
                // share. Rotating mints a usable link and invalidates the
                // stale one; the spec caps the TOKEN's life, not the
                // request's. Skipped while we still hold the link, so
                // repeated resumes do not churn the user's URL.
                let rotated = try await server.rotateHandoffToken(id: existingID)
                remember(rotated)
                durable = rotated.transfer
            }
            transfer = durable
        } else {
            let created = try await server.createTransfer()
            remember(created)
            transfer = created.transfer
        }
        return try follow(current, transfer)
    }

    private func acceptDestinationShare(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let transferID = try transferID(current)
        let transfer = try await server.transfer(id: transferID)
        guard transfer.phase == .destinationReady else { return try follow(current, transfer) }
        guard let zoneName = transfer.destination_zone_name,
              let ownerName = transfer.destination_zone_owner_name,
              let shareURLString = transfer.destination_share_url,
              let shareURL = URL(string: shareURLString) else {
            throw AccountDeletionCoordinatorError.destinationUnavailable
        }

        let accepted = try await cloudKit.acceptShare(at: shareURL)
        // The zone the link resolved to must be the zone the successor told
        // the server they own. If it is not, the copy would land somewhere
        // the successor does not control — and the digests would still
        // match, because a digest deliberately says nothing about the zone
        // it came from.
        guard accepted.zoneName == zoneName, accepted.ownerName == ownerName else {
            throw AccountDeletionCoordinatorError.destinationOwnershipMismatch(
                expected: Self.zoneDescription(zoneName: zoneName, ownerName: ownerName),
                found: Self.zoneDescription(zoneName: accepted.zoneName, ownerName: accepted.ownerName))
        }
        try advance(current, to: .destinationShareAccepted) {
            $0.destinationZoneName = zoneName
            $0.destinationZoneOwnerName = ownerName
        }
        return .again
    }

    private func copyGraphToDestination(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let source = try sourceZoneID(current)
        let destination = try destinationZoneID(current)
        // An absent source here is a failure, never a completed deletion.
        // Only the source-deletion phase is allowed to read absence as
        // success (spec § "Failure invariants").
        let records = try await cloudKit.fetchRecords(in: source)
        let plan = try HouseholdGraphCopier.plan(records, from: source, to: destination)
        for batch in plan.batches {
            // Batch order is a dependency order: a `.deleteSelf` child
            // cannot be saved before its parent exists. And the policy is
            // required, not advisory — destination records are built fresh,
            // so they carry no change tag and would lose to the successor's
            // pre-existing root (and to anything a previous attempt already
            // landed) under any other policy.
            try await cloudKit.saveRecords(batch, policy: plan.savePolicy, in: destination)
        }
        try advance(current, to: .copyComplete)
        return .again
    }

    private func postOwnerVerification(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let transferID = try transferID(current)
        let source = try sourceZoneID(current)
        let destination = try destinationZoneID(current)

        // BOTH sides, and compared here.
        //
        // The server's dual gate gets one document from the owner and one
        // from the successor — but both are computed from the DESTINATION,
        // so on their own they only prove the two devices are looking at the
        // same zone. A copy that silently dropped a record would produce two
        // perfectly matching documents over the same truncated garden and
        // authorise deleting the complete original. The comparison that
        // actually matters is this one: destination == source, made by the
        // only device that can still see both. Re-reading the source is safe
        // at this phase — nothing has deleted it, and nothing may until the
        // lease is taken much later.
        let sourceRecords = try await cloudKit.fetchRecords(in: source)
        let sourceDigest = try HouseholdGraphDigester.digest(of: sourceRecords, in: source)
        let copied = try await cloudKit.fetchRecords(in: destination)
        let destinationDigest = try HouseholdGraphDigester.digest(of: copied, in: destination)

        guard sourceDigest.sha256 == destinationDigest.sha256 else {
            throw AccountDeletionCoordinatorError.copyDoesNotMatchSource(
                source: sourceDigest.sha256, destination: destinationDigest.sha256)
        }
        guard sourceDigest.counts == destinationDigest.counts else {
            throw AccountDeletionCoordinatorError.recordCountMismatch(
                owner: sourceDigest.counts, successor: destinationDigest.counts)
        }

        return try follow(current,
                          try await server.putOwnerVerification(id: transferID, digest: destinationDigest))
    }

    private func deleteSourceZone(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let transferID = try transferID(current)
        // Always re-read before the irreversible step. A local `.verified`
        // is a memory of an answer; this is the answer.
        let transfer = try await server.transfer(id: transferID)
        guard transfer.phase == .verified else { return try follow(current, transfer) }
        try assertAuthorizesSourceDeletion(transfer, current)

        // Take the lease, and do not touch CloudKit until it is granted.
        //
        // Reading `verified` is not authorisation, it is a memory of one:
        // between this read and the delete, a second owner device can cancel
        // a still-`verified` transfer, or the successor can vanish. Either
        // leaves the source destroyed with no route to `source_deleted` and
        // therefore no route to deleting the account. The lease closes that
        // window from the server side — it revalidates successor ownership
        // and permanently forbids cancellation — and moving the checkpoint
        // to `.sourceZoneDeleting` closes it from this side, because
        // `cancel()` refuses from there even while the zone still exists.
        let leased = try await server.acquireSourceDeletionLease(id: transferID)
        guard leased.phase == .sourceDeleting || leased.phase == .sourceDeleted else {
            return try follow(current, leased)
        }
        return try follow(current, leased)
    }

    /// Runs only under the server's source-deletion lease.
    private func deleteLeasedSourceZone(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let source = try sourceZoneID(current)
        // Idempotent by construction: deleting an already-absent zone is a
        // no-op, so a crash between the delete and this checkpoint advance
        // resumes straight through.
        try await cloudKit.deleteOwnedZone(zoneID: source)
        guard try await cloudKit.ownedZoneIsAbsent(zoneID: source) else {
            throw AccountDeletionCoordinatorError.zoneStillPresent(zoneName: source.zoneName)
        }
        try advance(current, to: .sourceZoneDeleted)
        return .again
    }

    /// The last gate in front of an irreversible deletion. The server has
    /// already enforced all of this to reach `verified`; re-checking here
    /// means a client bug, a spoofed response, or a transfer that moved
    /// under us cannot turn into a lost garden.
    private func assertAuthorizesSourceDeletion(
        _ transfer: AccountDeletionTransferDTO,
        _ current: AccountDeletionCheckpoint
    ) throws {
        guard let ownerDigest = transfer.owner_digest, let successorDigest = transfer.successor_digest else {
            throw AccountDeletionCoordinatorError.verificationIncomplete(transferID: transfer.id)
        }
        guard ownerDigest.digest == successorDigest.digest else {
            throw AccountDeletionCoordinatorError.digestMismatch(
                owner: ownerDigest.digest, successor: successorDigest.digest)
        }
        // The census is checked separately: an implementation that ever
        // produced the same hash for two different graphs would still be
        // caught by a differing record count.
        guard ownerDigest.record_counts == successorDigest.record_counts else {
            throw AccountDeletionCoordinatorError.recordCountMismatch(
                owner: ownerDigest.record_counts, successor: successorDigest.record_counts)
        }
        let recorded = Self.zoneDescription(zoneName: transfer.destination_zone_name,
                                            ownerName: transfer.destination_zone_owner_name)
        let accepted = Self.zoneDescription(zoneName: current.destinationZoneName,
                                            ownerName: current.destinationZoneOwnerName)
        guard transfer.destination_zone_name != nil,
              transfer.destination_zone_owner_name != nil,
              recorded == accepted else {
            throw AccountDeletionCoordinatorError.destinationOwnershipMismatch(
                expected: recorded, found: accepted)
        }
    }

    // MARK: - Successor steps

    private func createDestination(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let householdID = try sourceHouseholdID(current)
        let destination = try await cloudKit.createDestination(
            householdID: householdID, title: Self.destinationTitle)
        pendingDestination = destination
        try advance(current, to: .destinationZoneCreated) {
            $0.destinationZoneName = destination.zoneID.zoneName
            $0.destinationZoneOwnerName = destination.ownerRecordName
        }
        return .again
    }

    private func publishDestination(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let transferID = try transferID(current)
        let householdID = try sourceHouseholdID(current)
        let destination: AccountDeletionDestination
        if let cached = pendingDestination, cached.zoneID.zoneName == current.destinationZoneName {
            destination = cached
        } else {
            // Cold resume: the share URL is a capability and is never
            // persisted, so it is re-derived. Creating the destination is
            // fetch-or-create on both the zone and its share, so this adopts
            // what the interrupted attempt built rather than forking a
            // second garden.
            let rebuilt = try await cloudKit.createDestination(
                householdID: householdID, title: Self.destinationTitle)
            guard current.destinationZoneName == nil || current.destinationZoneName == rebuilt.zoneID.zoneName else {
                throw AccountDeletionCoordinatorError.destinationOwnershipMismatch(
                    expected: Self.zoneDescription(zoneName: current.destinationZoneName,
                                                   ownerName: current.destinationZoneOwnerName),
                    found: Self.zoneDescription(zoneName: rebuilt.zoneID.zoneName,
                                                ownerName: rebuilt.ownerRecordName))
            }
            pendingDestination = rebuilt
            destination = rebuilt
        }

        let transfer = try await server.putDestination(
            id: transferID,
            zoneName: destination.zoneID.zoneName,
            zoneOwnerName: destination.ownerRecordName,
            shareRecordName: destination.shareRecordName,
            shareURL: destination.shareURL.absoluteString)
        return try follow(current, transfer)
    }

    private func postSuccessorVerification(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        let transferID = try transferID(current)
        guard let zoneName = current.destinationZoneName,
              let ownerRecordName = current.destinationZoneOwnerName else {
            throw AccountDeletionCoordinatorError.destinationUnavailable
        }
        let destination = try destinationZoneID(current)
        let records = try await cloudKit.fetchRecords(in: destination)
        let digest = try HouseholdGraphDigester.digest(of: records, in: destination)
        let transfer = try await server.putSuccessorVerification(
            id: transferID, digest: digest,
            destinationZoneName: zoneName,
            destinationZoneOwnerName: ownerRecordName)
        guard transfer.phase == .verified else { return try follow(current, transfer) }
        try advance(current, to: .successorAdopting)
        return .again
    }

    // MARK: - The last step

    private func deleteAccount(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        guard let disposition = current.disposition else {
            // The disposition is an assertion that the CloudKit work is
            // done. If the checkpoint cannot produce one — a shared owner
            // that lost its transfer id, a successor that should never be
            // here — the honest move is to stop, not to claim a weaker
            // disposition the server would happily accept.
            throw AccountDeletionCoordinatorError.dispositionUnavailable(
                phase: current.phase, role: current.role)
        }
        // A nonce from a previous attempt means the destructive call may
        // already have committed without us hearing about it.
        if let existing = current.deletionReceipt,
           try await server.deletionReceipt(token: existing) != nil {
            return try await finishDeletedAccount(current)
        }

        // Mint and PERSIST before the destructive call. Deleting the account
        // cascades the session that authorised it, so once the request is in
        // flight there is no credential left to ask "did that happen?". This
        // nonce is the only thing that can answer, and a nonce we cannot
        // name afterwards is no better than none.
        var pending = current
        if pending.deletionReceipt == nil {
            let minted = newReceipt()
            try advance(current, to: .deletingAccount) { $0.deletionReceipt = minted }
            pending = checkpoint ?? pending
        }
        let receipt = try requireReceipt(pending)

        do {
            guard try await server.deleteAccount(
                disposition: disposition, receiptHash: Self.receiptHash(of: receipt)) else {
                throw AccountDeletionCoordinatorError.accountDeletionNotConfirmed
            }
        } catch {
            // 401 is what a LOST SUCCESS looks like — the session is gone
            // because the deletion took it — and it is also what a merely
            // expired token looks like. Never infer success from the status;
            // ask for the receipt, which only exists if the transaction
            // committed. A lookup that itself fails proves nothing either,
            // so it leaves the original error standing and the flow
            // resumable.
            let confirmed = (try? await server.deletionReceipt(token: receipt)).flatMap { $0 }
            guard confirmed != nil else { throw error }
            return try await finishDeletedAccount(pending)
        }
        return try await finishDeletedAccount(pending)
    }

    private func finishDeletedAccount(_ current: AccountDeletionCheckpoint) async throws -> StepResult {
        // The account no longer exists. A checkpoint file that refuses to go
        // away must not keep the user in a signed-in session holding a dead
        // token, so removal is best effort and sign-out is not.
        try? clear(userID: current.userID)
        handoff = nil
        pendingDestination = nil
        await session.signOut()
        return .settled(.deleted)
    }

    private func requireReceipt(_ current: AccountDeletionCheckpoint) throws -> String {
        guard let receipt = current.deletionReceipt else {
            throw AccountDeletionCoordinatorError.deletionReceiptUnavailable
        }
        return receipt
    }

    // MARK: - Durable-phase reconciliation

    private enum Adoption {
        case retry
        case settled(Outcome)
        case unhandled
    }

    /// Move the checkpoint onto the phase the SERVER holds. Used after a 409
    /// `phase_conflict`, which is the server telling us another device moved
    /// the transfer while we were working from a stale view.
    private func adopt(
        _ durable: AccountDeletionTransferPhase,
        at current: AccountDeletionCheckpoint
    ) throws -> Adoption {
        guard let local = AccountDeletionCheckpoint.Phase(transferPhase: durable) else {
            return .settled(try handleCancellation(at: current, transferID: current.transferID))
        }
        // Adopting the phase we are already on would spin. Whatever went
        // wrong was not a stale view.
        guard local != current.phase else { return .unhandled }
        var next = current
        next.phase = local
        next.lastFailure = nil
        next.updatedAt = now()
        try persist(next)
        return .retry
    }

    /// Follow a transfer we just read or just changed.
    private func follow(
        _ current: AccountDeletionCheckpoint,
        _ transfer: AccountDeletionTransferDTO
    ) throws -> StepResult {
        guard let local = AccountDeletionCheckpoint.Phase(transferPhase: transfer.phase) else {
            return .settled(try handleCancellation(at: current, transferID: transfer.id))
        }
        let unchanged = local == current.phase
            && current.transferID == transfer.id
            && current.lastFailure == nil
        if !unchanged {
            var next = current
            next.transferID = transfer.id
            next.phase = local
            next.lastFailure = nil
            next.updatedAt = now()
            try persist(next)
        }
        if local == current.phase || Self.waitsForTheOtherDevice(local, role: current.role) {
            return .settled(.waiting(local))
        }
        return .again
    }

    /// What to do when the durable phase is `cancelled` — the only transfer
    /// phase with no step to resume. Either the flow simply ends, or, if the
    /// source garden is already gone, it cannot.
    private func handleCancellation(
        at current: AccountDeletionCheckpoint,
        transferID: String?
    ) throws -> Outcome {
        guard !current.phase.sourceIsGone else {
            // The garden is already gone and the transfer that authorises
            // deleting the account has been withdrawn. There is no safe
            // automatic move left: keep the credentials, keep the
            // checkpoint, and surface it.
            throw AccountDeletionCoordinatorError.transferCancelledAfterSourceDeletion(
                transferID: transferID ?? current.transferID ?? "")
        }
        // Cancelled before anything irreversible: the original garden is
        // untouched, so there is nothing to resume.
        try clear(userID: current.userID)
        return .idle
    }

    /// Phases whose next move belongs to the other device. Settling here
    /// instead of looping saves a redundant read and, more importantly, lets
    /// a caller render an honest "waiting for…".
    private static func waitsForTheOtherDevice(
        _ phase: AccountDeletionCheckpoint.Phase,
        role: AccountDeletionCheckpoint.Role
    ) -> Bool {
        switch (role, phase) {
        case (.sharedOwner, .transferPending),      // nobody has opened the link
             (.sharedOwner, .successorBound),       // no destination published yet
             (.sharedOwner, .ownerVerified),        // successor has not verified
             (.successor, .destinationReady):       // owner has not copied yet
            return true
        default:
            return false
        }
    }

    /// The durable phase a 409 carries, or `nil` for anything else —
    /// including a phase string this build cannot name, which must fail
    /// rather than approximate.
    private static func durablePhase(in error: Error) -> AccountDeletionTransferPhase? {
        guard let serverError = error as? SeedkeepError,
              serverError.code == "phase_conflict",
              let raw = serverError.conflictPhase else { return nil }
        return AccountDeletionTransferPhase(rawValue: raw)
    }

    // MARK: - Checkpoint plumbing

    private func reload(userID: String) throws -> AccountDeletionCheckpoint? {
        guard let loaded = try store.load(userID: userID) else {
            checkpoint = nil
            lease = nil
            return nil
        }
        checkpoint = loaded.checkpoint
        lease = loaded.lease
        return loaded.checkpoint
    }

    private func persist(_ next: AccountDeletionCheckpoint) throws {
        do {
            lease = try store.save(next, lease: lease)
            checkpoint = next
        } catch {
            // Rejected: somebody else moved the record on. Drop the lease so
            // nothing here can write over whatever they decided.
            lease = nil
            throw error
        }
    }

    private func clear(userID: String) throws {
        try store.clear(userID: userID)
        checkpoint = nil
        lease = nil
    }

    private func advance(
        _ current: AccountDeletionCheckpoint,
        to phase: AccountDeletionCheckpoint.Phase,
        _ mutate: (inout AccountDeletionCheckpoint) -> Void = { _ in }
    ) throws {
        var next = current
        mutate(&next)
        next.phase = phase
        next.lastFailure = nil
        next.updatedAt = now()
        try persist(next)
    }

    /// Record which step failed so a relaunch can name it instead of showing
    /// a bare spinner. Best effort: the caller's error is the one that
    /// matters, and a note that cannot be written must not replace it.
    private func noteFailure(_ error: Error, at phase: AccountDeletionCheckpoint.Phase) {
        guard var next = checkpoint else { return }
        next.lastFailure = .init(phase: phase, message: humanizeDeletionError(error),
                                 occurredAt: now())
        next.updatedAt = now()
        try? persist(next)
    }

    private func remember(_ created: WireResponses.AccountDeletionTransferOne) {
        guard let token = created.handoff_token else { return }
        handoff = Handoff(transferID: created.transfer.id,
                          token: token,
                          expiresAt: created.transfer.handoff_expires_at)
    }

    // MARK: - Small readers

    private static let destinationTitle = "Seedkeep garden"

    private func requireIdentity() throws -> AccountDeletionSession.Identity {
        guard let identity = session.identity() else {
            throw AccountDeletionCoordinatorError.notSignedIn
        }
        return identity
    }

    private func makeCheckpoint(
        _ identity: AccountDeletionSession.Identity,
        role: AccountDeletionCheckpoint.Role,
        phase: AccountDeletionCheckpoint.Phase,
        source: CKRecordZone.ID?
    ) -> AccountDeletionCheckpoint {
        AccountDeletionCheckpoint(
            userID: identity.userID,
            role: role,
            phase: phase,
            sourceZoneName: source?.zoneName,
            sourceZoneOwnerName: source?.ownerName,
            updatedAt: now())
    }

    private func transferID(_ current: AccountDeletionCheckpoint) throws -> String {
        guard let transferID = current.transferID else {
            throw AccountDeletionCoordinatorError.transferUnknown(phase: current.phase)
        }
        return transferID
    }

    private func sourceZoneID(_ current: AccountDeletionCheckpoint) throws -> CKRecordZone.ID {
        guard let zoneName = current.sourceZoneName, let ownerName = current.sourceZoneOwnerName else {
            throw AccountDeletionCoordinatorError.sourceZoneUnknown(phase: current.phase)
        }
        return CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }

    private func sourceHouseholdID(_ current: AccountDeletionCheckpoint) throws -> String {
        guard let zoneName = current.sourceZoneName else {
            throw AccountDeletionCoordinatorError.sourceZoneUnknown(phase: current.phase)
        }
        return SeedkeepRecordNames.householdID(fromZoneName: zoneName)
    }

    /// The destination as THIS device addresses it.
    ///
    /// The stored `destinationZoneOwnerName` is always the successor's
    /// CloudKit user record name — the ownership claim both parties compare
    /// — which is also the `ownerName` of the departing owner's shared copy.
    /// On the successor's own device the same zone lives in their private
    /// database, so it is addressed by the current-user placeholder instead.
    private func destinationZoneID(_ current: AccountDeletionCheckpoint) throws -> CKRecordZone.ID {
        guard let zoneName = current.destinationZoneName else {
            throw AccountDeletionCoordinatorError.destinationUnavailable
        }
        switch current.role {
        case .successor:
            return CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        case .noCloudKitGarden, .participant, .soloOwner, .sharedOwner:
            guard let ownerName = current.destinationZoneOwnerName else {
                throw AccountDeletionCoordinatorError.destinationUnavailable
            }
            return CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        }
    }

    private static func zoneDescription(zoneName: String?, ownerName: String?) -> String {
        "\(zoneName ?? "—")|\(ownerName ?? "—")"
    }
}

// MARK: - Session seam

/// Who is signed in, and how to end their session.
///
/// Two closures rather than a reference to `AppEnvironment`: the coordinator
/// must not be able to touch anything else about the app, and a test has to
/// be able to prove that sign-out did not happen.
struct AccountDeletionSession {
    struct Identity: Equatable, Sendable {
        let userID: String
        let householdID: String
    }

    /// `nil` when nobody is signed in.
    var identity: @MainActor () -> Identity?

    /// Who the locally cached data belongs to, whether or not there is a
    /// live session — the app's own record of "the owner of the local
    /// store".
    ///
    /// Separate from `identity` on purpose. The launch sweep runs before
    /// sign-in, so `identity` is nil exactly when the question matters, and
    /// answering it wrong in the permissive direction erases a live
    /// account's garden on behalf of a dead one. `nil` here means unknown,
    /// which is treated as "not a match" and never as "anyone".
    var localStoreOwnerID: @MainActor () -> String?

    /// Clears the token, erases local data, and returns the app to signed
    /// out. Called exactly once, after the server confirms the account is
    /// gone.
    var signOut: @MainActor () async -> Void

    /// Cut this device over to a garden it has just received as a
    /// successor: adopt the server-rehomed household, stop being a
    /// participant of the departing owner's share, and rebuild the
    /// CloudKit scope as the owner of the destination zone.
    ///
    /// THROWS on purpose. Until this succeeds the app is still pointed at
    /// a shared zone the departing owner is about to delete, so a silent
    /// failure would leave the successor watching their new garden
    /// disappear. The coordinator holds the checkpoint at
    /// `.successorAdopting` until it lands, which is what makes the crash
    /// window between server verification and local adoption recoverable.
    ///
    /// The parameter is the household id the garden now lives under —
    /// unchanged by the transfer, but re-homed to this user server-side.
    var adoptTransferredGarden: @MainActor (String) async throws -> Void

    init(
        identity: @escaping @MainActor () -> Identity?,
        localStoreOwnerID: @escaping @MainActor () -> String?,
        signOut: @escaping @MainActor () async -> Void,
        adoptTransferredGarden: @escaping @MainActor (String) async throws -> Void
    ) {
        self.identity = identity
        self.localStoreOwnerID = localStoreOwnerID
        self.signOut = signOut
        self.adoptTransferredGarden = adoptTransferredGarden
    }
}

// MARK: - Errors

/// Every way the coordinator refuses to continue. All of them leave the
/// account, its credentials, and the garden exactly as they were.
enum AccountDeletionCoordinatorError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Nobody is signed in, so there is no account to delete.
    case notSignedIn
    /// A zone was deleted and is still readable. Never treated as success.
    case zoneStillPresent(zoneName: String)
    /// The transfer is verified but a digest document is missing.
    case verificationIncomplete(transferID: String)
    /// The owner's and successor's canonical hashes disagree.
    case digestMismatch(owner: String, successor: String)
    /// The hashes agree but the per-type censuses do not.
    case recordCountMismatch(owner: [String: Int], successor: [String: Int])
    /// The copied destination is not equal to the source it came from.
    case copyDoesNotMatchSource(source: String, destination: String)
    /// The deletion nonce could not be established, so a lost response
    /// would be unrecoverable. Refuse rather than delete blind.
    case deletionReceiptUnavailable
    /// The destination the server recorded is not the zone this device is
    /// working with.
    case destinationOwnershipMismatch(expected: String, found: String)
    /// The successor has not published a usable destination zone/share.
    case destinationUnavailable
    /// This device has not accepted the source garden's share, so it cannot
    /// prove it may receive the handoff.
    case notASourceParticipant
    /// The handoff names a garden this device cannot see.
    case sourceHouseholdMismatch(expected: String, found: String)
    /// A handoff link arrived while this account had its own deletion (or a
    /// different handoff) under way.
    case deletionAlreadyInProgress(phase: AccountDeletionCheckpoint.Phase)
    /// Cancelling is refused once the original garden is gone.
    case cancelAfterSourceDeletion
    /// Cancelling is refused for a role whose irreversible CloudKit step
    /// may already have run.
    case cancelNotAvailable(role: AccountDeletionCheckpoint.Role)
    /// The handoff link is past its 72-hour life.
    case handoffExpired
    /// Somebody has already accepted this handoff.
    case handoffAlreadyUsed
    /// The departing owner withdrew the transfer.
    case handoffWithdrawn
    /// The transfer was withdrawn after the source zone was deleted — the
    /// one state the client cannot resolve on its own.
    case transferCancelledAfterSourceDeletion(transferID: String)
    /// The server did not confirm the deletion.
    case accountDeletionNotConfirmed
    /// A shared-owner flow with no transfer id, or a successor that reached
    /// the account-deletion step. Fails rather than downgrading the claim.
    case dispositionUnavailable(phase: AccountDeletionCheckpoint.Phase, role: AccountDeletionCheckpoint.Role)
    case transferUnknown(phase: AccountDeletionCheckpoint.Phase)
    case sourceZoneUnknown(phase: AccountDeletionCheckpoint.Phase)
    case unexpectedPhase(AccountDeletionCheckpoint.Phase, role: AccountDeletionCheckpoint.Role)
    /// The flow stopped making progress. Defensive; a seam that never leaves
    /// a phase would otherwise loop against CloudKit and the server forever.
    case stalled(phase: AccountDeletionCheckpoint.Phase)

    var description: String {
        switch self {
        case .notSignedIn:
            return "There is no signed-in account to delete."
        case .zoneStillPresent(let zoneName):
            return "The iCloud garden \(zoneName) is still there. Nothing else was changed."
        case .verificationIncomplete(let transferID):
            return "Transfer \(transferID) has not been verified by both devices yet."
        case .digestMismatch:
            return "The copied garden does not match the original, so the original was kept."
        case .recordCountMismatch:
            return "The copied garden has a different number of records, so the original was kept."
        case .copyDoesNotMatchSource:
            return "The copy does not match your garden yet, so nothing was deleted."
        case .deletionReceiptUnavailable:
            return "Could not prepare a safe deletion. Nothing was changed."
        case .destinationOwnershipMismatch(let expected, let found):
            return "The successor's garden moved (expected \(expected), found \(found)); the original was kept."
        case .destinationUnavailable:
            return "The successor has not finished preparing their garden yet."
        case .notASourceParticipant:
            return "Join the shared garden before accepting the handoff."
        case .sourceHouseholdMismatch:
            return "This handoff is for a garden this device cannot see."
        case .deletionAlreadyInProgress(let phase):
            return "Something else is already in progress on this account (\(phase.rawValue))."
        case .cancelAfterSourceDeletion:
            return "The original garden has already been handed over; deletion has to finish."
        case .cancelNotAvailable(let role):
            switch role {
            case .participant:
                return "Leaving the shared garden has already started, so this has to finish."
            case .soloOwner:
                return "Deleting your iCloud garden has already started, so this has to finish."
            case .successor:
                return "This is somebody else's handoff — there is no deletion here to cancel."
            case .noCloudKitGarden, .sharedOwner:
                return "This step has already started, so it has to finish."
            }
        case .handoffExpired:
            return "This handoff link has expired. Ask for a new one."
        case .handoffAlreadyUsed:
            return "This garden has already been handed to someone. The link is no longer usable."
        case .handoffWithdrawn:
            return "This handoff was withdrawn, so it is no longer available."
        case .transferCancelledAfterSourceDeletion(let transferID):
            return "Transfer \(transferID) was cancelled after the original garden was deleted."
        case .accountDeletionNotConfirmed:
            return "The server did not confirm the account deletion, so you are still signed in."
        case .dispositionUnavailable(let phase, let role):
            return "Cannot state what happened to the iCloud garden from \(role.rawValue)/\(phase.rawValue)."
        case .transferUnknown(let phase):
            return "No transfer is recorded for \(phase.rawValue)."
        case .sourceZoneUnknown(let phase):
            return "No source garden is recorded for \(phase.rawValue)."
        case .unexpectedPhase(let phase, let role):
            return "\(role.rawValue) cannot be at \(phase.rawValue)."
        case .stalled(let phase):
            return "Account deletion stopped making progress at \(phase.rawValue)."
        }
    }

    var errorDescription: String? { description }
}

/// User-facing copy for anything the deletion flow can fail with.
///
/// `humanizeError` flattens every error it does not recognise to one
/// generic sentence, which is right for machine strings and wrong here:
/// each `AccountDeletionCoordinatorError` case is already written as a
/// user sentence, and WHICH one it is carries the only information that
/// matters. "The original was kept", "the iCloud garden is still there"
/// and "this handoff is for a garden this device cannot see" are three
/// different situations, and collapsing them into "Something went wrong"
/// leaves a user who is mid-deletion with no idea whether their garden
/// survived. None of the cases interpolate a token or a credential.
func humanizeDeletionError(_ error: Error) -> String {
    if let deletionError = error as? AccountDeletionCoordinatorError {
        return deletionError.description
    }
    // Reached only past the expired-inspection recovery in
    // `acceptHandoff`: a transfer nobody ever accepted has expired on the
    // SERVER side, in a shape `previewHandoff` never produces because it
    // stopped this device before spending the token. `token_expired` is
    // `/accept`'s own name for that; `handoff_expired` is included so an
    // inspection failure that reaches here for any other reason still
    // reads as an expiry rather than the generic fallback.
    if let seedkeepError = error as? SeedkeepError,
       seedkeepError.code == "token_expired" || seedkeepError.code == "handoff_expired" {
        return "This handoff link has expired. Ask for a new one."
    }
    return humanizeError(error)
}
