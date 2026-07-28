import SwiftUI
import SeedkeepKit

/// Five-tab root: Today / Library / Garden / Journal / You. Today (Diurnalis)
/// is the default landing — a daily dashboard with sun arc + sowing queue +
/// recent journal margin note. Settings lives under You → Settings.
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

            YouView()
                .tag(AppEnvironment.AppTab.you)
                .tabItem { Label("You", systemImage: "person.crop.circle") }
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
            HerbBanner(
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
