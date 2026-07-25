import Foundation

/// The rules the successor's app-scope cutover has to satisfy before this
/// device may call a transferred garden its own.
///
/// The interesting part is which household to adopt, and the answer is NOT
/// "whatever the refreshed session says". `/api/me` answers with a
/// membership; a user who belongs to more than one household can be handed
/// a different one, and a session restored from cache can still be
/// describing the world from before the server re-homed ownership. Either
/// would silently point the app at a garden the transfer never mentioned —
/// and the cutover's whole job is to stop pointing at the wrong garden.
///
/// So the transfer's household id is the authority, and the refreshed
/// session is checked against it. A disagreement is a refusal, never a
/// choice: the checkpoint stays at `.successorAdopting` and the cutover is
/// retried when the re-home has actually landed.
enum TransferredGardenCutover {

    enum Failure: Error, Equatable, LocalizedError {
        /// Nobody is signed in after the refresh, so there is no household
        /// to compare against.
        case sessionUnavailable
        /// The refreshed session does not name the transferred household.
        case householdNotTransferred(expected: String, found: String)
        /// The destination-owner scope did not sync, so this device cannot
        /// yet show the garden it just adopted.
        case destinationSyncIncomplete(message: String?)

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable:
                return "Sign in again to finish taking over the garden."
            case .householdNotTransferred:
                return """
                The garden hasn't finished moving to your account yet. \
                Nothing was changed — try again in a moment.
                """
            case .destinationSyncIncomplete(let message):
                return message ?? "Your new garden could not be loaded yet. Try again."
            }
        }
    }

    /// Throws unless the signed-in household IS the transferred one.
    static func verifyHousehold(transferHouseholdID: String, signedInHouseholdID: String?) throws {
        guard let signedInHouseholdID else { throw Failure.sessionUnavailable }
        guard signedInHouseholdID == transferHouseholdID else {
            throw Failure.householdNotTransferred(expected: transferHouseholdID,
                                                  found: signedInHouseholdID)
        }
    }
}
