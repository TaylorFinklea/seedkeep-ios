import Foundation

/// Wire-format DTOs for the planting-recommendation API endpoints.
/// The recommendation routes emit camelCase JSON keys, so synthesized
/// `Codable` conformance works without custom `CodingKeys`.

public struct DateRangeDTO: Codable, Sendable, Equatable {
    public let start: String   // 'YYYY-MM-DD'
    public let end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

public struct DailyScoresDTO: Codable, Sendable, Equatable {
    public let anchorDate: String  // 'YYYY-MM-DD'
    public let scores: [Double]    // length 60

    public init(anchorDate: String, scores: [Double]) {
        self.anchorDate = anchorDate
        self.scores = scores
    }
}

public struct RecommendationDTO: Codable, Sendable, Equatable {
    public let catalogSeedId: String
    public let locationSignature: String
    public let computedAt: Int64        // ms-epoch
    public let source: String           // 'rule' | 'ai'
    public let confidence: Double
    public let verdict: String          // too_early|plant_soon|plant_now|late|too_late|unknown
    public let recommendedRange: DateRangeDTO?
    public let indoorRange: DateRangeDTO?
    public let dailyScores: DailyScoresDTO
    public let reasoning: String?
    public let inputsUsed: [String]

    public init(
        catalogSeedId: String,
        locationSignature: String,
        computedAt: Int64,
        source: String,
        confidence: Double,
        verdict: String,
        recommendedRange: DateRangeDTO? = nil,
        indoorRange: DateRangeDTO? = nil,
        dailyScores: DailyScoresDTO,
        reasoning: String? = nil,
        inputsUsed: [String]
    ) {
        self.catalogSeedId = catalogSeedId
        self.locationSignature = locationSignature
        self.computedAt = computedAt
        self.source = source
        self.confidence = confidence
        self.verdict = verdict
        self.recommendedRange = recommendedRange
        self.indoorRange = indoorRange
        self.dailyScores = dailyScores
        self.reasoning = reasoning
        self.inputsUsed = inputsUsed
    }
}

public struct HouseholdLocationDTO: Codable, Sendable, Equatable {
    public let zip: String
    public let latitude: Double
    public let longitude: Double
    public let usdaZone: String
    public let avgLastFrost: String   // 'MM-DD'
    public let avgFirstFrost: String

    public init(
        zip: String,
        latitude: Double,
        longitude: Double,
        usdaZone: String,
        avgLastFrost: String,
        avgFirstFrost: String
    ) {
        self.zip = zip
        self.latitude = latitude
        self.longitude = longitude
        self.usdaZone = usdaZone
        self.avgLastFrost = avgLastFrost
        self.avgFirstFrost = avgFirstFrost
    }
}

public enum WireRecommendation {
    public struct BulkResponse: Codable, Sendable, Equatable {
        public let recommendations: [RecommendationDTO]
        public let pending: [String]

        public init(recommendations: [RecommendationDTO], pending: [String]) {
            self.recommendations = recommendations
            self.pending = pending
        }
    }
}
