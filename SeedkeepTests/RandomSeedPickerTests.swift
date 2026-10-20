import Testing
@testable import Seedkeep

@Suite("RandomSeedPicker")
struct RandomSeedPickerTests {
    private func seed(
        _ id: String,
        householdID: String = "garden-a",
        stateRaw: String = "active",
        yearPacked: Int? = nil,
        isDeleted: Bool = false
    ) -> RandomSeedCandidate {
        RandomSeedCandidate(
            id: id,
            householdID: householdID,
            stateRaw: stateRaw,
            yearPacked: yearPacked,
            isDeleted: isDeleted
        )
    }

    @Test("weights unknown years as two and known years by age with a minimum of one")
    func weights() {
        #expect(RandomSeedPicker.weight(for: seed("unknown"), currentYear: 2026) == 2)
        #expect(RandomSeedPicker.weight(for: seed("fresh", yearPacked: 2026), currentYear: 2026) == 1)
        #expect(RandomSeedPicker.weight(for: seed("old", yearPacked: 2022), currentYear: 2026) == 4)
        #expect(RandomSeedPicker.weight(for: seed("future", yearPacked: 2028), currentYear: 2026) == 1)
    }

    @Test("an empty active garden has no candidates and no pick")
    func emptyGarden() {
        let candidates = RandomSeedPicker.candidates(from: [], householdID: "garden-a")
        #expect(candidates.isEmpty)
        #expect(RandomSeedPicker.pick(from: candidates, currentYear: 2026, rng: { 0 }) == nil)
        #expect(RandomSeedPicker.candidates(from: [seed("s1")], householdID: nil).isEmpty)
    }

    @Test("only active non-deleted seeds in the active garden are candidates")
    func activeGardenScope() {
        let candidates = RandomSeedPicker.candidates(from: [
            seed("included"),
            seed("other-garden", householdID: "garden-b"),
            seed("wishlist", stateRaw: "wishlist"),
            seed("deleted", isDeleted: true)
        ], householdID: "garden-a")

        #expect(candidates.map(\.id) == ["included"])
    }

    @Test("cumulative boundaries use the server's subtract-until-zero walk")
    func walkBoundaries() {
        let seeds = [
            seed("fresh", yearPacked: 2026),
            seed("mid", yearPacked: 2024),
            seed("old", yearPacked: 2022)
        ]

        #expect(RandomSeedPicker.pick(from: seeds, currentYear: 2026, rng: { 0 })?.id == "fresh")
        #expect(RandomSeedPicker.pick(from: seeds, currentYear: 2026, rng: { 1.0 / 7.0 })?.id == "fresh")
        #expect(RandomSeedPicker.pick(from: seeds, currentYear: 2026, rng: { 1.01 / 7.0 })?.id == "mid")
        #expect(RandomSeedPicker.pick(from: seeds, currentYear: 2026, rng: { 3.0 / 7.0 })?.id == "mid")
        #expect(RandomSeedPicker.pick(from: seeds, currentYear: 2026, rng: { 3.01 / 7.0 })?.id == "old")
    }

    @Test("the final seed is returned if floating-point arithmetic misses the walk")
    func floatingPointFallback() {
        let seeds = [seed("first", yearPacked: 2026), seed("last", yearPacked: 2022)]
        #expect(RandomSeedPicker.pick(from: seeds, currentYear: 2026, rng: { 1.0.nextUp })?.id == "last")
    }

    @Test("returning from the seed's detail keeps the pick: a picked seed that is still a candidate is not re-rolled")
    func returningKeepsPick() {
        #expect(!RandomSeedPicker.needsPick(pickedID: "b", candidateIDs: ["a", "b", "c"]))
    }

    @Test("a pick is made when nothing is picked yet")
    func picksWhenEmpty() {
        #expect(RandomSeedPicker.needsPick(pickedID: nil, candidateIDs: ["a"]))
    }

    @Test("a picked seed that disappeared is replaced once, and an empty garden never asks to pick")
    func disappearedPickWithoutLoop() {
        #expect(RandomSeedPicker.needsPick(pickedID: "gone", candidateIDs: ["a"]))
        #expect(!RandomSeedPicker.needsPick(pickedID: "gone", candidateIDs: []))
        #expect(!RandomSeedPicker.needsPick(pickedID: nil, candidateIDs: []))
    }
}
