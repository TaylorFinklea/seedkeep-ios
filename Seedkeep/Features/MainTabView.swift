import SwiftUI
import SeedkeepKit

/// Seven-tab root: Library / Garden / Journal / Random / Assistant /
/// Settings / You. Assistant is the Phase 4 entry point — Sprout, the
/// BYOK AI assistant. Journal (Phase 3) is the conversation substrate.
struct MainTabView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var selection: AppEnvironment.AppTab = .library

    var body: some View {
        TabView(selection: $selection) {
            LibraryView()
                .tag(AppEnvironment.AppTab.library)
                .tabItem { Label("Library", systemImage: "leaf") }

            GardenView()
                .tag(AppEnvironment.AppTab.garden)
                .tabItem { Label("Garden", systemImage: "square.grid.3x3.topleft.filled") }

            JournalView()
                .tag(AppEnvironment.AppTab.journal)
                .tabItem { Label("Journal", systemImage: "book") }

            RandomPickView()
                .tag(AppEnvironment.AppTab.random)
                .tabItem { Label("Random", systemImage: "shuffle") }

            AssistantView()
                .tag(AppEnvironment.AppTab.assistant)
                .tabItem { Label("Sprout", systemImage: "sparkles") }

            SettingsView()
                .tag(AppEnvironment.AppTab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }

            YouView()
                .tag(AppEnvironment.AppTab.you)
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
        .onChange(of: appEnv.requestedTab) { _, requested in
            if let requested {
                selection = requested
                appEnv.requestedTab = nil  // single-shot
            }
        }
    }
}
