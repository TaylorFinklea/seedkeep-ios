import SwiftUI
import SeedkeepKit

/// Seven-tab root: Today / Library / Garden / Journal / Sprout / Settings
/// / You. Today (Diurnalis) is the default landing — a daily dashboard
/// with sun arc + sowing queue + recent journal margin note. Sprout (the
/// BYOK AI assistant) lives here as a tab for browsing past conversations
/// AND as a bottom-right FAB on every page that opens a context-aware
/// popup sheet. Random pick lives in Library's toolbar.
struct MainTabView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var selection: AppEnvironment.AppTab = .today

    var body: some View {
        TabView(selection: $selection) {
            TodayView()
                .tag(AppEnvironment.AppTab.today)
                .tabItem { Label("Today", systemImage: "sun.max") }

            LibraryView()
                .tag(AppEnvironment.AppTab.library)
                .tabItem { Label("Library", systemImage: "leaf") }

            GardenView()
                .tag(AppEnvironment.AppTab.garden)
                .tabItem { Label("Garden", systemImage: "square.grid.3x3.topleft.filled") }

            JournalView()
                .tag(AppEnvironment.AppTab.journal)
                .tabItem { Label("Journal", systemImage: "book") }

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
