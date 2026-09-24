import Foundation
import SwiftData

public struct SeasonalCareAttributionSnapshot: Equatable, Sendable {
    public let authorityName: String?
    public let sourceTitle: String?
    public let sourceURL: String?
    public let applicabilityLabel: String?

    public init(
        authorityName: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        applicabilityLabel: String? = nil
    ) {
        self.authorityName = authorityName
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.applicabilityLabel = applicabilityLabel
    }
}

public struct SeasonalCareTaskDraft: Equatable, Sendable {
    public let title: String
    public let instructions: String
    public let startMonth: Int
    public let startDay: Int
    public let endMonth: Int
    public let endDay: Int
    public let notificationEnabled: Bool
    public let attribution: SeasonalCareAttributionSnapshot?
    public let templateID: String?
    public let templateVersion: Int?

    public init(
        title: String,
        instructions: String,
        startMonth: Int,
        startDay: Int,
        endMonth: Int,
        endDay: Int,
        notificationEnabled: Bool = false,
        attribution: SeasonalCareAttributionSnapshot? = nil,
        templateID: String? = nil,
        templateVersion: Int? = nil
    ) {
        self.title = title
        self.instructions = instructions
        self.startMonth = startMonth
        self.startDay = startDay
        self.endMonth = endMonth
        self.endDay = endDay
        self.notificationEnabled = notificationEnabled
        self.attribution = attribution
        self.templateID = templateID
        self.templateVersion = templateVersion
    }

    public var annualCareWindow: AnnualCareWindow? {
        try? AnnualCareWindow(startMonth: startMonth, startDay: startDay,
                              endMonth: endMonth, endDay: endDay)
    }
}

public enum SeasonalCareStoreError: Error, Equatable, Sendable {
    case noActiveHousehold
    case seedNotFound
    case seedBelongsToAnotherHousehold
    case taskNotFound
    case taskBelongsToAnotherHousehold
    case taskDeleted
    case emptyTitle
    case emptyInstructions
    case invalidWindow(AnnualCareWindow.ValidationError)
    case occurrenceNotDue
}

@MainActor
public protocol SeasonalCareMutating {
    func createManual(_ draft: SeasonalCareTaskDraft, seedID: String) throws -> String
    func addTemplate(_ template: SeasonalCareTemplate, seedID: String) throws -> String
    func update(taskID: String, draft: SeasonalCareTaskDraft) throws
    func complete(taskID: String, on date: Date, calendar: Calendar, timeZone: TimeZone) throws
    func delete(taskID: String) throws
}

/// The single local write boundary for seasonal care. Every mutation validates,
/// saves, and only then emits the existing household-sync signal.
@MainActor
public final class SeasonalCareStore: SeasonalCareMutating {
    public let container: ModelContainer
    private let householdIDProvider: () -> String?
    private let clock: () -> Date
    public var onLocalHouseholdMutation: () -> Void
    public var cloudKitScopeIDProvider: (() -> String?)?

    public init(
        container: ModelContainer,
        householdIDProvider: @escaping () -> String?,
        clock: @escaping () -> Date = Date.init,
        onLocalHouseholdMutation: @escaping () -> Void = {}
    ) {
        self.container = container
        self.householdIDProvider = householdIDProvider
        self.clock = clock
        self.onLocalHouseholdMutation = onLocalHouseholdMutation
    }

    @discardableResult
    public func createManual(_ draft: SeasonalCareTaskDraft, seedID: String) throws -> String {
        let householdID = try activeHouseholdID()
        try validate(draft)
        try requireSeed(seedID, householdID: householdID)
        let id = UUID().uuidString
        let now = milliseconds(clock())
        let context = ModelContext(container)
        context.insert(makeTask(id: id, householdID: householdID, seedID: seedID,
                                draft: draft, createdAt: now, updatedAt: now))
        try context.save()
        onLocalHouseholdMutation()
        return id
    }

