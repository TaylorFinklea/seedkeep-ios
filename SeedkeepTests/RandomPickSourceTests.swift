import Testing
@testable import Seedkeep

@Suite("Random pick source")
struct RandomPickSourceTests {

    private func seed(_ id: String, yearPacked: Int? = nil) -> RandomSeedCandidate {
        RandomSeedCandidate(
            id: id,
            householdID: "garden-a",
            stateRaw: "active",
            yearPacked: yearPacked,
            isDeleted: false
        )
    }

    @Test("sample-garden mode draws a fixed zero on every call")
    func sampleGardenDrawsZero() {
        let source = RandomPickSource.make(isSampleGarden: true)
        #expect((0..<5).map { _ in source() } == [0, 0, 0, 0, 0])
    }

    @Test("sample-garden mode picks the same seed in every run")
    func sampleGardenPickIsRepeatable() {
        let candidates = [seed("alpha", yearPacked: 2019), seed("beta", yearPacked: 2024), seed("gamma")]
        let picks = (0..<3).map { _ in
            RandomSeedPicker.pick(
                from: candidates,
                currentYear: 2026,
                rng: RandomPickSource.make(isSampleGarden: true)
            )?.id
        }
        #expect(picks == ["alpha", "alpha", "alpha"])
    }

    @Test("other builds draw from the half-open interval [0, 1)")
    func liveDrawsStayInRange() {
        let source = RandomPickSource.make(isSampleGarden: false)
        for _ in 0..<200 {
            let value = source()
            #expect(value >= 0 && value < 1)
        }
    }
}
