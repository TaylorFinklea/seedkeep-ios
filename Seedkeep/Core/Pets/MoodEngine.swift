import Foundation
import SeedkeepKit

/// Pure inputs to `MoodEngine.compute`. All counts are calendar-day
/// integers; `nil` means "no signal available — contribute neutrally"
/// (per-signal score = 60). `ageDays` is mandatory because every
/// spawned pet has a known `pet_spawned_at`.
public struct PetMoodInputs: Sendable, Equatable {
    public var daysSinceJournal: Int?
    public var daysSinceWatered: Int?
    public var daysSincePhoto: Int?
    public var ageDays: Int
    public var harvestWindowMaxDays: Int?
    public var daysSinceSiblingActivity: Int?

    public init(
        daysSinceJournal: Int? = nil,
        daysSinceWatered: Int? = nil,
        daysSincePhoto: Int? = nil,
        ageDays: Int = 0,
        harvestWindowMaxDays: Int? = nil,
        daysSinceSiblingActivity: Int? = nil
    ) {
        self.daysSinceJournal = daysSinceJournal
        self.daysSinceWatered = daysSinceWatered
        self.daysSincePhoto = daysSincePhoto
        self.ageDays = ageDays
        self.harvestWindowMaxDays = harvestWindowMaxDays
        self.daysSinceSiblingActivity = daysSinceSiblingActivity
    }
}

/// Per-signal scores (0..100) computed by `MoodEngine.compute`. Surfaced
/// alongside the composite so `PetDetailView` can render the "why this
/// mood" breakdown without recomputing.
public struct PetMoodSignals: Sendable, Equatable {
    /// Score from `daysSinceJournal`.
    public var loneliness: Int
    /// Score from `daysSinceWatered`.
    public var thirst: Int
    /// Score from `daysSincePhoto`.
    public var attention: Int
    /// Score from `ageDays / harvestWindowMaxDays`.
    public var impatience: Int
    /// Score from `daysSinceSiblingActivity`.
    public var companionship: Int

    public init(
        loneliness: Int,
        thirst: Int,
        attention: Int,
        impatience: Int,
        companionship: Int
    ) {
        self.loneliness = loneliness
        self.thirst = thirst
        self.attention = attention
        self.impatience = impatience
        self.companionship = companionship
    }
}

/// Output of `MoodEngine.compute`. `composite` is the weighted, clamped
/// 0..100 score; `label` is the bucketed `PetMoodLabel` per the spec's
/// inclusive-of-lower-bound thresholds (composite=30 → `wilted`,
/// composite=29 → `departingImminent`); `signals` is the per-signal
/// breakdown so views can render attribution.
public struct PetMoodResult: Sendable, Equatable {
    public var composite: Int
    public var label: PetMoodLabel
    public var signals: PetMoodSignals
}

/// Pure mood derivation per the Phase 5 spec. No SwiftData, no
/// `Date()` reads, no `@MainActor`. `PetMoodResolver` collects the
/// inputs from SwiftData; this engine just scores them.
///
/// Anchors and weights are spec-locked — see "Mood Engine" in
/// `.docs/ai/specs/2026-06-02-phase-5-plant-pets-design.md` (line 519).
public enum MoodEngine {
    // MARK: - Per-signal anchors (spec, line 564-590)

    /// `(days, score)` anchors for loneliness — higher days, lower score.
    /// `[ (0, 100), (7, 70), (14, 30), (28, 0) ]`.
    private static let lonelinessAnchors: [(Double, Double)] = [
        (0, 100), (7, 70), (14, 30), (28, 0),
    ]

    /// Thirst anchors. `[ (0, 100), (2, 80), (5, 30), (10, 0) ]`.
    private static let thirstAnchors: [(Double, Double)] = [
        (0, 100), (2, 80), (5, 30), (10, 0),
    ]

    /// Attention anchors. `[ (0, 100), (10, 70), (21, 40), (45, 0) ]`.
    private static let attentionAnchors: [(Double, Double)] = [
        (0, 100), (10, 70), (21, 40), (45, 0),
    ]

    /// Impatience anchors keyed on `ratio = ageDays / harvestWindowMaxDays`.
    /// `[ (0.0, 100), (0.8, 80), (1.0, 50), (1.5, 0) ]`. Never reaches 0
    /// below ratio=1.5; saturates after.
    private static let impatienceAnchors: [(Double, Double)] = [
        (0.0, 100), (0.8, 80), (1.0, 50), (1.5, 0),
    ]

