import SwiftUI
import SwiftData
import SeedkeepKit

/// Create + edit a journal entry. `entryID == nil` means create; otherwise
/// the view loads the existing `LocalJournalEntry` and PATCHes on save.
struct JournalEntryView: View {
    /// nil ⇒ creating new; non-nil ⇒ editing existing entry by id.
    let entryID: String?

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var occurredOn: Date = Date()
    @State private var entryBody: String = ""
    @State private var seedID: String?
    @State private var bedID: String?
    @State private var plantingEventID: String?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var didLoadInitial = false

    var body: some View {
        Form {
            Section("Date") {
                DatePicker("Occurred on", selection: $occurredOn, displayedComponents: .date)
            }
            Section("Entry") {
                TextField("What happened?", text: $entryBody, axis: .vertical)
                    .lineLimit(3...12)
            }
            Section {
                AttachedEntityPicker(
                    seedID: $seedID,
                    bedID: $bedID,
                    plantingEventID: $plantingEventID)
            } header: {
                Text("Attached to")
            }

            // TODO (T7): photo gallery section
            // TODO (T8): checklist section

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(entryID == nil ? "New entry" : "Edit entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(saving || entryBody.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(saving)
            }
        }
        .task {
            // Load existing entry's fields the first time the view appears.
            guard !didLoadInitial else { return }
            didLoadInitial = true
            if let id = entryID,
               let existing = try? modelContext.fetch(
                FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
               ).first {
                loadFields(from: existing)
            }
        }
    }

    private func loadFields(from entry: LocalJournalEntry) {
        if let date = Self.parseYYYYMMDD(entry.occurredOn) { occurredOn = date }
        entryBody = entry.body
        seedID = entry.seedID
        bedID = entry.bedID
        plantingEventID = entry.plantingEventID
    }

    private func save() async {
        saving = true
        errorMessage = nil
        defer { saving = false }
        let dateStr = Self.yyyymmdd(occurredOn)
        do {
            if let id = entryID,
               let local = try? modelContext.fetch(
                FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
               ).first {
                // PATCH existing entry. Use `.some(value)` (including
                // `.some(nil)` to clear) so the encoder actually emits
                // the field — plain `nil` would mean "omit / no change".
                var patch = SeedkeepClient.UpdateJournalEntryInput()
                patch.occurredOn = dateStr
                patch.body = entryBody
                patch.seedId = .some(seedID)
                patch.bedId = .some(bedID)
                patch.plantingEventId = .some(plantingEventID)
                let dto = try await appEnv.client.updateJournalEntry(local.id, patch)
                dto.apply(to: local)
                try modelContext.save()
            } else {
                // Create new entry via the store.
                _ = try await appEnv.journal.create(
                    occurredOn: dateStr,
                    body: entryBody,
                    seedID: seedID,
                    bedID: bedID,
                    plantingEventID: plantingEventID)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func yyyymmdd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: date)
    }

    static func parseYYYYMMDD(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.date(from: s)
    }
}
