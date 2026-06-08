import SwiftUI

/// Floating action button mounted bottom-right of every primary page.
/// Opens Sprout in a fresh thread with the current page's context
/// pre-attached (read from `AIAssistantCoordinator.pageContext`, which
/// pages publish via `.publishesAssistantContext(...)`).
///
/// Patterned after SimmerSmith's `TabPrimaryFAB`. Pages mount it with
/// `.overlay(alignment: .bottomTrailing) { SproutFAB() }` on the OUTERMOST
/// container so it floats above the page's content (lists, sheets, etc).
///
/// When the user's API key isn't configured, the FAB routes to Settings
/// → AI Assistant instead of opening an empty thread.
struct SproutFAB: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var working = false
    @AppStorage("seedkeep.sparkleOnEveryPage") private var sparkleOnEveryPage: Bool = true

    /// Optional bottom-edge override. Useful when a page has a custom
    /// bottom-bar/composer that would overlap the FAB at the default offset.
    var bottomPadding: CGFloat = 16

    /// Optional trailing-edge override. Default matches Apple's
    /// large-titled-list right padding.
    var trailingPadding: CGFloat = 20

    var body: some View {
        if sparkleOnEveryPage {
            fabButton
        } else {
            EmptyView()
        }
    }

    private var fabButton: some View {
        Button {
            Task { await tap() }
        } label: {
            ZStack {
                Circle()
                    .fill(HerbColor.sepia)
                    .frame(width: 56, height: 56)
                    .shadow(color: HerbColor.sepia.opacity(0.35), radius: 12, y: 4)
                if working {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .disabled(working)
        .padding(.trailing, trailingPadding)
        .padding(.bottom, bottomPadding)
        .accessibilityLabel("Ask Sprout")
    }

    private func tap() async {
        working = true
        defer { working = false }
        if !appEnv.assistant.keyConfigured {
            // Route to Settings so the user can configure their key. The
            // Sprout tab's empty state would also tell them, but landing
            // them directly on Settings is faster.
            appEnv.requestedTab = .settings
            return
        }
        do {
            try await appEnv.assistant.presentSheet()
        } catch {
            appEnv.surfaceError(error)
        }
    }
}
