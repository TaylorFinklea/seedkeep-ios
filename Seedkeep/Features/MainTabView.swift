import SwiftUI
import SeedkeepKit

/// Five-tab root: Library / Plan / Random / Settings / You. Plan is still
/// a placeholder (Phase 2). Random and Settings are real in C-ios.
struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "leaf") }

            Text("Plan — coming in Phase 2")
                .foregroundStyle(.secondary)
                .tabItem { Label("Plan", systemImage: "calendar") }

            RandomPickView()
                .tabItem { Label("Random", systemImage: "shuffle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }

            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
    }
}
