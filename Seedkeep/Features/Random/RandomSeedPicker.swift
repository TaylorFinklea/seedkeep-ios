import Foundation

struct RandomSeedCandidate: Equatable, Sendable {
    let id: String
    let householdID: String
    let stateRaw: String
    let yearPacked: Int?
    let isDeleted: Bool
}

enum RandomSeedPicker {
    static func candidates(
        from seeds: [RandomSeedCandidate],
        householdID: String?
    ) -> [RandomSeedCandidate] {
        guard let householdID else { return [] }
        return seeds.filter {
            !$0.isDeleted && $0.stateRaw == "active" && $0.householdID == householdID
        }
    }

    static func weight(for seed: RandomSeedCandidate, currentYear: Int) -> Int {
        guard let yearPacked = seed.yearPacked else { return 2 }
        return max(1, currentYear - yearPacked)
    }

    static func pick(
        from seeds: [RandomSeedCandidate],
        currentYear: Int,
        rng: () -> Double
    ) -> RandomSeedCandidate? {
        guard !seeds.isEmpty else { return nil }

        let weights = seeds.map { weight(for: $0, currentYear: currentYear) }
        let total = weights.reduce(0, +)
        var target = rng() * Double(total)

        for (index, seed) in seeds.enumerated() {
            target -= Double(weights[index])
            if target <= 0 { return seed }
        }

        return seeds.last
    }

    /// Whether the view should pick: nothing is picked yet, or the picked seed is no longer a
    /// candidate (deleted, archived, moved). Returning from the seed's detail keeps the pick. With
    /// no candidates it never asks to pick, so an empty garden cannot loop.
    static func needsPick(pickedID: String?, candidateIDs: [String]) -> Bool {
        guard !candidateIDs.isEmpty else { return false }
        guard let pickedID else { return true }
        return !candidateIDs.contains(pickedID)
    }
}