    @discardableResult
    public func addTemplate(_ template: SeasonalCareTemplate, seedID: String) throws -> String {
        let draft = SeasonalCareTaskDraft(
            title: template.title,
            instructions: template.instructions,
            startMonth: template.startMonth,
            startDay: template.startDay,
            endMonth: template.endMonth,
            endDay: template.endDay,
            notificationEnabled: false,
            attribution: SeasonalCareAttributionSnapshot(
                authorityName: template.authorityName,
                sourceTitle: template.sourceTitle,
                sourceURL: template.sourceURL.absoluteString,
                applicabilityLabel: template.applicabilityLabel),
            templateID: template.id,
            templateVersion: template.version)
        return try create(draft, seedID: seedID)
    }

    public func update(taskID: String, draft: SeasonalCareTaskDraft) throws {
        let householdID = try activeHouseholdID()
        try validate(draft)
        let context = ModelContext(container)
        let task = try fetchTask(taskID, householdID: householdID, in: context)
        let now = milliseconds(clock())
        apply(draft, to: task)
        task.updatedAt = now
        try context.save()
        onLocalHouseholdMutation()
    }

    public func complete(taskID: String, on date: Date, calendar: Calendar, timeZone: TimeZone) throws {
        let householdID = try activeHouseholdID()
        let context = ModelContext(container)
        let task = try fetchTask(taskID, householdID: householdID, in: context)
        guard let window = task.annualCareWindow else {
            throw SeasonalCareStoreError.invalidWindow(.invalidMonth(task.startMonth))
        }
        let completions = (try? context.fetch(FetchDescriptor<LocalSeasonalCareCompletion>(
            predicate: #Predicate { $0.taskID == taskID && $0.householdID == householdID }
        ))) ?? []
        let completedYears = Set(completions.map(\.gardenYear))
        let createdAt = Date(timeIntervalSince1970: TimeInterval(task.createdAt) / 1000)
        let evaluation = try window.evaluation(
            on: date, calendar: calendar, timeZone: timeZone,
            completedGardenYears: completedYears, firstOccurrenceDate: createdAt)
        guard evaluation.state == .due || evaluation.state == .overdue else {
            if evaluation.state == .completed { return }
            throw SeasonalCareStoreError.occurrenceNotDue
        }
        let id = LocalSeasonalCareCompletion.id(
            taskID: taskID, gardenYear: evaluation.occurrence.gardenYear)
        if (try? context.fetch(FetchDescriptor<LocalSeasonalCareCompletion>(
            predicate: #Predicate { $0.id == id }
        )))?.first != nil { return }
        let now = milliseconds(clock())
        context.insert(LocalSeasonalCareCompletion(
            householdID: householdID, taskID: taskID,
            gardenYear: evaluation.occurrence.gardenYear,
            completedAt: now, updatedAt: now))
        try context.save()
        onLocalHouseholdMutation()
    }

    public func delete(taskID: String) throws {
        let householdID = try activeHouseholdID()
        let context = ModelContext(container)
        let task = try fetchTask(taskID, householdID: householdID, in: context)
        let now = milliseconds(clock())
        task.deletedAt = now
        task.updatedAt = now
        let completions = (try? context.fetch(FetchDescriptor<LocalSeasonalCareCompletion>(
            predicate: #Predicate { $0.taskID == taskID && $0.householdID == householdID }
        ))) ?? []
        let scopeID = cloudKitScopeIDProvider?()
        for completion in completions {
            if let scopeID {
                let recordName = completion.cloudKitValue.recordName
                let intentID = "\(scopeID)|\(recordName)"
                let existing = (try? context.fetch(FetchDescriptor<LocalCloudKitDeletion>(
                    predicate: #Predicate { $0.id == intentID }
                )))?.first
                if existing == nil {
                    context.insert(LocalCloudKitDeletion(
                        scopeID: scopeID, householdID: householdID,
                        recordName: recordName, createdAt: now))
                }
            }
            context.delete(completion)
        }
        try context.save()
        onLocalHouseholdMutation()
    }

