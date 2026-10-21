import SwiftUI
import SeedkeepKit

/// Five-tab root for the compact interface: Today, Seeds, Garden, Journal and Settings
/// (`AppEnvironment.AppTab`). Today is the default landing. Settings replaced the You tab in
/// R2b; the server-era rows You held were already hidden and stay unreachable until N3.
///
/// Sprout (the BYOK AI assistant) and Claude/MCP connections have no entry
/// point as of the 2026-07-27 V1 plan's removal of "temporarily unavailable"
/// surfaces — the FAB, the overlay sheet, and the You → Sprout link are gone.
/// The implementation and its unreferenced views remain for a 1.1 re-wire.
struct MainTabView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var selection: AppEnvironment.AppTab = .today

    /// Auto-dismiss timer for the error banner. Replaced (cancelled) when
    /// a new error fires so the 8s clock resets.
    @State private var dismissTask: Task<Void, Never>?

    @ViewBuilder
    private func tabRoot(_ tab: AppEnvironment.AppTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .seeds: LibraryView()
        case .garden: GardenView()
        case .journal: JournalView()
        case .settings: NavigationStack { SettingsContent() }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppEnvironment.AppTab.allCases, id: \.self) { tab in
                tabRoot(tab)
                    .tag(tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
            }
        }
        .overlay(alignment: .top) { bannerOverlay }
        .onChange(of: appEnv.requestedTab) { _, requested in
            if let requested {
                selection = requested
                appEnv.requestedTab = nil  // single-shot
            }
        }
        .onChange(of: appEnv.bannerError) { _, newValue in
            // Schedule auto-dismiss when a banner appears, cancel the
            // timer when the user (or the timer itself) clears it.
            // Debounce of repeated identical errors lives in
            // AppEnvironment.presentBanner so it covers every entry
            // point uniformly (surfaceError + post-sync mirror).
            if newValue != nil {
                scheduleAutoDismiss()
            } else {
                dismissTask?.cancel()
                dismissTask = nil
            }
        }
    }

    @ViewBuilder
    private var bannerOverlay: some View {
        if let message = appEnv.bannerError {
            WBBanner(
                severity: .error,
                title: "Sync hiccup",
                message: message,
                action: ("dismiss", {
                    dismissTask?.cancel()
                    dismissTask = nil
                    appEnv.dismissBannerError()
                })
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: appEnv.bannerError)
        }
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled {
                appEnv.dismissBannerError()
            }
        }
    }
}
