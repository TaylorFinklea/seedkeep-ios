import Foundation
import SeedkeepKit

// N2-E (G2) §6: the write fence. `AppEnvironment.writableGarden` is the active garden plus the
// `gardenScopeEpoch`; it is nil while the bound garden is gone, awaiting a choice, or under a
// running journal. A writer captures it when it starts and re-checks both the garden and the epoch
// at its final mutation boundary. A nil or changed value means the writer does nothing.

@MainActor
struct GardenWriteFence {
    /// The current writable garden, nil when nothing may be written.
    let current: () -> WritableGarden?

    static let refusedCode = "garden_not_writable"
    static let refusedMessage = "This garden is no longer in iCloud, so nothing can be added to it right now."

    static var refusal: SeedkeepError {
        SeedkeepError(code: refusedCode, message: refusedMessage)
    }

    /// Captures the writable garden at the start of a write. Throws when there is none.
    func begin() throws -> WritableGarden {
        guard let captured = current() else { throw Self.refusal }
        return captured
    }

    /// True while `captured` is still the current writable garden in the same scope epoch.
    func isStillValid(_ captured: WritableGarden) -> Bool {
        current() == captured
    }

    /// The re-check at a writer's final mutation boundary.
    func confirm(_ captured: WritableGarden) throws {
        guard isStillValid(captured) else { throw Self.refusal }
    }
}
