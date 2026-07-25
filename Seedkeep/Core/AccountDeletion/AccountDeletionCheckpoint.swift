import Foundation
import SeedkeepKit

/// The durable record of an account deletion — or of a successor's half of
/// a garden handoff — that is part-way done.
///
/// Deleting a Seedkeep account is not one operation. It is a sequence of
/// CloudKit work followed by `DELETE /api/me`, and the CloudKit half is
/// irreversible. Between "the source zone is gone" and "the server says
/// the account is deleted" the app is in a state nothing else can
/// describe: the garden no longer exists, but the account still does. If
/// the app is killed there, only this file can tell the next launch to
/// finish the job instead of showing a signed-in user an empty garden.
///
/// Hence the shape of the type
/// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md`
/// § "Durable state"): the transfer id, the role, the current phase, the
/// source/destination zone identity, and the last recoverable error.
///
/// What it deliberately does NOT hold is the single-use handoff token.
/// That credential lives in the universal link and, server-side, only as
/// a hash; persisting it here would put a live capability into a plain
/// JSON file in Application Support for the lifetime of the flow.
struct AccountDeletionCheckpoint: Codable, Equatable, Sendable {

    /// What this device is doing. Fixed when the flow starts — it is a
    /// fact about the CloudKit share, not about progress — and it decides
    /// which phases are reachable and which `cloudkit_disposition` the
    /// final `DELETE /api/me` may claim.
    enum Role: String, Codable, Sendable, CaseIterable {
        /// Deleting this account; there is no iCloud garden to dispose of.
        case noCloudKitGarden = "no_cloudkit_garden"
        /// Deleting this account; accepted someone else's CKShare, so the
        /// CloudKit step is leaving that share.
        case participant
        /// Deleting this account; owns an unshared household zone.
        case soloOwner = "solo_owner"
        /// Deleting this account; owns a zone other people participate in,
        /// so the garden must be handed to a successor first.
        case sharedOwner = "shared_owner"
        /// NOT deleting this account. This device accepted a handoff link
        /// and is building the destination garden for a departing owner.
        /// It needs a checkpoint of its own: the accept consumed a
        /// single-use token, so a crash here cannot be recovered by
        /// re-opening the link.
        case successor
    }

    /// Which side of the server transfer this device acts as.
    ///
    /// Derived from `role` rather than stored: two independently-stored
    /// fields could disagree on disk, and the pair "owner of a deletion"
    /// / "owner party of the transfer" is one fact, not two.
    enum TransferParty: String, Sendable, Equatable {
        case owner
        case successor
    }

    /// The step the flow is ON.
    ///
    /// Written *before* the step runs and advanced only after it succeeds,
    /// so a resumed flow re-attempts exactly the step named here. Every
    /// step — CloudKit and server alike — is idempotent, which is what
    /// makes that safe (spec § "Failure invariants": "Every network/
    /// CloudKit step is idempotent and checkpointed after success").
    ///
    /// Local-only phases exist wherever a CloudKit operation lands with no
    /// server phase to record it. Without them a crash in that window is
    /// indistinguishable from a crash before the operation, and the
    /// coordinator would have to redo an expensive copy — or, worse, guess
    /// whether a zone it can no longer see was deleted by this flow.
    enum Phase: String, Codable, Sendable, CaseIterable {
        // ── Participant ────────────────────────────────────────────────
        /// Leaving the accepted share.
        case participantLeaving = "participant_leaving"

        // ── Solo owner ─────────────────────────────────────────────────
        /// Deleting the owned household zone.
        case ownerDeletingZone = "owner_deleting_zone"

