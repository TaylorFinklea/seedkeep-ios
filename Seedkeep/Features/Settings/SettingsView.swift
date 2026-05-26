import SwiftUI
import SeedkeepKit

/// Root Settings tab — restyled as "The Order".
///
/// Hosts inventory, garden, sprout, backend, household, and sync
/// subsections, all rendered in the herbarium aesthetic: vellum
/// background, scholarly italic title, Rubric-styled section headers
/// with Roman numerals.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AuthController.self) private var auth

    @State private var inviteCode: String?
    @State private var isCreatingInvite = false
    @State private var inviteError: String?

    /// New preference: hide the bottom-right Sprout FAB on every primary
    /// page. The FAB is the popup-assistant entry point; users who don't
    /// use Sprout can reclaim that corner.
    @AppStorage("seedkeep.sparkleOnEveryPage") private var sparkleOnEveryPage: Bool = true

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                Form {
                    Section {
                        herbHero
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }

                    Section {
                        NavigationLink {
                            LocationsView()
                        } label: {
                            Label("Locations", systemImage: "tray")
                        }
                        NavigationLink {
                            TagsView()
                        } label: {
                            Label("Tags", systemImage: "tag")
                        }
                    } header: {
                        Rubric(text: "inventory", number: 1)
                    }

                    Section {
                        NavigationLink {
                            HomeLocationSettingsView()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Home location", systemImage: "location")
                                Text(homeLocationSummary)
                                    .font(HerbFont.bodyItalic(size: 12))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        }
                    } header: {
                        Rubric(text: "garden", number: 2)
                    }

                    Section {
                        NavigationLink {
                            AssistantKeySettingsView()
                        } label: {
                            Label("AI assistant key", systemImage: "sparkles")
                        }
                        Toggle(isOn: $sparkleOnEveryPage) {
                            Label("Sparkle on every page", systemImage: "wand.and.stars")
                        }
                    } header: {
                        Rubric(text: "sprout · the scribe", number: 3)
                    } footer: {
                        Text("When on, a sparkle button sits in the bottom-right of every primary page and opens Sprout with the current page's context attached.")
                            .font(HerbFont.bodyItalic(size: 11))
                            .foregroundStyle(HerbColor.inkSoft)
                    }

                    Section {
                        NavigationLink {
                            ServerSettingsView()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Server", systemImage: "server.rack")
                                Text(appEnv.preferences.effectiveServerURL.absoluteString)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(HerbColor.inkSoft)
                                    .lineLimit(1)
                            }
                        }
                        NavigationLink {
                            AIProviderSettingsView()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("AI provider", systemImage: "sparkles")
                                Text(appEnv.preferences.aiProvider.displayName)
                                    .font(HerbFont.bodyItalic(size: 12))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        }
                        NavigationLink {
                            APIKeysSettingsView()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("API keys", systemImage: "key.fill")
                                Text(apiKeysStatusText)
                                    .font(HerbFont.bodyItalic(size: 12))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        }
                        if AppPreferences.isHostedTierEnabled {
                            NavigationLink {
                                SubscriptionSettingsView()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label("Subscription", systemImage: "creditcard")
                                    Text(subscriptionStatusText)
                                        .font(HerbFont.bodyItalic(size: 12))
                                        .foregroundStyle(HerbColor.inkSoft)
                                }
                            }
                        }
                    } header: {
                        Rubric(text: "backend", number: 4)
                    }

                    if case .signedIn(_, let household) = auth.state {
                        Section {
                            LabeledContent("Name", value: household.name)
                            LabeledContent("ID") {
                                Text(household.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        } header: {
                            Rubric(text: "household", number: 5)
                        }
                        Section {
                            if let code = inviteCode {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Share this code")
                                        .font(HerbFont.smallCaps(size: 10))
                                        .tracking(1.5)
                                        .foregroundStyle(HerbColor.sepia)
                                    Text(code)
                                        .font(.title3.monospaced())
                                        .textSelection(.enabled)
                                }
                            } else {
                                Button {
                                    Task { await createInvite() }
                                } label: {
                                    HStack {
                                        Text("Create invite link")
                                        if isCreatingInvite { ProgressView().controlSize(.small) }
                                    }
                                }
                                .disabled(isCreatingInvite)
                            }
                            if let inviteError {
                                Text(inviteError)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        } header: {
                            Rubric(text: "invite", number: 6)
                        }
                    }

                    Section {
                        Button {
                            Task { await appEnv.syncIfPossible() }
                        } label: {
                            Label("Sync now", systemImage: "arrow.clockwise")
                        }
                        if let err = appEnv.sync.lastError {
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        NavigationLink {
                            PendingWritesView()
                        } label: {
                            Label("Pending writes", systemImage: "tray.full")
                        }
                    } header: {
                        Rubric(text: "sync", number: 7)
                    }

                    Section {
                        Text("SEEDKEEP · BUILD XXIII · ANNO MMXXVI")
                            .font(HerbFont.smallCaps(size: 8))
                            .tracking(1.5)
                            .foregroundStyle(HerbColor.inkFaint)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Hero block

    @ViewBuilder
    private var herbHero: some View {
        VStack(alignment: .leading, spacing: 6) {
            FolioStrip(section: "Order", folio: 1)
                .padding(.horizontal, -16)

            VStack(alignment: .leading, spacing: 4) {
                Text("The Order")
                    .font(HerbFont.display(size: 38))
                    .foregroundStyle(HerbColor.ink)
                Text(orderSubtitle)
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            ScholarRule(verticalMargin: 8)
        }
    }

    private var orderSubtitle: String {
        if case .signedIn(_, let household) = auth.state {
            let zip = appEnv.preferences.homeZip ?? ""
            let suffix = zip.isEmpty ? "" : " · \(zip)"
            return "House of \(household.name)\(suffix)"
        }
        return "House awaiting steward"
    }

    private var homeLocationSummary: String {
        switch (appEnv.preferences.homeZip, appEnv.preferences.cachedUsdaZone) {
        case (let zip?, let zone?):
            return "\(zip) · Zone \(zone)"
        case (let zip?, nil):
            return zip
        default:
            return "Not set"
        }
    }

    private var apiKeysStatusText: String {
        if let provider = appEnv.apiKeys.preferredProvider() {
            return "\(provider.displayName) configured"
        }
        return "None configured"
    }

    private var subscriptionStatusText: String {
        appEnv.preferences.cachedTier ?? "Tap to view"
    }

    private func createInvite() async {
        isCreatingInvite = true
        inviteError = nil
        defer { isCreatingInvite = false }
        do {
            let res = try await appEnv.client.createInvite()
            inviteCode = res.invite.code
        } catch let err as SeedkeepError {
            inviteError = "\(err.code): \(err.message)"
        } catch {
            inviteError = error.localizedDescription
        }
    }
}
