import SwiftUI

/// Lets the user pick which AI extraction path they want for new seeds.
/// Free and BYOK remain available on this device. Hosted is shown only
/// while its server-backed subscription service is available.
struct AIProviderSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var refreshing = false

    var body: some View {
        Form {
            Section {
                ForEach(availableProviders) { provider in
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

            if !ServerRetirement.isRetired && AppPreferences.isHostedTierEnabled {
                Section {
                    LabeledContent("Server-reported tier") {
                        Text(appEnv.preferences.cachedTier ?? "(unknown)")
                            .foregroundStyle(WBColor.muted)
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack {
                            Label("Refresh from server", systemImage: "arrow.clockwise")
                            if refreshing {
                                Spacer()
                                ProgressView().controlSize(.small).tint(WBColor.accent)
                            }
                        }
                    }
                    .disabled(refreshing)
                } header: {
                    WBSectionHeader("subscription")
                } footer: {
                    Text("Hosted requires an active subscription. The server records your purchase and reports it back here. Your local picker chooses your *preferred* extraction path; the server enforces what you can actually use.")
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                }

                if appEnv.preferences.aiProvider == .hosted &&
                   appEnv.preferences.cachedTier != "hosted" {
                    Section {
                        Label {
                            Text("You picked Hosted, but the server doesn't yet see an active subscription. Subscribe in the next step (or restore a previous purchase). Until then, extractions will fall back to on-device.")
                                .font(.wbCaption)
                                .foregroundStyle(WBColor.ink)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.wbCaption)
                                .foregroundStyle(WBColor.warn)
                        }
                    }
                }
            }
        }
        .wbForm()
        .accessibilityIdentifier("screen.aiProvider")
        .navigationTitle("AI provider")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if !ServerRetirement.isRetired && AppPreferences.isHostedTierEnabled {
                await refresh()
            }
        }
    }

    private var availableProviders: [AppPreferences.AIProvider] {
        AppPreferences.AIProvider.allCases.filter { provider in
            (!ServerRetirement.isRetired && AppPreferences.isHostedTierEnabled)
                || provider != .hosted
        }
    }

    private func refresh() async {
        guard !ServerRetirement.isRetired else { return }
        refreshing = true
        defer { refreshing = false }
        await appEnv.refreshTier()
    }
}