    /// Companionship anchors. Never reaches 0; saturates at 30.
    /// `[ (0, 100), (7, 80), (21, 50), (60, 30) ]`.
    private static let companionshipAnchors: [(Double, Double)] = [
        (0, 100), (7, 80), (21, 50), (60, 30),
    ]

    // MARK: - Weights (spec, line 597-605, sum = 1.00)

    private static let weightThirst        = 0.30
    private static let weightLoneliness    = 0.25
    private static let weightImpatience    = 0.20
    private static let weightAttention     = 0.15
    private static let weightCompanionship = 0.10

    /// Score per signal when the input is `nil` ("no data — contribute
    /// neutrally"). Spec: 60.
    private static let neutralScore: Int = 60

    // MARK: - Public entry point

    /// Score the inputs and bucket into a `PetMoodLabel`. Pure — same
    /// inputs always produce the same output.
    public static func compute(_ inputs: PetMoodInputs) -> PetMoodResult {
        let loneliness = score(days: inputs.daysSinceJournal, anchors: lonelinessAnchors)
        let thirst = score(days: inputs.daysSinceWatered, anchors: thirstAnchors)
        let attention = score(days: inputs.daysSincePhoto, anchors: attentionAnchors)
        let impatience = impatienceScore(
            ageDays: inputs.ageDays,
            harvestWindowMaxDays: inputs.harvestWindowMaxDays
        )
        let companionship = score(
            days: inputs.daysSinceSiblingActivity,
            anchors: companionshipAnchors
        )

        let signals = PetMoodSignals(
            loneliness: loneliness,
            thirst: thirst,
            attention: attention,
            impatience: impatience,
            companionship: companionship
        )

        let weighted =
            weightThirst        * Double(thirst)
            + weightLoneliness    * Double(loneliness)
            + weightImpatience    * Double(impatience)
            + weightAttention     * Double(attention)
            + weightCompanionship * Double(companionship)

        let composite = clampScore(Int(weighted.rounded()))
        return PetMoodResult(composite: composite, label: label(for: composite), signals: signals)
    }

    /// Bucket a composite into a `PetMoodLabel`. Lower bound inclusive
    /// per spec: composite=30 → `wilted`, composite=29 →
    /// `departingImminent`.
    public static func label(for composite: Int) -> PetMoodLabel {
        switch composite {
        case 90...:        return .thriving
        case 75...89:      return .content
        case 50...74:      return .quiet
        case 30...49:      return .wilted
        default:           return .departingImminent
        }
    }

    // MARK: - Helpers

    /// Generic days→score lookup against an ascending `(days, score)`
    /// anchor table. Nil days → `neutralScore`. Days below the first
    /// anchor saturate to the first anchor's score; days above the last
    /// saturate to the last anchor's score. Between two anchors, scores
    /// linearly interpolate.
    private static func score(days: Int?, anchors: [(Double, Double)]) -> Int {
        guard let raw = days else { return neutralScore }
        let d = max(0, Double(raw))
        return clampScore(Int(interpolate(x: d, anchors: anchors).rounded()))
    }

    /// Impatience is keyed on a `ratio`, not raw days. Nil window →
    /// neutral. Spec: `ratio = ageDays / harvestWindowMaxDays`.
    private static func impatienceScore(ageDays: Int, harvestWindowMaxDays: Int?) -> Int {
        guard let window = harvestWindowMaxDays, window > 0 else { return neutralScore }
        let ratio = max(0, Double(ageDays)) / Double(window)
        return clampScore(Int(interpolate(x: ratio, anchors: impatienceAnchors).rounded()))
    }

    /// Piecewise-linear interpolation. `anchors` must be ascending by
    /// `x`. Below the first anchor returns the first `y`; above the
    /// last returns the last `y`.
    private static func interpolate(x: Double, anchors: [(Double, Double)]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return Double(neutralScore) }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<anchors.count {
            let (x1, y1) = anchors[i]
            if x <= x1 {
                let (x0, y0) = anchors[i - 1]
                let t = (x - x0) / (x1 - x0)
                return y0 + t * (y1 - y0)
            }
        }
        return last.1
    }

    /// Clamp to `[0, 100]`.
    private static func clampScore(_ s: Int) -> Int {
        max(0, min(100, s))
    }
}
