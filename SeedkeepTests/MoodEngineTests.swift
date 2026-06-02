import Testing
import Foundation
@testable import Seedkeep
import SeedkeepKit

// MARK: - Helpers

private func inputs(
    journal: Int? = nil,
    watered: Int? = nil,
    photo: Int? = nil,
    age: Int = 0,
    window: Int? = nil,
    siblings: Int? = nil
) -> PetMoodInputs {
    PetMoodInputs(
        daysSinceJournal: journal,
        daysSinceWatered: watered,
        daysSincePhoto: photo,
        ageDays: age,
        harvestWindowMaxDays: window,
        daysSinceSiblingActivity: siblings
    )
}

/// Helper for monotonicity assertions. Given a builder that varies one
/// signal's days-since input, verify the composite is monotonically
/// non-increasing as days grow (higher days = worse signal score).
private func assertNonIncreasing(
    builder: (Int) -> PetMoodInputs,
    signal: String
) {
    var prev = Int.max
    for d in stride(from: 0, through: 60, by: 1) {
        let r = MoodEngine.compute(builder(d))
        #expect(
            r.composite <= prev || prev == Int.max,
            "\(signal): composite rose from \(prev) to \(r.composite) at d=\(d)"
        )
        prev = r.composite
    }
}

// MARK: - Suite

/// Pure-function tests for `MoodEngine`. No SwiftData, no `@MainActor`,
/// no Date — every test calls `MoodEngine.compute(_:)` directly with a
/// `PetMoodInputs` value.
@Suite("MoodEngine — Phase 5 pure mood derivation")
struct MoodEngineTests {

    // MARK: - Determinism + bounds

