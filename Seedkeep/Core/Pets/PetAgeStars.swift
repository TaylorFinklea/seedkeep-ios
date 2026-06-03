import Foundation
import SeedkeepKit

/// Phase 5.1.6 — single source for the pet age-star computation. Used by
/// PetCard.menagerie, PetDetailView, and AIAssistantCoordinator's
/// `client_pet_state` map.
///
/// Rule (spec line 730): 1 age-star per 14 days alive, cap at 5 stars
/// at 70 days. Wilted/departing time still counts as alive. Departed /
/// graduated pets render 0 stars (callers gate display, not computation).
enum PetAgeStars {

    /// Star count derived from a planting event's `petSpawnedAt` and the
    /// current lifecycle phase. Caller is expected to pass `phase` so the
    /// helper can decide whether stars are meaningful for that state.
    ///
    /// - For alive/wilted/departing: clock runs from `spawnedAt` to `now`.
    /// - For departed/graduated: returns 0 (display is hidden anyway).
    static func compute(
        spawnedAt: Int64?,
        phase: PetLifecyclePhase,
        terminalAt: Int64? = nil,
        now: Date = Date()
    ) -> Int {
        guard let spawned = spawnedAt else { return 0 }
        switch phase {
        case .alive, .wilted, .departing:
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            let days = (nowMs - spawned) / (1000 * 60 * 60 * 24)
            return min(5, max(0, Int(days / 14)))
        case .departed, .graduated:
            return 0
        }
    }
}
