import Testing
import Foundation
@testable import SeedkeepKit

/// `humanizeError` copy for every branch: the transport (`URLError`) cases, each known
/// `SeedkeepError` code, and the generic fallback. Raw codes and messages never reach the copy.
@Suite("humanizeError copy")
struct HumanizeErrorTests {
    private static let fallback = "Something went wrong. Try again, or contact support if it sticks."

    @Test("offline and lost connections read as offline", arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost])
    func offline(_ code: URLError.Code) {
        #expect(humanizeError(URLError(code)) == "You're offline. Sync paused until the connection returns.")
    }

    @Test("a timeout says the server didn't respond in time")
    func timedOut() {
        #expect(humanizeError(URLError(.timedOut)) == "The server didn't respond in time. Try again.")
    }

    @Test("a cancelled request says so")
    func cancelled() {
        #expect(humanizeError(URLError(.cancelled)) == "Request cancelled.")
    }

    @Test("any other transport failure suggests retrying", arguments: [URLError.Code.cannotConnectToHost, .cannotFindHost, .badServerResponse])
    func otherTransport(_ code: URLError.Code) {
        #expect(humanizeError(URLError(code)) == "Couldn't reach the server. Tap retry, or check your connection.")
    }

    @Test("known SeedkeepError codes get their own copy")
    func knownCodes() {
        let expected = [
            "no_household": "Sign in to a household before continuing.",
            "no_household_location": "Add your home ZIP in Settings to get planting recommendations.",
            "not_found": "We couldn't find that. It may have been removed.",
            "no_seeds": "No seeds in your library yet. Add one to get started.",
            "wrong_tier": "That action isn't available on your current plan.",
            "unauthorized": "Your session expired. Sign in again to continue.",
        ]
        for (code, copy) in expected {
            #expect(humanizeError(SeedkeepError(code: code, message: "raw \(code)")) == copy)
        }
    }

    @Test("an unknown SeedkeepError code and a foreign error fall back without leaking machine text")
    func fallback() {
        let unknown = humanizeError(SeedkeepError(code: "inactive_garden_entry", message: "raw machine text"))
        #expect(unknown == Self.fallback)
        #expect(!unknown.contains("raw machine text"))
        struct Foreign: Error {}
        #expect(humanizeError(Foreign()) == Self.fallback)
        #expect(humanizeError(NSError(domain: "x", code: 7)) == Self.fallback)
    }
}
