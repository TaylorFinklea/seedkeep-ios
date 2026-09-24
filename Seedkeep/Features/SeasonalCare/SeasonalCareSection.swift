import SwiftUI
import SwiftData

/// Seed-owned seasonal care. The section is intentionally self-contained so
/// the same task projection can be mounted beside the other Seed Detail rows.
struct SeasonalCareSection: View {
    let seed: LocalSeed

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.openURL) private var openURL
    @Query private var taskQuery: [LocalSeasonalCareTask]
    @Query private var completionQuery: [LocalSeasonalCareCompletion]
    @State private var showingEditor = false
    @State private var showingTemplatePicker = false
    @State private var editingTaskID: String?
    @State private var pendingTemplateTask: LocalSeasonalCareTask?
    @State private var loadedTemplates: [SeasonalCareTemplate] = []
    @State private var templateUnavailableMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var taskToDelete: LocalSeasonalCareTask?
    @State private var errorMessage: String?

    init(seed: LocalSeed) {
        self.seed = seed
        let seedID = seed.id
        _taskQuery = Query(
            filter: #Predicate<LocalSeasonalCareTask> { task in
                task.seedID == seedID && task.deletedAt == nil
            },
            sort: \.updatedAt,
            order: .reverse
        )
        _completionQuery = Query(
            filter: #Predicate<LocalSeasonalCareCompletion> { completion in
                completion.householdID != ""
            }
        )
    }

    var body: some View {
        let groups = SeasonalCareViewHelpers.seedDetailGroups(viewStates)
        Section {
            if groups.active.isEmpty && groups.completed.isEmpty {
                Text("No seasonal care tasks yet.")
                    .font(HerbFont.bodyItalic(size: 13))
                    .foregroundStyle(HerbColor.inkSoft)
            } else {
                ForEach(groups.active) { row in
                    taskRow(row)
                }
                if !groups.completed.isEmpty {
                    DisclosureGroup("Completed this year") {
                        ForEach(groups.completed) { row in
                            completedRow(row)
                        }
                    }
                }
                if !completionHistory.isEmpty {
                    DisclosureGroup("Completion history") {
                        ForEach(completionHistory) { completion in
                            VStack(alignment: .leading, spacing: 2) {
                                Label("\(completion.title) · \(completion.gardenYear)", systemImage: "checkmark.circle")
                                    .font(.subheadline)
                                Text("Completed \(completionDateLabel(completion.completedAt))")
                                    .font(.footnote)
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        }
                    }
                }
            }

            HStack {
                Button {
                    editingTaskID = nil
                    showingEditor = true
                } label: {
                    Label("Add manually", systemImage: "plus")
                }
                .accessibilityLabel("Add seasonal care task manually")

                Button {
                    openTemplatePicker()
                } label: {
                    Label("Templates", systemImage: "text.book.closed")
                }
                .disabled(cropKey == nil)
                .accessibilityLabel(cropKey == nil ? "Templates unavailable; add manually" : "Add seasonal care from templates")
            }

            if cropKey == nil {
                Text("Templates need a known crop. Add any care task manually.")
                    .font(.footnote)
                    .foregroundStyle(HerbColor.inkSoft)
            }
            if let templateUnavailableMessage {
                Text(templateUnavailableMessage)
                    .font(.footnote)
                    .foregroundStyle(HerbColor.rose)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(HerbColor.rose)
            }
        } header: {
            Rubric(text: "seasonal care")
        }
        .sheet(isPresented: $showingEditor) {
            SeasonalCareTaskEditor(
                seedID: seed.id,
                task: editingTask,
                onSaved: { requestedAuthorization in
                    pendingTemplateTask = nil
                    errorMessage = nil
                    reconcileReminders(allowAuthorizationRequest: requestedAuthorization)
                }
            )
        }
        .sheet(isPresented: $showingTemplatePicker) {
            SeasonalCareTemplatePicker(templates: loadedTemplates) { template in
                addTemplate(template)
            }
        }
        .confirmationDialog(
            "Delete this care task?",
            isPresented: $showDeleteConfirmation,
            presenting: taskToDelete
        ) { task in
            Button("Delete", role: .destructive) { delete(task) }
            Button("Cancel", role: .cancel) {}
        } message: { task in
            Text("This removes \(task.title) and its completion history.")
        }
    }

    private var activeHouseholdID: String? { appEnv.activeGardenHouseholdID }

    private var activeTasks: [LocalSeasonalCareTask] {
        guard let householdID = activeHouseholdID else { return [] }
        return taskQuery.filter { $0.householdID == householdID && $0.seedID == seed.id }
    }

    private var viewStates: [SeasonalCareTaskViewState] {
        let calendar = Calendar.current
        let timeZone = calendar.timeZone
        let evaluationDate = appEnv.seasonalCareEvaluationDate
        return activeTasks.compactMap { task in
            guard let window = task.annualCareWindow else { return nil }
            let completions = completionQuery.filter {
                $0.householdID == task.householdID && $0.taskID == task.id
            }
            let years = Set(completions.map(\.gardenYear))
            let createdDate = Date(timeIntervalSince1970: TimeInterval(task.createdAt) / 1_000)
            guard let evaluation = try? window.evaluation(
                on: evaluationDate,
                calendar: calendar,
                timeZone: timeZone,
                completedGardenYears: years,
                firstOccurrenceDate: createdDate
            ) else { return nil }
            return SeasonalCareTaskViewState(
                id: task.id,
                seedID: task.seedID,
                seedName: seed.customName ?? "Untitled seed",
                title: task.title,
                instructions: task.instructions,
                evaluation: evaluation,
                notificationEnabled: task.notificationEnabled,
                authorityName: task.authorityName,
                sourceTitle: task.sourceTitle,
                sourceURL: task.sourceURL,
                applicabilityLabel: task.applicabilityLabel
            )
        }
    }

    private var editingTask: LocalSeasonalCareTask? {
        guard let editingTaskID else { return nil }
        return activeTasks.first { $0.id == editingTaskID } ?? pendingTemplateTask
    }

    private var completionHistory: [SeasonalCareCompletionViewState] {
        let tasksByID = Dictionary(uniqueKeysWithValues: activeTasks.map { ($0.id, $0) })
        let currentOccurrenceByTask = Dictionary(uniqueKeysWithValues: viewStates.map {
            ($0.id, $0.occurrence.gardenYear)
        })
        let completions = completionQuery.compactMap { completion -> SeasonalCareCompletionViewState? in
            guard let task = tasksByID[completion.taskID],
                  task.householdID == completion.householdID else { return nil }
            let attribution = task.authorityName.map { authority in
                task.sourceTitle.map { source in "Source: \(authority), \(source)" }
                    ?? "Source: \(authority)"
            }
            return SeasonalCareCompletionViewState(
                id: completion.id,
                taskID: completion.taskID,
                title: task.title,
                seedName: seed.customName ?? "Untitled seed",
                gardenYear: completion.gardenYear,
                completedAt: completion.completedAt,
                attributionLabel: attribution)
        }
        return SeasonalCareViewHelpers.completionHistory(
            completions,
            currentOccurrenceByTask: currentOccurrenceByTask)
    }

    private var cropKey: String? {
        guard let raw = seed.customType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.lowercased()
    }

    private func openTemplatePicker() {
        guard let cropKey else { return }
        do {
            loadedTemplates = try appEnv.seasonalCareTemplates.templates(cropKey: cropKey, regionCode: nil)
            templateUnavailableMessage = nil
            showingTemplatePicker = true
        } catch {
            loadedTemplates = []
            templateUnavailableMessage = "Reviewed templates are unavailable right now. Add any care task manually."
        }
    }

    @ViewBuilder
    private func taskRow(_ row: SeasonalCareTaskViewState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(HerbFont.body(size: 16))
                    .foregroundStyle(HerbColor.ink)
                Spacer()
                Text(row.stateLabel)
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.2)
                    .foregroundStyle(row.state == .overdue ? HerbColor.rose : HerbColor.sepia)
                    .textCase(.uppercase)
            }
            Text(row.instructions)
                .font(.subheadline)
                .foregroundStyle(HerbColor.inkSoft)
            Text(SeasonalCareViewHelpers.timingLabel(for: row.occurrence, calendar: .current))
                .font(.footnote.weight(.medium))
                .foregroundStyle(HerbColor.sepia)
            if let applicability = row.applicabilityLabel {
                Text(applicability)
                    .font(.footnote)
                    .foregroundStyle(HerbColor.inkSoft)
            }
            if let attribution = row.attributionLabel {
                HStack(spacing: 8) {
                    Text(attribution)
                        .font(.footnote)
                        .foregroundStyle(HerbColor.inkSoft)
                    if let sourceURL = row.sourceURL, let url = URL(string: sourceURL) {
                        Button("Open source") { openURL(url) }
                            .font(.footnote.weight(.medium))
                    }
                }
            }
            HStack {
                Button {
                    complete(row)
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!isReadyToComplete(row.state))
                Toggle("Reminder", isOn: reminderBinding(for: row))
                    .labelsHidden()
                    .accessibilityLabel(row.notificationEnabled ? "Reminder on" : "Reminder off")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            editingTaskID = row.id
            showingEditor = true
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") {
                editingTaskID = row.id
                showingEditor = true
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                taskToDelete = activeTasks.first { $0.id == row.id }
                showDeleteConfirmation = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.seedName), \(row.title), \(row.stateLabel), \(SeasonalCareViewHelpers.timingLabel(for: row.occurrence, calendar: .current))")
    }

    private func completedRow(_ row: SeasonalCareTaskViewState) -> some View {
        taskRow(row)
    }

    private func reminderBinding(for row: SeasonalCareTaskViewState) -> Binding<Bool> {
        Binding(
            get: { row.notificationEnabled },
            set: { enabled in
                guard let task = activeTasks.first(where: { $0.id == row.id }) else { return }
                let draft = SeasonalCareTaskDraft(
                    title: task.title,
                    instructions: task.instructions,
                    startMonth: task.startMonth,
                    startDay: task.startDay,
                    endMonth: task.endMonth,
                    endDay: task.endDay,
                    notificationEnabled: enabled,
                    attribution: SeasonalCareAttributionSnapshot(
                        authorityName: task.authorityName,
                        sourceTitle: task.sourceTitle,
                        sourceURL: task.sourceURL,
                        applicabilityLabel: task.applicabilityLabel),
                    templateID: task.templateID,
                    templateVersion: task.templateVersion)
                do {
                    let wasEnabled = task.notificationEnabled
                    try appEnv.seasonalCare.update(taskID: task.id, draft: draft)
                    reconcileReminders(allowAuthorizationRequest: enabled && !wasEnabled)
                } catch {
                    errorMessage = "Couldn't update the reminder setting."
                }
            }
        )
    }

    private func addTemplate(_ template: SeasonalCareTemplate) {
        do {
            let id = try appEnv.seasonalCare.addTemplate(template, seedID: seed.id)
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            pendingTemplateTask = LocalSeasonalCareTask(
                id: id,
                householdID: activeHouseholdID ?? "",
                seedID: seed.id,
                title: template.title,
                instructions: template.instructions,
                startMonth: template.startMonth,
                startDay: template.startDay,
                endMonth: template.endMonth,
                endDay: template.endDay,
                authorityName: template.authorityName,
                sourceTitle: template.sourceTitle,
                sourceURL: template.sourceURL.absoluteString,
                applicabilityLabel: template.applicabilityLabel,
                templateID: template.id,
                templateVersion: template.version,
                createdAt: now,
                updatedAt: now
            )
            editingTaskID = id
            showingEditor = true
        } catch {
            errorMessage = "Couldn't add that template. Add the task manually instead."
        }
    }

    private func complete(_ row: SeasonalCareTaskViewState) {
        let calendar = Calendar.current
        do {
            try appEnv.seasonalCare.complete(
                taskID: row.id,
                on: Date(),
                calendar: calendar,
                timeZone: calendar.timeZone)
            reconcileReminders()
        } catch {
            errorMessage = "This task can be completed when its window begins."
        }
    }

    private func isReadyToComplete(_ state: AnnualCareState) -> Bool {
        switch state {
        case .due, .overdue: return true
        case .upcoming, .completed: return false
        }
    }

    private func delete(_ task: LocalSeasonalCareTask) {
        do {
            try appEnv.seasonalCare.delete(taskID: task.id)
            taskToDelete = nil
            reconcileReminders()
        } catch {
            errorMessage = "Couldn't delete this care task."
        }
    }

    private func reconcileReminders(allowAuthorizationRequest: Bool = false) {
        Task { @MainActor in
            let outcome = await appEnv.reconcileSeasonalCareReminders(
                allowAuthorizationRequest: allowAuthorizationRequest)
            switch outcome {
            case .permissionDenied:
                errorMessage = "Reminders are unavailable in iOS Settings; this care task remains active."
            case .schedulingFailed(_, _):
                errorMessage = "Couldn't schedule the reminder; this care task remains active. Try again."
            case .cancelled:
                break
            case .disabled, .reconciled(_, _):
                errorMessage = nil
            }
        }
    }

    private func completionDateLabel(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000))
    }
}
