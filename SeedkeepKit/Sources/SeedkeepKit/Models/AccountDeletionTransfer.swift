import Foundation

// Wire types for the shared-owner account-deletion handoff
// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md`
// § "Coordination API"; server: `src/routes/account-deletion-transfers.ts`,
// mounted at `/api/account-deletion`).
//
// A shared garden lives in the departing owner's CloudKit zone, so deleting
// that account means moving the garden to a successor's own zone first. The
// server coordinates the two devices without ever receiving garden contents:
// it holds the parties, the zone/share identifiers, a canonical digest with
// per-type counts from each side, and the phase. These types are the client's
// half of that contract.

/// Server-side transfer phase. Raw values mirror `TRANSFER_PHASES` in
/// `account-deletion-transfers.ts` verbatim, in the same order:
///
///     pending_successor → successor_bound → destination_ready
///       → owner_verified → verified → source_deleted
///
/// Any non-terminal phase can move to `cancelled`.
///
/// Deliberately strict: a phase this build cannot name fails decoding
/// rather than degrading to a default. The coordinator uses the phase to
/// decide whether deleting the source zone is authorized, so an unknown
/// value must stop the flow, never approximate it.
public enum AccountDeletionTransferPhase: String, Codable, CaseIterable, Sendable, Hashable {
    /// Created; waiting for someone to open the handoff link.
    case pendingSuccessor = "pending_successor"
    /// A successor presented the handoff token and is now bound.
    case successorBound = "successor_bound"
    /// The successor created and posted a destination zone/share they own.
    case destinationReady = "destination_ready"
    /// The departing owner copied the graph and posted its digest.
    case ownerVerified = "owner_verified"
    /// Both digests agreed; server membership has been re-homed.
    case verified
    /// The owner reported the source zone verifiably absent. Only from
    /// here will `DELETE /api/me` complete for a shared owner.
    case sourceDeleted = "source_deleted"
    /// Abandoned before source deletion. The original garden is untouched.
    case cancelled
}

/// One party's verification document: the canonical graph hash plus the
/// per-record-type census. The server compares the owner's against the
/// successor's and refuses source deletion unless both agree.
///
/// `digest` is the lowercase-hex SHA-256 produced by
/// `SeedkeepCloudKit.HouseholdGraphDigester`; `record_counts` is that
/// digest's `counts`. This module stays CloudKit-free, so the caller
/// passes the two values rather than the CloudKit type.
public struct AccountDeletionDigestDTO: Codable, Sendable, Equatable {
    public let digest: String
    public let record_counts: [String: Int]
    /// Server clock (epoch ms) at the moment the document was accepted.
    public let submitted_at: Int64

    public init(digest: String, record_counts: [String: Int], submitted_at: Int64) {
        self.digest = digest
        self.record_counts = record_counts
        self.submitted_at = submitted_at
    }
}

/// A durable transfer row as the server serializes it. The hashed handoff
/// token is never part of this shape — only its expiry and consumption
/// timestamps.
public struct AccountDeletionTransferDTO: Codable, Sendable, Equatable {
    public let id: String
    public let source_household_id: String
    public let owner_user_id: String
    public let successor_user_id: String?
    public let phase: AccountDeletionTransferPhase
    public let handoff_expires_at: Int64
    public let handoff_consumed_at: Int64?
    public let destination_zone_name: String?
    public let destination_zone_owner_name: String?
    public let destination_share_record_name: String?
    public let destination_share_url: String?
    public let owner_digest: AccountDeletionDigestDTO?
    public let successor_digest: AccountDeletionDigestDTO?
    public let created_at: Int64
    public let updated_at: Int64
    public let cancelled_at: Int64?

    public init(
        id: String,
        source_household_id: String,
        owner_user_id: String,
        successor_user_id: String?,
        phase: AccountDeletionTransferPhase,
        handoff_expires_at: Int64,
        handoff_consumed_at: Int64?,
        destination_zone_name: String?,
        destination_zone_owner_name: String?,
        destination_share_record_name: String?,
        destination_share_url: String?,
        owner_digest: AccountDeletionDigestDTO?,
        successor_digest: AccountDeletionDigestDTO?,
        created_at: Int64,
        updated_at: Int64,
        cancelled_at: Int64?
    ) {
        self.id = id
        self.source_household_id = source_household_id
        self.owner_user_id = owner_user_id
        self.successor_user_id = successor_user_id
        self.phase = phase
        self.handoff_expires_at = handoff_expires_at
        self.handoff_consumed_at = handoff_consumed_at
        self.destination_zone_name = destination_zone_name
        self.destination_zone_owner_name = destination_zone_owner_name
        self.destination_share_record_name = destination_share_record_name
        self.destination_share_url = destination_share_url
        self.owner_digest = owner_digest
        self.successor_digest = successor_digest
        self.created_at = created_at
        self.updated_at = updated_at
        self.cancelled_at = cancelled_at
    }
}
