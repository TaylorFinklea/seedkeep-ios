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
                    Button {
                        appEnv.preferences.aiProvider = provider
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: appEnv.preferences.aiProvider == provider
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(.tint)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.displayName)
                                    .font(HerbFont.body(size: 14))
                                    .foregroundStyle(HerbColor.ink)
                                Text(provider.helpText)
                                    .font(HerbFont.bodyItalic(size: 12))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Rubric(text: "provider")
            }

            if !ServerRetirement.isRetired && AppPreferences.isHostedTierEnabled {
                Section {
                    LabeledContent("Server-reported tier") {
                        Text(appEnv.preferences.cachedTier ?? "(unknown)")
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack {
                            Label("Refresh from server", systemImage: "arrow.clockwise")
                            if refreshing {
                                Spacer()
                                ProgressView().controlSize(.small).herbProgressStyle()
                            }
                        }
                    }
                    .disabled(refreshing)
                } header: {
                    Rubric(text: "subscription")
                } footer: {
                    Text("Hosted requires an active subscription. The server records your purchase and reports it back here. Your local picker chooses your *preferred* extraction path; the server enforces what you can actually use.")
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkSoft)
                }

                if appEnv.preferences.aiProvider == .hosted &&
                   appEnv.preferences.cachedTier != "hosted" {
                    Section {
                        Label {
                            Text("You picked Hosted, but the server doesn't yet see an active subscription. Subscribe in the next step (or restore a previous purchase). Until then, extractions will fall back to on-device.")
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.inkSoft)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(HerbColor.ochre)
                        }
                    }
                }
            }
        }
        .vellumForm()
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
