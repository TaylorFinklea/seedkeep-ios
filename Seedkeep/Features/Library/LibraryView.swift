import SwiftUI
import SeedkeepKit

/// Phase 1 / B-step placeholder. C-ios will hang the seed list, filters,
/// and add-flow off this view. We deliberately render empty states for
/// each lifecycle so the navigation shape is locked in.
struct LibraryView: View {
    @Environment(AuthController.self) private var auth
    @State private var selectedState: SeedState = .active

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Lifecycle", selection: $selectedState) {
                    Text("Active").tag(SeedState.active)
                    Text("Wishlist").tag(SeedState.wishlist)
                    Text("Saved").tag(SeedState.saved)
                    Text("Archive").tag(SeedState.archived)
                }
                .pickerStyle(.segmented)
                .padding()

                Spacer()

                ContentUnavailableView(
                    "No \(selectedState.rawValue) seeds yet",
                    systemImage: "leaf",
                    description: Text("C-ios will list your packets here. Backend is ready.")
                )

                Spacer()
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
