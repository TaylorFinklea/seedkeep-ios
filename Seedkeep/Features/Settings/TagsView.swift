import SwiftUI
import SwiftData
import SeedkeepKit

/// Manage user-defined tags. Color is optional; the iOS client decides
/// how to render the value (we accept hex, named, or any short string).
struct TagsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Query(filter: #Predicate<LocalTag> { $0.deletedAt == nil },
           sort: [SortDescriptor(\.name, order: .forward)])
    private var tags: [LocalTag]

    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newColor: Color? = nil
    @State private var renamingID: String?
    @State private var renameText = ""

    private let palette: [(name: String, color: Color, hex: String)] = [
        ("Olive",  Color(red: 0.49, green: 0.62, blue: 0.24), "#7d9e3d"),
        ("Earth",  Color(red: 0.49, green: 0.37, blue: 0.24), "#7d5e3c"),
        ("Tomato", Color(red: 0.79, green: 0.25, blue: 0.17), "#c93f2c"),
        ("Sky",    Color(red: 0.16, green: 0.36, blue: 0.54), "#295c8a"),
        ("Slate",  Color(red: 0.40, green: 0.43, blue: 0.45), "#666e74"),
    ]

    var body: some View {
        Group {
            if tags.isEmpty {
                ContentUnavailableView(
                    "no tags yet",
                    systemImage: "tag",
                    description: Text("Tags help you slice the library — try 'heirloom', 'salsa', or 'native'.")
                )
            } else {
                List {
                    ForEach(tags) { tag in
                        Button {
                            renamingID = tag.id
                            renameText = tag.name
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(colorFor(hex: tag.color))
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().strokeBorder(HerbColor.inkFaint, lineWidth: 0.5))
                                Text(tag.name)
                                Spacer()
                                Image(systemName: "pencil")
                                    .foregroundStyle(HerbColor.inkFaint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    newColor = nil
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add tag")
            }
        }
        .sheet(isPresented: $showingAdd) {
            NewTagSheet(name: $newName, palette: palette) { hex in
                addTag(hex: hex)
                showingAdd = false
            }
        }
        .alert("Rename tag", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) { renamingID = nil }
        }
    }

    private func addTag(hex: String?) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              case .signedIn(_, let household) = appEnv.auth.state else { return }
        do {
            _ = try appEnv.sync.enqueueCreateTag(
                name: trimmed,
                color: hex,
                householdID: household.id
            )
            Task { try? await appEnv.sync.flushPending() }
        } catch {}
    }

    private func saveRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = renamingID else { return }
        do {
            try appEnv.sync.enqueueUpdateTag(id: id, name: trimmed, color: nil)
            Task { try? await appEnv.sync.flushPending() }
        } catch {}
        renamingID = nil
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let tag = tags[index]
            try? appEnv.sync.enqueueDeleteTag(id: tag.id)
        }
        Task { try? await appEnv.sync.flushPending() }
    }

    private func colorFor(hex: String?) -> Color {
        guard let hex else { return Color.gray.opacity(0.5) }
        if let match = palette.first(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }) {
            return match.color
        }
        return Color.gray.opacity(0.5)
    }
}

private struct NewTagSheet: View {
    @Binding var name: String
    let palette: [(name: String, color: Color, hex: String)]
    let onSave: (String?) -> Void

    @State private var selectedHex: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tag name", text: $name)
                        .textInputAutocapitalization(.words)
                } header: {
                    Rubric(text: "name")
                }
                Section {
                    ForEach(palette, id: \.hex) { entry in
                        Button {
                            selectedHex = (selectedHex == entry.hex) ? nil : entry.hex
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(entry.color)
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(HerbColor.inkFaint, lineWidth: 0.5))
                                Text(entry.name)
                                Spacer()
                                if selectedHex == entry.hex {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Rubric(text: "color")
                }
            }
            .vellumForm()
            .navigationTitle("New tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onSave(selectedHex) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
