import Foundation
import SwiftData

/// SwiftData cache for a single seed's planting recommendation fetched from
/// the server. One row per `catalogSeedID` — the `RecommendationStore` (a
/// later task) enforces the invariant via fetch-then-upsert, and
/// `@Attribute(.unique)` provides a belt-and-suspenders guard at the store
/// level (consistent with `LocalSeed.id`).
@Model
final class LocalRecommendation {
    @Attribute(.unique) var catalogSeedID: String
    var locationSignature: String
    var computedAt: Int64          // ms-epoch, server compute time
    var source: String             // "rule" | "ai"
    var confidence: Double
    var verdict: String            // server-computed at fetch time
    var rangeStart: String?        // 'YYYY-MM-DD'
    var rangeEnd: String?
    var indoorStart: String?
    var indoorEnd: String?
    var scoresAnchorDate: String   // day 0 of dailyScores
    var dailyScoresJSON: String    // JSON-encoded [Double]
    var reasoning: String?
    var fetchedAt: Int64           // ms-epoch, when the client last pulled it

    init(catalogSeedID: String, locationSignature: String, computedAt: Int64,
         source: String, confidence: Double, verdict: String,
         rangeStart: String?, rangeEnd: String?, indoorStart: String?, indoorEnd: String?,
         scoresAnchorDate: String, dailyScoresJSON: String, reasoning: String?,
         fetchedAt: Int64) {
        self.catalogSeedID = catalogSeedID
        self.locationSignature = locationSignature
        self.computedAt = computedAt
        self.source = source
        self.confidence = confidence
        self.verdict = verdict
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.indoorStart = indoorStart
        self.indoorEnd = indoorEnd
        self.scoresAnchorDate = scoresAnchorDate
        self.dailyScoresJSON = dailyScoresJSON
        self.reasoning = reasoning
        self.fetchedAt = fetchedAt
    }

    var dailyScores: [Double] {
        (try? JSONDecoder().decode([Double].self, from: Data(dailyScoresJSON.utf8))) ?? []
    }
}
