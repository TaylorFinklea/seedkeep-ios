import SwiftUI
import SeedkeepKit

/// Seven-tab root: Library / Garden / Journal / Random / Assistant /
/// Settings / You. Assistant is the Phase 4 entry point — Sprout, the
/// BYOK AI assistant. Journal (Phase 3) is the conversation substrate.
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

            AssistantView()
                .tabItem { Label("Sprout", systemImage: "sparkles") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }

            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
    }
}
