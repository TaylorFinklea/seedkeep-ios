import SwiftUI
import SeedkeepKit

/// Five-tab root: Library / Garden / Random / Settings / You. Garden is
/// the Phase 2 entry point — beds + planting events. Random and Settings
/// shipped in C-ios.
struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "leaf") }

            GardenView()
                .tabItem { Label("Garden", systemImage: "square.grid.3x3.topleft.filled") }

            RandomPickView()
                .tabItem { Label("Random", systemImage: "shuffle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }

            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
    }
}
