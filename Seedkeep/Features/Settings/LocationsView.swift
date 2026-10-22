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

    private var activeLocations: [LocalLocation] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return locations.filter { $0.householdID == householdID }
    }

    var body: some View {
        listContent
            .wbForm()
            .accessibilityIdentifier("screen.locations")
            .navigationTitle("Locations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        if activeLocations.isEmpty {
            WBEmptyState(
                title: "No locations yet",
                message: "Add the spots where seeds physically live so you can find them again.",
                systemImage: "tray"
            )
        } else {
            List {
                ForEach(activeLocations) { loc in
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
                    .foregroundStyle(WBColor.ink)
                Spacer()
                Image(systemName: "pencil")
                    .foregroundStyle(WBColor.faint)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Rename")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .platformTrailing) {
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
                sortOrder: activeLocations.count,
                householdID: appEnv.activeGardenHouseholdID ?? household.id
            )
        } catch {
            appEnv.surfaceError(error)
        }
    }

    private func saveRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = renamingID else { return }
        do {
            try appEnv.sync.enqueueUpdateLocation(id: id, name: trimmed, sortOrder: nil)
        } catch {
            appEnv.surfaceError(error)
        }
        renamingID = nil
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let loc = activeLocations[index]
            do {
                try appEnv.sync.enqueueDeleteLocation(id: loc.id)
            } catch {
                appEnv.surfaceError(error)
            }
        }
    }
}
