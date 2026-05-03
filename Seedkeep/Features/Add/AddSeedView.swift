import SwiftUI
import SwiftData
import SeedkeepKit

/// Manual-entry sheet for adding a new seed packet. Scan-driven entry
/// lives in D-ios; this is the always-available offline-friendly path.
struct AddSeedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var appEnv

    @Query(filter: #Predicate<LocalLocation> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var locations: [LocalLocation]

    @Query(filter: #Predicate<LocalTag> { $0.deletedAt == nil },
           sort: \.name, order: .forward)
    private var tags: [LocalTag]

    @State private var state: SeedState = .active
    @State private var name: String = ""
    @State private var variety: String = ""
    @State private var company: String = ""
    @State private var packetCount: Int = 1
    @State private var locationID: String?
    @State private var selectedTagIDs: Set<String> = []
    @State private var yearPacked: Int?
    @State private var notes: String = ""
    @State private var source: SeedSource = .store

    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Lifecycle") {
                    Picker("State", selection: $state) {
                        Text("Active").tag(SeedState.active)
                        Text("Wishlist").tag(SeedState.wishlist)
                        Text("Saved").tag(SeedState.saved)
                        Text("Archive").tag(SeedState.archived)
                    }
                }

                Section("Identity") {
                    TextField("Name (e.g. Cherokee Purple)", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Variety (optional)", text: $variety)
                        .textInputAutocapitalization(.words)
                    TextField("Company (e.g. Baker Creek)", text: $company)
                        .textInputAutocapitalization(.words)
                }

                if state != .wishlist {
                    Section("Quantity") {
                        Stepper("\(packetCount) packet\(packetCount == 1 ? "" : "s")", value: $packetCount, in: 0...100)
                    }
                }

                Section("Storage") {
                    Picker("Location", selection: $locationID) {
                        Text("None").tag(String?.none)
                        ForEach(locations) { loc in
                            Text(loc.name).tag(Optional(loc.id))
                        }
                    }
                    if !tags.isEmpty {
                        NavigationLink {
                            TagPickerView(tags: tags, selection: $selectedTagIDs)
                        } label: {
                            HStack {
                                Text("Tags")
                                Spacer()
                                Text(selectedTagIDs.isEmpty ? "None" : "\(selectedTagIDs.count) selected")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Provenance") {
                    Picker("Source", selection: $source) {
                        Text("Store-bought").tag(SeedSource.store)
                        Text("Self-saved").tag(SeedSource.saved)
                        Text("Gift").tag(SeedSource.gift)
                        Text("Swap").tag(SeedSource.swap)
                    }
                    YearField(year: $yearPacked)
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add seed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
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
        saveError = nil
        defer { saving = false }

        guard case .signedIn(_, let household) = appEnv.auth.state else {
            saveError = "Not signed in."
            return
        }

        let input = SeedkeepClient.CreateSeedInput(
            state: state,
            packet_count: state == .wishlist ? 0 : packetCount,
            location_id: locationID,
            year_packed: yearPacked,
            source: source,
            custom_name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            custom_variety: variety.trimmedNonEmpty,
            custom_company: company.trimmedNonEmpty,
            notes: notes.trimmedNonEmpty,
            tag_ids: Array(selectedTagIDs)
        )

        do {
            _ = try appEnv.sync.enqueueCreateSeed(input, householdID: household.id)
            try? await appEnv.sync.flushPending()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct TagPickerView: View {
    let tags: [LocalTag]
    @Binding var selection: Set<String>

    var body: some View {
        List(tags) { tag in
            Button {
                if selection.contains(tag.id) {
                    selection.remove(tag.id)
                } else {
                    selection.insert(tag.id)
                }
            } label: {
                HStack {
                    Text(tag.name)
                    Spacer()
                    if selection.contains(tag.id) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct YearField: View {
    @Binding var year: Int?
    private let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())

    var body: some View {
        Picker("Year packed", selection: $year) {
            Text("Unknown").tag(Int?.none)
            ForEach((currentYear - 8 ... currentYear + 1).reversed(), id: \.self) { y in
                Text(String(y)).tag(Optional(y))
            }
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
