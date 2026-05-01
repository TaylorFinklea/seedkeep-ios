import SwiftUI
import SeedkeepKit

/// Root tab navigation. Library and "You" are populated in B-step;
/// Plan and Random tabs are deliberate placeholders so the navigation
/// shape is set in stone before C-ios fills them in.
struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "leaf") }

            Text("Plan — coming in Phase 2")
                .foregroundStyle(.secondary)
                .tabItem { Label("Plan", systemImage: "calendar") }

            Text("Random — pulls a packet for you")
                .foregroundStyle(.secondary)
                .tabItem { Label("Random", systemImage: "shuffle") }

            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
    }
}
