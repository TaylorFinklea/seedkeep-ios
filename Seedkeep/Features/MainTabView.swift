import SwiftUI
import SeedkeepKit

/// Six-tab root: Library / Garden / Journal / Random / Settings / You.
/// Garden is the Phase 2 entry point (beds + planting events). Journal
/// is the Phase 3 entry point — read-only feed in T4, compose + detail
/// follow. Random and Settings shipped in C-ios.
struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "leaf") }

            GardenView()
                .tabItem { Label("Garden", systemImage: "square.grid.3x3.topleft.filled") }

            JournalView()
                .tabItem { Label("Journal", systemImage: "book") }

            RandomPickView()
                .tabItem { Label("Random", systemImage: "shuffle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }

            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
    }
}
