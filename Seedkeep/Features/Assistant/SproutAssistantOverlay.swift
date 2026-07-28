import SwiftUI

// Intentionally unwired for 1.0 — no entry point mounts this view; see the
// 2026-07-27 V1 plan's Sprout/MCP removal.
/// Invisible host that observes `AIAssistantCoordinator.isSheetPresented`
/// and shows `SproutAssistantSheetView` as a sheet. Mounted once at the
/// signed-in root so the popup floats above any tab.
///
/// The FAB drives this — see `SproutFAB.tap`.
struct SproutAssistantOverlay: View {
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        @Bindable var coord = appEnv.assistant

        if FeatureFlags.serverGardenFeaturesRestricted {
            Color.clear
                .onAppear { appEnv.assistant.dismissSheet() }
        } else {
            Color.clear
                .allowsHitTesting(false)
                .sheet(isPresented: $coord.isSheetPresented) {
                    SproutAssistantSheetView()
                }
        }
    }
}
