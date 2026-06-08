import Foundation

/// Converts an `Error` into a user-readable single sentence.
///
/// Two goals, in order:
///   1. Never leak machinery — bearer tokens, raw HTTP statuses, JSON decoding
///      internals, internal paths — to end users.
///   2. Suggest an action when the failure mode admits one.
///
/// Unknown errors fall through to a short generic fallback. `URLError`s
/// covering the common transport failures get bespoke copy. Known
/// `SeedkeepError` codes that already surface at user-visible sites
/// (`no_household`, `no_household_location`, `not_found`, `no_seeds`,
/// `wrong_tier`, `unauthorized`) get explicit copy; everything else falls
/// through to the generic fallback so we don't echo machine-shaped strings.
public func humanizeError(_ error: Error) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "You're offline. Sync paused until the connection returns."
        case .timedOut:
            return "The server didn't respond in time. Try again."
        case .cancelled:
            return "Request cancelled."
        default:
            return "Couldn't reach the server. Tap retry, or check your connection."
        }
    }

    if let sk = error as? SeedkeepError {
        switch sk.code {
        case "no_household":
            return "Sign in to a household before continuing."
        case "no_household_location":
            return "Add your home ZIP in Settings to get planting recommendations."
        case "not_found":
            return "We couldn't find that. It may have been removed."
        case "no_seeds":
            return "No seeds in your library yet. Add one to get started."
        case "wrong_tier":
            return "That action isn't available on your current plan."
        case "unauthorized":
            return "Your session expired. Sign in again to continue."
        default:
            return "Something went wrong. Try again, or contact support if it sticks."
        }
    }

    return "Something went wrong. Try again, or contact support if it sticks."
}
