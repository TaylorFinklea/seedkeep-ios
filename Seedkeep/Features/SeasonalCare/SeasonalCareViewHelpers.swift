import Foundation

/// Scalar, testable input for seasonal-care presentation. Views build this
/// from committed SwiftData rows and the shared annual evaluator.
public struct SeasonalCareTaskViewState: Equatable, Identifiable, Sendable {
    public let id: String
    public let seedID: String
    public let seedName: String
    public let title: String
    public let instructions: String
    public let evaluation: AnnualCareEvaluation
    public let notificationEnabled: Bool
    public let authorityName: String?
    public let sourceTitle: String?
    public let sourceURL: String?
    public let applicabilityLabel: String?

    public init(
        id: String,
        seedID: String,
        seedName: String,
        title: String,
        instructions: String,
        evaluation: AnnualCareEvaluation,
        notificationEnabled: Bool,
        authorityName: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        applicabilityLabel: String? = nil
    ) {
        self.id = id
        self.seedID = seedID
        self.seedName = seedName
        self.title = title
        self.instructions = instructions
        self.evaluation = evaluation
        self.notificationEnabled = notificationEnabled
        self.authorityName = authorityName
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.applicabilityLabel = applicabilityLabel
    }

    public var state: AnnualCareState { evaluation.state }
    public var occurrence: AnnualCareOccurrence { evaluation.occurrence }
    public var isCurrentCompletion: Bool { state == .completed }

    public var stateLabel: String {
        switch state {
        case .due: return "Due"
        case .overdue: return "Overdue"
        case .completed: return "Completed"
        case .upcoming(let days):
            return days == 1 ? "Starts tomorrow" : "Starts in \(days) days"
        }
    }

    public var attributionLabel: String? {
        guard let authorityName, !authorityName.isEmpty else { return nil }
        if let sourceTitle, !sourceTitle.isEmpty {
            return "Source: \(authorityName), \(sourceTitle)"
        }
        return "Source: \(authorityName)"
    }
}

/// A completion projected with its task identity and title. Keeping the task
/// on the history row prevents two different tasks completed in the same year
/// from collapsing into one indistinguishable entry.
public struct SeasonalCareCompletionViewState: Equatable, Identifiable, Sendable {
    public let id: String
    public let taskID: String
    public let title: String
    public let seedName: String
    public let gardenYear: Int
    public let completedAt: Int64
    public let attributionLabel: String?

    public init(
        id: String,
        taskID: String,
        title: String,
        seedName: String,
        gardenYear: Int,
        completedAt: Int64,
        attributionLabel: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.seedName = seedName
        self.gardenYear = gardenYear
        self.completedAt = completedAt
        self.attributionLabel = attributionLabel
    }
}

public enum SeasonalCareViewHelpers {
    /// Keeps the current completion visible in Seed Detail while separating
    /// it from active work. Previous-year history is supplied separately by
    /// the caller and is never inferred from the current state.
    public static func seedDetailGroups(
        _ rows: [SeasonalCareTaskViewState]
    ) -> (active: [SeasonalCareTaskViewState], completed: [SeasonalCareTaskViewState]) {
        let active = rows.filter { !$0.isCurrentCompletion }
        let completed = rows.filter(\.isCurrentCompletion)
        return (
            active.sorted(by: stableTaskOrder),
            completed.sorted(by: stableTaskOrder)
        )
    }

    /// Selects Today work in the required Due → Overdue → Upcoming order.
    /// Upcoming work is limited to the next 30 days, inclusive.
    public static func todayRows(
        _ rows: [SeasonalCareTaskViewState]
    ) -> [SeasonalCareTaskViewState] {
        rows
            .filter { row in
                switch row.state {
                case .due, .overdue: return true
                case .upcoming(let days): return days <= 30
                case .completed: return false
                }
            }
            .sorted { left, right in
                let leftRank = stateRank(left.state)
                let rightRank = stateRank(right.state)
                if leftRank != rightRank { return leftRank < rightRank }
                return stableTaskOrder(left, right)
            }
    }

    public static func timingLabel(
        for occurrence: AnnualCareOccurrence,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: occurrence.start))–\(formatter.string(from: occurrence.end))"
    }

    public static func completionHistory(
        _ completions: [SeasonalCareCompletionViewState],
        currentOccurrenceByTask: [String: Int] = [:]
    ) -> [SeasonalCareCompletionViewState] {
        completions
            .filter { completion in
                currentOccurrenceByTask[completion.taskID] != completion.gardenYear
            }
            .sorted {
                if $0.gardenYear != $1.gardenYear { return $0.gardenYear > $1.gardenYear }
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id < $1.id
            }
    }

    private static func stateRank(_ state: AnnualCareState) -> Int {
        switch state {
        case .due: return 0
        case .overdue: return 1
        case .upcoming: return 2
        case .completed: return 3
        }
    }

    private static func stableTaskOrder(
        _ left: SeasonalCareTaskViewState,
        _ right: SeasonalCareTaskViewState
    ) -> Bool {
        if left.occurrence.start != right.occurrence.start {
            return left.occurrence.start < right.occurrence.start
        }
        if left.seedName.localizedCaseInsensitiveCompare(right.seedName) != .orderedSame {
            return left.seedName.localizedCaseInsensitiveCompare(right.seedName) == .orderedAscending
        }
        return left.id < right.id
    }
}
