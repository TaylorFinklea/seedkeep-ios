import Foundation
import SwiftData

/// A household-owned annual care definition attached to one seed.
@Model
public final class LocalSeasonalCareTask {
    @Attribute(.unique) public var id: String
    public var householdID: String
    public var seedID: String
    public var title: String
    public var instructions: String
    public var startMonth: Int
    public var startDay: Int
    public var endMonth: Int
    public var endDay: Int
    public var notificationEnabled: Bool
    public var authorityName: String?
    public var sourceTitle: String?
    public var sourceURL: String?
    public var applicabilityLabel: String?
    public var templateID: String?
    public var templateVersion: Int?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        id: String,
        householdID: String,
        seedID: String,
        title: String,
        instructions: String,
        startMonth: Int,
        startDay: Int,
        endMonth: Int,
        endDay: Int,
        notificationEnabled: Bool = false,
        authorityName: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        applicabilityLabel: String? = nil,
        templateID: String? = nil,
        templateVersion: Int? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.seedID = seedID
        self.title = title
        self.instructions = instructions
        self.startMonth = startMonth
        self.startDay = startDay
        self.endMonth = endMonth
        self.endDay = endDay
        self.notificationEnabled = notificationEnabled
        self.authorityName = authorityName
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.applicabilityLabel = applicabilityLabel
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var annualCareWindow: AnnualCareWindow? {
        try? AnnualCareWindow(startMonth: startMonth, startDay: startDay,
                              endMonth: endMonth, endDay: endDay)
    }
}

/// One immutable annual completion occurrence. Its identity is deterministic so
/// concurrent completions converge by ordinary record identity.
@Model
public final class LocalSeasonalCareCompletion {
    @Attribute(.unique) public var id: String
    public var householdID: String
    public var taskID: String
    public var gardenYear: Int
    public var completedAt: Int64
    public var updatedAt: Int64

    public init(
        id: String? = nil,
        householdID: String,
        taskID: String,
        gardenYear: Int,
        completedAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id ?? Self.id(taskID: taskID, gardenYear: gardenYear)
        self.householdID = householdID
        self.taskID = taskID
        self.gardenYear = gardenYear
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }

    public static func id(taskID: String, gardenYear: Int) -> String {
        "\(taskID):\(gardenYear)"
    }
}
