import SwiftUI
import SwiftData
import SeedkeepKit

/// Manage storage locations (kitchen drawer, garage shelf, fridge…).
/// Each mutation is optimistic + queued to the server via the SyncEngine.
struct LocationsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Query(filter: #Predicate<LocalLocation> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var locations: [LocalLocation]

    @State private var showingAdd = false
    @State private var newName = ""
    @State private var renamingID: String?
    @State private var renameText = ""

    var body: some View {
        listContent
            .navigationTitle("Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .alert("New location", isPresented: $showingAdd) {
                TextField("Name", text: $newName)
                Button("Add") { addLocation() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename location", isPresented: renameBinding) {
                TextField("Name", text: $renameText)
                Button("Save") { saveRename() }
                Button("Cancel", role: .cancel) { renamingID = nil }
            }
    }

    @ViewBuilder
    private var listContent: some View {
        if locations.isEmpty {
            ContentUnavailableView(
                "no locations yet",
                systemImage: "tray",
                description: Text("Add the spots where seeds physically live so you can find them again.")
            )
        } else {
            List {
                ForEach(locations) { loc in
                    locationRow(loc)
                }
                .onDelete(perform: delete)
            }
        }
    }

    @ViewBuilder
    private func locationRow(_ loc: LocalLocation) -> some View {
        Button {
            renamingID = loc.id
            renameText = loc.name
        } label: {
            HStack {
                Text(loc.name)
                Spacer()
                Image(systemName: "pencil").foregroundStyle(HerbColor.inkFaint)
            }
        }
        .buttonStyle(.plain)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                newName = ""
                showingAdd = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add location")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )
    }

    private func addLocation() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              case .signedIn(_, let household) = appEnv.auth.state else { return }
        do {
            _ = try appEnv.sync.enqueueCreateLocation(
                name: trimmed,
                sortOrder: locations.count,
                householdID: household.id
            )
            Task { try? await appEnv.sync.flushPending() }
        } catch {
            // Errors surface in SyncEngine.lastError.
        }
    }

    private func saveRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = renamingID else { return }
        try? appEnv.sync.enqueueUpdateLocation(id: id, name: trimmed, sortOrder: nil)
        Task { try? await appEnv.sync.flushPending() }
        renamingID = nil
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let loc = locations[index]
            try? appEnv.sync.enqueueDeleteLocation(id: loc.id)
        }
        Task { try? await appEnv.sync.flushPending() }
    }
}