    private func create(_ draft: SeasonalCareTaskDraft, seedID: String) throws -> String {
        let householdID = try activeHouseholdID()
        try validate(draft)
        try requireSeed(seedID, householdID: householdID)
        let id = UUID().uuidString
        let now = milliseconds(clock())
        let context = ModelContext(container)
        context.insert(makeTask(id: id, householdID: householdID, seedID: seedID,
                                draft: draft, createdAt: now, updatedAt: now))
        try context.save()
        onLocalHouseholdMutation()
        return id
    }

    private func activeHouseholdID() throws -> String {
        guard let id = householdIDProvider(), !id.isEmpty else {
            throw SeasonalCareStoreError.noActiveHousehold
        }
        return id
    }

    private func requireSeed(_ seedID: String, householdID: String) throws {
        let context = ModelContext(container)
        guard let seed = (try? context.fetch(FetchDescriptor<LocalSeed>(
            predicate: #Predicate { $0.id == seedID }
        )))?.first else { throw SeasonalCareStoreError.seedNotFound }
        guard seed.householdID == householdID else {
            throw SeasonalCareStoreError.seedBelongsToAnotherHousehold
        }
        guard seed.deletedAt == nil else { throw SeasonalCareStoreError.seedNotFound }
    }

    private func fetchTask(_ id: String, householdID: String, in context: ModelContext) throws -> LocalSeasonalCareTask {
        guard let task = (try? context.fetch(FetchDescriptor<LocalSeasonalCareTask>(
            predicate: #Predicate { $0.id == id }
        )))?.first else { throw SeasonalCareStoreError.taskNotFound }
        guard task.householdID == householdID else {
            throw SeasonalCareStoreError.taskBelongsToAnotherHousehold
        }
        guard task.deletedAt == nil else { throw SeasonalCareStoreError.taskDeleted }
        return task
    }

    private func validate(_ draft: SeasonalCareTaskDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SeasonalCareStoreError.emptyTitle
        }
        guard !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SeasonalCareStoreError.emptyInstructions
        }
        do { _ = try AnnualCareWindow(startMonth: draft.startMonth, startDay: draft.startDay,
                                      endMonth: draft.endMonth, endDay: draft.endDay) }
        catch let error as AnnualCareWindow.ValidationError {
            throw SeasonalCareStoreError.invalidWindow(error)
        }
    }

    private func makeTask(id: String, householdID: String, seedID: String,
                          draft: SeasonalCareTaskDraft, createdAt: Int64,
                          updatedAt: Int64) -> LocalSeasonalCareTask {
        let attribution = draft.attribution
        return LocalSeasonalCareTask(
            id: id, householdID: householdID, seedID: seedID,
            title: draft.title, instructions: draft.instructions,
            startMonth: draft.startMonth, startDay: draft.startDay,
            endMonth: draft.endMonth, endDay: draft.endDay,
            notificationEnabled: draft.notificationEnabled,
            authorityName: attribution?.authorityName,
            sourceTitle: attribution?.sourceTitle,
            sourceURL: attribution?.sourceURL,
            applicabilityLabel: attribution?.applicabilityLabel,
            templateID: draft.templateID,
            templateVersion: draft.templateVersion,
            createdAt: createdAt, updatedAt: updatedAt)
    }

    private func apply(_ draft: SeasonalCareTaskDraft, to task: LocalSeasonalCareTask) {
        task.title = draft.title
        task.instructions = draft.instructions
        task.startMonth = draft.startMonth
        task.startDay = draft.startDay
        task.endMonth = draft.endMonth
        task.endDay = draft.endDay
        task.notificationEnabled = draft.notificationEnabled
        if let attribution = draft.attribution {
            task.authorityName = attribution.authorityName
            task.sourceTitle = attribution.sourceTitle
            task.sourceURL = attribution.sourceURL
            task.applicabilityLabel = attribution.applicabilityLabel
        }
        task.templateID = draft.templateID
        task.templateVersion = draft.templateVersion
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
