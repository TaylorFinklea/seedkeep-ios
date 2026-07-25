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
        /// The server has not re-homed this household to this user yet.
        case notYetTransferred
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
            case .sessionUnavailable:
                return "Sign in again to finish taking over the garden."
            case .destinationSyncIncomplete(let message):
                return message ?? "Your new garden could not be loaded yet. Try again."
            }
        }
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
}