    @Test("compute is deterministic — identical input → identical output")
    func determinism() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let i = PetMoodInputs(
                daysSinceJournal: Int.random(in: 0...60, using: &rng),
                daysSinceWatered: Int.random(in: 0...30, using: &rng),
                daysSincePhoto: Int.random(in: 0...90, using: &rng),
                ageDays: Int.random(in: 0...365, using: &rng),
                harvestWindowMaxDays: Int.random(in: 1...180, using: &rng),
                daysSinceSiblingActivity: Int.random(in: 0...120, using: &rng)
            )
            let a = MoodEngine.compute(i)
            let b = MoodEngine.compute(i)
            #expect(a == b)
        }
    }

    @Test("composite stays in [0, 100] across 1000 random inputs")
    func bounded() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1000 {
            let i = PetMoodInputs(
                daysSinceJournal: Bool.random() ? nil : Int.random(in: 0...500, using: &rng),
                daysSinceWatered: Bool.random() ? nil : Int.random(in: 0...200, using: &rng),
                daysSincePhoto: Bool.random() ? nil : Int.random(in: 0...600, using: &rng),
                ageDays: Int.random(in: 0...1000, using: &rng),
                harvestWindowMaxDays: Bool.random() ? nil : Int.random(in: 1...365, using: &rng),
                daysSinceSiblingActivity: Bool.random() ? nil : Int.random(in: 0...365, using: &rng)
            )
            let result = MoodEngine.compute(i)
            #expect(result.composite >= 0)
            #expect(result.composite <= 100)
        }
    }

    @Test("all-nil signals + age=0 + no harvest window → composite 60 (neutral)")
    func nilNeutrality() {
        let r = MoodEngine.compute(inputs())
        #expect(r.composite == 60)
    }

    // MARK: - Monotonicity per signal

    @Test("loneliness: more days since journal → composite never rises")
    func lonelinessMonotonic() {
        assertNonIncreasing(builder: { inputs(journal: $0) }, signal: "loneliness")
    }

    @Test("thirst: more days since watered → composite never rises")
    func thirstMonotonic() {
        assertNonIncreasing(builder: { inputs(watered: $0) }, signal: "thirst")
    }

    @Test("attention: more days since photo → composite never rises")
    func attentionMonotonic() {
        assertNonIncreasing(builder: { inputs(photo: $0) }, signal: "attention")
    }

    @Test("companionship: more days since sibling activity → composite never rises")
    func companionshipMonotonic() {
        assertNonIncreasing(builder: { inputs(siblings: $0) }, signal: "companionship")
    }

    @Test("impatience: rising age/window ratio → composite never rises")
    func impatienceMonotonic() {
        let window = 30
        var prev = Int.max
        for age in stride(from: 0, through: 60, by: 1) {
            let r = MoodEngine.compute(inputs(age: age, window: window))
            #expect(r.composite <= prev || prev == Int.max)
            prev = r.composite
        }
    }

    // MARK: - Per-signal anchor exactness

    @Test("loneliness anchor: daysSinceJournal=14 → loneliness signal score 30")
    func lonelinessAt14() {
        let r = MoodEngine.compute(inputs(journal: 14))
        #expect(r.signals.loneliness == 30)
    }

    @Test("loneliness anchor: daysSinceJournal=0 → loneliness signal score 100")
    func lonelinessAt0() {
        let r = MoodEngine.compute(inputs(journal: 0))
        #expect(r.signals.loneliness == 100)
    }

    @Test("loneliness anchor: daysSinceJournal=7 → loneliness signal score 70")
    func lonelinessAt7() {
        let r = MoodEngine.compute(inputs(journal: 7))
        #expect(r.signals.loneliness == 70)
    }

    @Test("loneliness anchor: daysSinceJournal=28+ → loneliness signal score 0")
    func lonelinessAt28() {
        #expect(MoodEngine.compute(inputs(journal: 28)).signals.loneliness == 0)
        #expect(MoodEngine.compute(inputs(journal: 60)).signals.loneliness == 0)
    }

    @Test("thirst anchors: 0/2/5/10 → 100/80/30/0")
    func thirstAnchors() {
        #expect(MoodEngine.compute(inputs(watered: 0)).signals.thirst == 100)
        #expect(MoodEngine.compute(inputs(watered: 2)).signals.thirst == 80)
        #expect(MoodEngine.compute(inputs(watered: 5)).signals.thirst == 30)
        #expect(MoodEngine.compute(inputs(watered: 10)).signals.thirst == 0)
        #expect(MoodEngine.compute(inputs(watered: 100)).signals.thirst == 0)
    }

    @Test("attention anchors: 0/10/21/45 → 100/70/40/0")
    func attentionAnchors() {
        #expect(MoodEngine.compute(inputs(photo: 0)).signals.attention == 100)
        #expect(MoodEngine.compute(inputs(photo: 10)).signals.attention == 70)
        #expect(MoodEngine.compute(inputs(photo: 21)).signals.attention == 40)
        #expect(MoodEngine.compute(inputs(photo: 45)).signals.attention == 0)
    }

    @Test("companionship anchors: 0/7/21/60 → 100/80/50/30 (never reaches 0)")
    func companionshipAnchors() {
        #expect(MoodEngine.compute(inputs(siblings: 0)).signals.companionship == 100)
        #expect(MoodEngine.compute(inputs(siblings: 7)).signals.companionship == 80)
        #expect(MoodEngine.compute(inputs(siblings: 21)).signals.companionship == 50)
        #expect(MoodEngine.compute(inputs(siblings: 60)).signals.companionship == 30)
        // Saturates at 30 — never falls below.
        #expect(MoodEngine.compute(inputs(siblings: 365)).signals.companionship == 30)
    }

    @Test("impatience: nil harvest window → neutral 60")
    func impatienceNilWindow() {
        let r = MoodEngine.compute(inputs(age: 30, window: nil))
        #expect(r.signals.impatience == 60)
    }

    @Test("impatience anchors at ratio 0.0 / 0.8 / 1.0 / 1.5")
    func impatienceAnchorScores() {
        // ratio 0 → 100
        #expect(MoodEngine.compute(inputs(age: 0, window: 100)).signals.impatience == 100)
        // ratio 0.8 → 80
        #expect(MoodEngine.compute(inputs(age: 80, window: 100)).signals.impatience == 80)
        // ratio 1.0 → 50
        #expect(MoodEngine.compute(inputs(age: 100, window: 100)).signals.impatience == 50)
        // ratio 1.5 → 0
        #expect(MoodEngine.compute(inputs(age: 150, window: 100)).signals.impatience == 0)
        // saturate above 1.5
        #expect(MoodEngine.compute(inputs(age: 1000, window: 100)).signals.impatience == 0)
    }

    // MARK: - Label bucket boundaries

    @Test("label boundaries — composite 30 → wilted, 29 → departingImminent")
    func labelBoundariesWilted() {
        #expect(MoodEngine.label(for: 30) == .wilted)
        #expect(MoodEngine.label(for: 29) == .departingImminent)
    }

    @Test("label boundaries across all five buckets (29/30/49/50/74/75/89/90)")
    func labelBoundariesFull() {
        #expect(MoodEngine.label(for: 0) == .departingImminent)
        #expect(MoodEngine.label(for: 29) == .departingImminent)
        #expect(MoodEngine.label(for: 30) == .wilted)
        #expect(MoodEngine.label(for: 49) == .wilted)
        #expect(MoodEngine.label(for: 50) == .quiet)
        #expect(MoodEngine.label(for: 74) == .quiet)
        #expect(MoodEngine.label(for: 75) == .content)
        #expect(MoodEngine.label(for: 89) == .content)
        #expect(MoodEngine.label(for: 90) == .thriving)
        #expect(MoodEngine.label(for: 100) == .thriving)
    }
}
