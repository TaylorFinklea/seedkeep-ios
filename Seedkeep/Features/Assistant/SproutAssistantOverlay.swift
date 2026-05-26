import SwiftUI

/// Invisible host that observes `AIAssistantCoordinator.isSheetPresented`
/// and shows `SproutAssistantSheetView` as a sheet. Mounted once at the
/// signed-in root so the popup floats above any tab.
///
/// The FAB drives this — see `SproutFAB.tap`.
struct SproutAssistantOverlay: View {
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        @Bindable var coord = appEnv.assistant

        Color.clear
            .allowsHitTesting(false)
            .sheet(isPresented: $coord.isSheetPresented) {
                SproutAssistantSheetView()
            }
    }
}
