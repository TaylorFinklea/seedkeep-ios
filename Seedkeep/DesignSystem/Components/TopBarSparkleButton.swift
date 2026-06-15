import SwiftUI

/// Toolbar button that opens Sprout in a fresh thread, with the current
/// page's context pre-attached. Place in a `.toolbar { ToolbarItem(...) }`
/// on any primary view (Library, Garden, SeedDetail, BedDetail, etc.).
///
/// When the user's API key isn't configured, the button still appears but
/// taps route to Settings instead — discoverability over silence.
struct TopBarSparkleButton: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var working = false

    var body: some View {
        Button {
            Task { await launch() }
        } label: {
            Image(systemName: "sparkles")
                .symbolRenderingMode(.hierarchical)
        }
        .tint(HerbColor.sepia)
        .disabled(working)
        .accessibilityLabel("Ask Sprout")
    }

    private func launch() async {
        working = true
        defer { working = false }
        if !appEnv.assistant.keyConfigured {
            // Route to You so the user can navigate to Settings → AI assistant
            // key. Settings now lives under You rather than as a standalone tab.
            appEnv.requestedTab = .you
            return
        }
        do {
            try await appEnv.assistant.presentSheet()
        } catch {
            appEnv.surfaceError(error)
        }
    }
}
