import Foundation

/// A read-only, authority-attributed care definition bundled with the app.
///
/// Templates are inputs to an explicit snapshot operation. Once copied into a
/// household task, later pack changes do not mutate the task.
public struct SeasonalCareTemplate: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let version: Int
    public let cropKey: String
    public let regionCodes: [String]
    public let applicabilityLabel: String?
    public let title: String
    public let instructions: String
    public let startMonth: Int
    public let startDay: Int
    public let endMonth: Int
    public let endDay: Int
    public let authorityName: String
    public let sourceTitle: String
    public let sourceURL: URL

    public init(
        id: String,
        version: Int,
        cropKey: String,
        regionCodes: [String],
        applicabilityLabel: String? = nil,
        title: String,
        instructions: String,
        startMonth: Int,
        startDay: Int,
        endMonth: Int,
        endDay: Int,
        authorityName: String,
        sourceTitle: String,
        sourceURL: URL
    ) {
        self.id = id
        self.version = version
        self.cropKey = cropKey
        self.regionCodes = regionCodes
        self.applicabilityLabel = applicabilityLabel
        self.title = title
        self.instructions = instructions
        self.startMonth = startMonth
        self.startDay = startDay
        self.endMonth = endMonth
        self.endDay = endDay
        self.authorityName = authorityName
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
    }

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case cropKey = "crop_key"
        case regionCodes = "region_codes"
        case applicabilityLabel = "applicability_label"
        case title
        case instructions
        case startMonth = "start_month"
        case startDay = "start_day"
        case endMonth = "end_month"
        case endDay = "end_day"
        case authorityName = "authority_name"
        case sourceTitle = "source_title"
        case sourceURL = "source_url"
    }
}

public protocol SeasonalCareTemplateRepository: Sendable {
    func templates(cropKey: String, regionCode: String?) throws -> [SeasonalCareTemplate]
}