        // ── Shared owner ───────────────────────────────────────────────
        /// Creating/resuming the server transfer and showing the link.
        case transferPending = "transfer_pending"
        /// A successor is bound; waiting for their destination.
        case successorBound = "successor_bound"
        /// Successor-only: destination zone + share created in CloudKit,
        /// not yet posted to the server. Re-posting is idempotent; losing
        /// this would strand a zone nobody knows about.
        case destinationZoneCreated = "destination_zone_created"
        /// The destination is recorded server-side.
        case destinationReady = "destination_ready"
        /// Owner-only: the destination share has been accepted, so the
        /// owner can write into the successor's zone. The copy is next.
        case destinationShareAccepted = "destination_share_accepted"
        /// Owner-only: the graph is fully copied but the digest has not
        /// been posted. Resuming re-posts the digest instead of recopying
        /// the whole garden.
        case copyComplete = "copy_complete"
        /// The owner's digest is posted; waiting on the successor's.
        case ownerVerified = "owner_verified"
        /// Both digests matched. The owner may now ASK for the deletion
        /// lease — not delete anything.
        case verified
        /// Owner-only: the server granted the exclusive source-deletion
        /// lease (`source_deleting`) and has permanently closed
        /// cancellation for this transfer. Only from here is destroying
        /// the only copy of the garden safe: without the lease, a second
        /// device cancelling — or the successor departing — between the
        /// phase read and the CloudKit delete would leave the source gone
        /// and no route to `source_deleted`.
        case sourceZoneDeleting = "source_zone_deleting"
        /// Owner-only: the source zone is gone but the server does not
        /// know yet. This is the one window where an absent source zone is
        /// expected rather than alarming (spec § "Failure invariants":
        /// "A crash after source deletion resumes server deletion").
        case sourceZoneDeleted = "source_zone_deleted"
        /// The server has recorded the source as deleted.
        case sourceDeleted = "source_deleted"
        /// Successor-only: both digests matched server-side, but this
        /// device still points at the departing owner's shared zone. The
        /// garden is not the successor's until the app itself is cut over
        /// — household re-homed, participant marker cleared, owner
        /// coordinator rebuilt on the destination — and the owner is about
        /// to delete the source. A crash in that window would otherwise
        /// leave a successor whose app is aimed at a zone that is about to
        /// stop existing, with no record that adoption was owed.
        case successorAdopting = "successor_adopting"

        // ── Every deleting role ────────────────────────────────────────
        /// `DELETE /api/me`, then sign-out and local erase.
        case deletingAccount = "deleting_account"

        /// Where a durable server phase says the flow should resume.
        ///
        /// `nil` for `.cancelled`: a cancelled transfer has no step to
        /// resume, so the checkpoint is removed rather than rewritten.
        init?(transferPhase: AccountDeletionTransferPhase) {
            switch transferPhase {
            case .pendingSuccessor: self = .transferPending
            case .successorBound: self = .successorBound
            case .destinationReady: self = .destinationReady
            case .ownerVerified: self = .ownerVerified
            case .verified: self = .verified
            case .sourceDeleting: self = .sourceZoneDeleting
            case .sourceDeleted: self = .sourceDeleted
            case .cancelled: return nil
            }
        }

        /// The server phase this local step implies, or `nil` for a step
        /// the server never sees. Lets a resumed flow compare its
        /// checkpoint against a reloaded transfer and notice the server is
        /// ahead — the other device advanced it — instead of replaying.
        var impliedTransferPhase: AccountDeletionTransferPhase? {
            switch self {
            case .transferPending: return .pendingSuccessor
            case .successorBound, .destinationZoneCreated: return .successorBound
            case .destinationReady, .destinationShareAccepted, .copyComplete: return .destinationReady
            case .ownerVerified: return .ownerVerified
            case .verified, .successorAdopting: return .verified
            // The lease is held from here on: the zone may already be gone.
            case .sourceZoneDeleting, .sourceZoneDeleted: return .sourceDeleting
            case .sourceDeleted: return .sourceDeleted
            case .participantLeaving, .ownerDeletingZone, .deletingAccount: return nil
            }
        }

        /// True once abandoning the flow is no longer a safe answer.
        ///
        /// This deliberately starts at `.sourceZoneDeleting` — one step
        /// BEFORE the garden is actually gone. From there the server holds
        /// a lease it will not release, so a client-side cancel could only
        /// produce a transfer the server refuses to cancel, or worse, a
        /// local flow that forgets a deletion the server has already
        /// committed to. It is also the predicate the progress surface
        /// uses to decide whether to offer Cancel at all: one definition,
        /// so what the button shows and what `cancel()` permits cannot
        /// drift apart.
        var sourceIsGone: Bool {
            switch self {
            case .sourceZoneDeleting, .sourceZoneDeleted, .sourceDeleted, .deletingAccount:
                return true
            case .participantLeaving, .ownerDeletingZone, .transferPending, .successorBound,
                 .destinationZoneCreated, .destinationReady, .destinationShareAccepted,
                 .copyComplete, .ownerVerified, .verified, .successorAdopting:
                return false
            }
        }
    }

    /// The last step that failed, kept so a relaunch can show the user
    /// which phase to retry instead of a bare spinner.
    ///
    /// `message` is user-facing copy. Callers must not put credentials,
    /// tokens, or raw server payloads in it — this file is unencrypted
    /// JSON.
    struct Failure: Codable, Equatable, Sendable {
        var phase: Phase
        var message: String
        /// Epoch milliseconds.
        var occurredAt: Int64

