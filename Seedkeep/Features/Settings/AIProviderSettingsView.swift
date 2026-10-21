import SwiftUI

/// Lets the user pick which AI extraction path they want for new seeds: on-device (Free) or their
/// own key (BYOK). Hosted needs the retired server, so it isn't offered. A stored Hosted choice
/// reads as Free (see `AppPreferences`).
struct AIProviderSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        Form {
            Section {
                ForEach(SettingsPolicy.selectableAIProviders()) { provider in
                    let selected = appEnv.preferences.aiProvider == provider
                    Button {
                        appEnv.preferences.aiProvider = provider
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selected
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(.tint)
                                .padding(.top, 2)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.displayName)
                                    .font(.wbBody)
                                    .foregroundStyle(WBColor.ink)
                                Text(provider.helpText)
                                    .font(.wbCaption)
                                    .foregroundStyle(WBColor.muted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            } header: {
                WBSectionHeader("provider")
            }
        }
        .wbForm()
        .accessibilityIdentifier("screen.aiProvider")
        .navigationTitle("AI provider")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
