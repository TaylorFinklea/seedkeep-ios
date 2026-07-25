import Foundation
import SeedkeepKit

/// The rules the successor's app-scope cutover has to satisfy before this
/// device may call a transferred garden its own.
///
/// The interesting part is which household to adopt, and the answer is NOT
/// "whatever the ambient session says". A user who belongs to more than one
/// household — which this device now genuinely does, the moment a transfer
/// re-homes ownership to it — cannot be resolved by asking "what is my
/// current household" (`POST /api/households`'s most-recently-joined
/// heuristic, however carefully ordered, is still a heuristic). The
/// transfer itself already names the household, so the cutover asks the
/// server the EXACT question — `GET /api/households/:id` — and the server
/// answers with proof of membership or a refusal, never a guess.
///
/// `classify` turns that refusal into copy. A `not_a_member` (403) means
/// the re-home has not landed on the server yet — legitimately retryable,
/// not a failure to report as broken. Anything else propagates unchanged.
enum TransferredGardenCutover {

    enum Failure: Error, Equatable, LocalizedError {
        /// The server has not re-homed this household to this user yet —
        /// or already reverted it (a still-legal owner cancel after
        /// `verified` demotes/removes the successor's re-homed
        /// membership, per `account-deletion-transfers.ts`'s cancel
        /// route).
        case notYetTransferred
        /// The transfer that authorized this handoff was withdrawn. The
        /// membership re-home it made is gone too — there is nothing left
        /// to adopt, ever, for this transfer.
        case transferWithdrawn
        /// Nobody is signed in to adopt the household as.
        case sessionUnavailable
        /// The destination-owner scope did not sync, so this device cannot
        /// yet show the garden it just adopted.
        case destinationSyncIncomplete(message: String?)

        var errorDescription: String? {
            switch self {
            case .notYetTransferred:
                return """
                The garden hasn't finished moving to your account yet. \
                Nothing was changed — try again in a moment.
                """
            case .transferWithdrawn:
                return "This handoff was withdrawn before it finished. The garden was not transferred."
            case .sessionUnavailable:
                return "Sign in again to finish taking over the garden."
            case .destinationSyncIncomplete(let message):
                return message ?? "Your new garden could not be loaded yet. Try again."
            }
        }
    }

    /// Whether the EXACT household lookup's role proves the re-home
    /// landed as ownership, not mere membership.
    ///
    /// The successor's whole claim to this garden is that verification
    /// UPSERTs them as `role = 'owner'` of the re-homed household
    /// (`account-deletion-transfers.ts`, "atomic re-home"). A membership
    /// row that exists but is not `owner` proves nothing has actually
    /// completed — reporting success over it would let a device call a
    /// garden its own that the server does not agree it owns.
    static func verifyOwnership(role: String) throws {
        guard role == "owner" else { throw Failure.notYetTransferred }
    }

    /// Turns a `client.household(id:)` failure into a `Failure` this type
    /// knows how to talk about, or `nil` when the error is something else
    /// (a transport failure, say) that should propagate as-is rather than
    /// be reinterpreted.
    static func classify(_ error: Error) -> Failure? {
        guard let seedkeepError = error as? SeedkeepError else { return nil }
        switch seedkeepError.code {
        case "not_a_member": return .notYetTransferred
        case "unauthorized": return .sessionUnavailable
        default: return nil
        }
    }

    /// Whether the transfer itself still authorizes calling this garden
    /// adopted — re-read at the LAST possible moment, because the owner
    /// may still legally cancel a `verified` transfer right up until the
    /// source-deletion lease is taken (`Phase.sourceIsGone` starts at
    /// `.sourceZoneDeleting`, not `.verified`), and a cancel past
    /// `verified` reverts the very membership the household lookup just
    /// confirmed.
    static func verifyTransferAuthorizes(_ phase: AccountDeletionTransferPhase) throws {
        switch phase {
        case .verified, .sourceDeleting, .sourceDeleted:
            return
        case .cancelled:
            throw Failure.transferWithdrawn
        case .pendingSuccessor, .successorBound, .destinationReady, .ownerVerified:
            // Reachable only via a stale local view (the reload below is
            // what closes that window); not proof of anything gone wrong.
            throw Failure.notYetTransferred
        }
    }
}
