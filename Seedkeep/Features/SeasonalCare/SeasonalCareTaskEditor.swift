import SwiftUI

struct SeasonalCareTaskEditor: View {
    let seedID: String
    let task: LocalSeasonalCareTask?
    let onSaved: (_ requestedAuthorization: Bool) -> Void

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var instructions: String
    @State private var startMonth: String
    @State private var startDay: String
    @State private var endMonth: String
    @State private var endDay: String
    @State private var notificationsEnabled: Bool
    @State private var errorMessage: String?

    init(
        seedID: String,
        task: LocalSeasonalCareTask?,
        onSaved: @escaping (_ requestedAuthorization: Bool) -> Void = { _ in }
    ) {
        self.seedID = seedID
        self.task = task
        self.onSaved = onSaved
        _title = State(initialValue: task?.title ?? "")
        _instructions = State(initialValue: task?.instructions ?? "")
        _startMonth = State(initialValue: task.map { String($0.startMonth) } ?? "")
        _startDay = State(initialValue: task.map { String($0.startDay) } ?? "")
        _endMonth = State(initialValue: task.map { String($0.endMonth) } ?? "")
        _endDay = State(initialValue: task.map { String($0.endDay) } ?? "")
        _notificationsEnabled = State(initialValue: task?.notificationEnabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Care task") {
                    TextField("Title", text: $title)
                        .accessibilityLabel("Care task title")
                    TextField("Instructions", text: $instructions, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityLabel("Care task instructions")
                }

                Section {
                    monthDayField("Starts", month: $startMonth, day: $startDay)
                    monthDayField("Ends", month: $endMonth, day: $endDay)
                    Text("The window repeats each year. February 29 resolves to February 28 in non-leap years.")
                        .font(.footnote)
                        .foregroundStyle(HerbColor.inkSoft)
                } header: {
                    Text("Annual window")
                }

                Section {
                    Toggle("Remind me at the start", isOn: $notificationsEnabled)
                    Text("Reminders are optional. In-app care tracking remains available if notifications are unavailable.")
                        .font(.footnote)
                        .foregroundStyle(HerbColor.inkSoft)
                } header: {
                    Text("Reminder")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(HerbColor.rose)
                        .accessibilityLabel("Care task error: \(errorMessage)")
                }
            }
            .navigationTitle(task == nil ? "New care task" : "Edit care task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func monthDayField(
        _ label: String,
        month: Binding<String>,
        day: Binding<String>
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("MM", text: month)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .accessibilityLabel("\(label) month")
            Text("/")
            TextField("DD", text: day)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .accessibilityLabel("\(label) day")
        }
    }

    private func save() {
        guard let startMonth = Int(startMonth),
              let startDay = Int(startDay),
              let endMonth = Int(endMonth),
              let endDay = Int(endDay)
        else {
            errorMessage = "Enter numeric month and day values."
            return
        }

        let attribution: SeasonalCareAttributionSnapshot?
        if let task {
            attribution = SeasonalCareAttributionSnapshot(
                authorityName: task.authorityName,
                sourceTitle: task.sourceTitle,
                sourceURL: task.sourceURL,
                applicabilityLabel: task.applicabilityLabel)
        } else {
            attribution = nil
        }
        let draft = SeasonalCareTaskDraft(
            title: title,
            instructions: instructions,
            startMonth: startMonth,
            startDay: startDay,
            endMonth: endMonth,
            endDay: endDay,
            notificationEnabled: notificationsEnabled,
            attribution: attribution,
            templateID: task?.templateID,
            templateVersion: task?.templateVersion)

        do {
            let wasEnabled = task?.notificationEnabled ?? false
            if let task {
                try appEnv.seasonalCare.update(taskID: task.id, draft: draft)
            } else {
                try appEnv.seasonalCare.createManual(draft, seedID: seedID)
            }
            onSaved(notificationsEnabled && !wasEnabled)
            dismiss()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case SeasonalCareStoreError.emptyTitle:
            return "Add a title for this care task."
        case SeasonalCareStoreError.emptyInstructions:
            return "Add instructions so this task is useful later."
        case SeasonalCareStoreError.invalidWindow(_):
            return "Choose a valid annual window."
        case SeasonalCareStoreError.occurrenceNotDue:
            return "This occurrence is not ready to complete yet."
        default:
            return "Couldn't save this care task. Try again."
        }
    }
}
