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
            // Route to Settings instead of opening an empty assistant tab.
            appEnv.requestedTab = .settings
            return
        }
        do {
            _ = try await appEnv.assistant.launchFromSparkle()
            appEnv.requestedTab = .assistant
        } catch {
            // Silent fail — user can still tap the Assistant tab and try.
            // We don't surface an error overlay here because the button is
            // typically in a crowded toolbar.
        }
    }
}