        enum CodingKeys: String, CodingKey {
            case phase
            case message
            case occurredAt = "occurred_at"
        }

        init(phase: Phase, message: String, occurredAt: Int64) {
            self.phase = phase
            self.message = message
            self.occurredAt = occurredAt
        }
    }

    /// Authenticated user this checkpoint belongs to. The store keys files
    /// by it and refuses to hand a checkpoint to a different account.
    let userID: String
    var role: Role
    var phase: Phase
    /// Server transfer id — shared-owner and successor flows only.
    var transferID: String?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var destinationZoneName: String?
    var destinationZoneOwnerName: String?
    /// Random nonce presented (as a SHA-256 hash) with `DELETE /api/me`,
    /// minted and persisted BEFORE that call.
    ///
    /// Deleting the account cascades the session that authorised it, so if
    /// the response is lost there is no credential left to ask "did that
    /// actually happen?". This nonce is the answer: the server writes a
    /// receipt row inside the deletion transaction, and
    /// `POST /api/account-deletion/receipts/lookup` will confirm it
    /// unauthenticated. Without it a lost response is indistinguishable
    /// from a rejected one, and the app would either strand a signed-in
    /// user on a deleted account or — far worse — treat an ordinary 401 as
    /// proof of deletion.
    ///
    /// Unlike the handoff token, this one IS persisted here. It is not a
    /// capability: it grants no access to any account or garden, only the
    /// ability to learn whether the deletion keyed to this random value
    /// committed. The handoff token, by contrast, lets a stranger become
    /// the successor of a live garden, which is why it never touches disk.
    var deletionReceipt: String?
    var lastFailure: Failure?
    /// Epoch milliseconds, set by the caller that advanced the phase. The
    /// store uses it to reject a stale write that lost a race.
    var updatedAt: Int64

    /// Which side of the transfer this device is, if any.
    var transferParty: TransferParty? {
        switch role {
        case .sharedOwner: return .owner
        case .successor: return .successor
        case .noCloudKitGarden, .participant, .soloOwner: return nil
        }
    }

    /// True when this checkpoint describes deleting *this* user's account.
    /// A successor is finishing someone else's handoff and must never be
    /// routed into an account-deletion flow.
    var deletesOwnAccount: Bool { role != .successor }

    /// The `cloudkit_disposition` this flow may claim on `DELETE /api/me`.
    ///
    /// Available at exactly one phase — `.deletingAccount` — because the
    /// disposition is an assertion that the CloudKit work is DONE, and
    /// `.deletingAccount` is by definition the state reached only after
    /// it is. At every earlier phase the claim would be a lie the server
    /// cannot check: it cannot see whether a share was left or a zone
    /// deleted, so a client that asks early gets its account erased with
    /// the garden still live.
    ///
    /// `nil` also for a successor at any phase: they are finishing
    /// someone else's handoff, not deleting an account. And `nil` for a
    /// shared owner with no transfer id — losing it must fail closed
    /// rather than fall back to a simpler disposition the server would
    /// accept.
    var disposition: AccountDeletionDisposition? {
        guard phase == .deletingAccount else { return nil }
        switch role {
        case .noCloudKitGarden: return .noCloudKitGarden
        case .participant: return .participantLeftShare
        case .soloOwner: return .ownerZoneDeleted
        case .sharedOwner:
            guard let transferID else { return nil }
            return .transferSourceDeleted(transferID: transferID)
        case .successor: return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
        case phase
        case transferID = "transfer_id"
        case sourceZoneName = "source_zone_name"
        case sourceZoneOwnerName = "source_zone_owner_name"
        case destinationZoneName = "destination_zone_name"
        case destinationZoneOwnerName = "destination_zone_owner_name"
        case deletionReceipt = "deletion_receipt"
        case lastFailure = "last_failure"
        case updatedAt = "updated_at"
    }

    init(
        userID: String,
        role: Role,
        phase: Phase,
        transferID: String? = nil,
        sourceZoneName: String? = nil,
        sourceZoneOwnerName: String? = nil,
        destinationZoneName: String? = nil,
        destinationZoneOwnerName: String? = nil,
        deletionReceipt: String? = nil,
        lastFailure: Failure? = nil,
        updatedAt: Int64
    ) {
        self.userID = userID
        self.role = role
        self.phase = phase
        self.transferID = transferID
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.destinationZoneName = destinationZoneName
        self.destinationZoneOwnerName = destinationZoneOwnerName
        self.deletionReceipt = deletionReceipt
        self.lastFailure = lastFailure
        self.updatedAt = updatedAt
    }
}
