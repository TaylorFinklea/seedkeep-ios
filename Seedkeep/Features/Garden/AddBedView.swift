import SwiftUI
import SeedkeepKit

/// Simple form for creating a new bed. Dimensions are optional —
/// Phase 2A doesn't use them yet, but capturing them now means the
/// spatial-layout work in Phase 2C doesn't need a separate backfill.
struct AddBedView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var widthFeet: String = ""
    @State private var lengthFeet: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Back garden, greenhouse shelf, etc.", text: $name)
                        .textInputAutocapitalization(.sentences)
                }
                Section("Description (optional)") {
                    TextField("What's special about this bed?", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    HStack {
                        Text("Width")
                        Spacer()
                        TextField("ft", text: $widthFeet)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text("ft").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Length")
                        Spacer()
                        TextField("ft", text: $lengthFeet)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text("ft").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Dimensions (optional)")
                } footer: {
                    Text("Used later for spatial layout. You can fill these in any time.")
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(HerbColor.rose)
                    }
                }
            }
            .navigationTitle("New bed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || !canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        guard case .signedIn(_, let household) = appEnv.auth.state else {
            error = "Not signed in."
            return
        }
        let input = SeedkeepClient.CreateBedInput(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmedNonEmpty,
            width_feet: Double(widthFeet.trimmingCharacters(in: .whitespaces)),
            length_feet: Double(lengthFeet.trimmingCharacters(in: .whitespaces))
        )
        do {
            _ = try appEnv.sync.enqueueCreateBed(input, householdID: household.id)
            await appEnv.syncIfPossible()
            dismiss()
        } catch let err as SeedkeepError {
            error = "\(err.code): \(err.message)"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
