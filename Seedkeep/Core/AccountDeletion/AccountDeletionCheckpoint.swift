import Foundation
import SeedkeepKit

/// The durable record of an account deletion that is part-way done.
///
/// Deleting a Seedkeep account is not one operation — it is a sequence of
/// CloudKit work followed by `DELETE /api/me`, and the CloudKit half is
/// irreversible. Between "the source zone is gone" and "the server says
/// the account is deleted" the app is in a state that nothing else can
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

    /// Which CloudKit flow this deletion is running. The role is fixed
    /// when the flow starts (it is a fact about the share, not about
    /// progress) and decides which phases are reachable.
    enum Role: String, Codable, Sendable, CaseIterable {
        /// Accepted someone else's CKShare; leaves the share.
        case participant
        /// Owns an unshared household zone; deletes the zone.
        case soloOwner = "solo_owner"
        /// Owns a zone other people participate in; must hand the garden
        /// to a successor before the zone can go.
        case sharedOwner = "shared_owner"
    }

    /// The step that has been *reached*. A checkpoint is written only
    /// after the external operation that reaches it succeeded, so a
    /// resumed flow re-attempts the step AFTER this one — never the one
    /// that already landed.
    ///
    /// The shared-owner cases mirror `AccountDeletionTransferPhase` one
    /// for one so a server reload maps straight across
    /// (`init(transferPhase:)`).
    enum Phase: String, Codable, Sendable, CaseIterable {
        /// Participant: leaving the accepted share.
        case participantLeaving = "participant_leaving"
        /// Solo owner: deleting the owned household zone.
        case ownerDeletingZone = "owner_deleting_zone"
        /// Shared owner: transfer created, waiting for a successor to
        /// open the handoff link.
        case transferPending = "transfer_pending"
        /// A successor accepted; they are preparing their destination.
        case successorBound = "successor_bound"
        /// The destination zone/share exists — copy the graph into it.
        case destinationReady = "destination_ready"
        /// The owner's digest is posted; waiting on the successor's.
        case ownerVerified = "owner_verified"
        /// Both digests matched. The source zone may now be deleted.
        case verified
        /// The source zone is verifiably gone and the server knows.
        case sourceDeleted = "source_deleted"
        /// Every role's last step: `DELETE /api/me`, then sign-out.
        case deletingAccount = "deleting_account"

        /// Maps a durable server phase onto the local resume point.
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
            case .sourceDeleted: self = .sourceDeleted
            case .cancelled: return nil
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

    /// Authenticated user this deletion belongs to. The store keys files
    /// by it and refuses to hand a checkpoint to a different account.
    let userID: String
    var role: Role
    var phase: Phase
    /// Server transfer id — shared-owner flows only.
    var transferID: String?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var destinationZoneName: String?
    var destinationZoneOwnerName: String?
    var lastFailure: Failure?
    /// Epoch milliseconds, set by the caller that advanced the phase.
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
        case phase
        case transferID = "transfer_id"
        case sourceZoneName = "source_zone_name"
        case sourceZoneOwnerName = "source_zone_owner_name"
        case destinationZoneName = "destination_zone_name"
        case destinationZoneOwnerName = "destination_zone_owner_name"
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
        self.lastFailure = lastFailure
        self.updatedAt = updatedAt
    }
}
