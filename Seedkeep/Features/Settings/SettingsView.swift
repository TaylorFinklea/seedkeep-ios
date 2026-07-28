import SwiftUI
import SwiftData
import SeedkeepKit

/// Stack-less content view for Settings — "The Order". Designed to be
/// embedded inside an existing `NavigationStack` (e.g. `YouView`). All
/// `NavigationLink`s push onto the host's stack; no inner stack is created.
///
/// `SettingsView` below is a thin standalone wrapper that adds its own
/// `NavigationStack` for any remaining direct-navigation uses.
struct SettingsContent: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AuthController.self) private var auth

    // R1 beta — CloudKit diagnostics
    @State private var iCloudStatus: String?
    @State private var checkingICloud = false
    @State private var isSyncingNow = false
    @State private var syncedJustNow = false
    @State private var syncToken = 0
    @State private var preparingShare = false
    // R1 27d.18 — participant journal recovery review inbox
    @State private var showingJournalRecoveryReview = false
    @State private var showingWhatsNew = false
    @Query(filter: #Predicate<LocalJournalRecoveryItem> { $0.status == "pending" })
    private var pendingRecoveryItems: [LocalJournalRecoveryItem]

    @ViewBuilder private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(HerbColor.inkFaint)
            Spacer()
            Text(value).foregroundStyle(HerbColor.ink)
        }
        .font(.footnote)
    }

    var body: some View {
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
                    Rubric(text: "inventory")
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
                    NavigationLink {
                        NotificationsSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                } header: {
                    Rubric(text: "garden")
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
                    Rubric(text: "backend")
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
                        Rubric(text: "household")
                    }
                }

                Section {
                    Button {
                        guard !isSyncingNow else { return }
                        isSyncingNow = true
                        syncedJustNow = false
                        syncToken += 1
                        let token = syncToken
                        Task {
                            await appEnv.syncIfPossible()
                            isSyncingNow = false
                            // Only show the success ✓ when the pass actually succeeded (no error
                            // surfaced on either path) — a green check next to an error banner lies.
                            let clean = appEnv.sync.lastError == nil && appEnv.cloudKit?.lastHumanizedError == nil
                            syncedJustNow = clean
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            if syncToken == token { syncedJustNow = false }   // don't clear a newer tap's ✓
                        }
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.clockwise")
                            Spacer()
                            if isSyncingNow {
                                ProgressView()
                            } else if syncedJustNow {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(HerbColor.sage)
                            }
                        }
                    }
                    .disabled(isSyncingNow)
                    if let err = appEnv.sync.lastError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(HerbColor.rose)
                    }
                    if FeatureFlags.cloudKitHouseholdSyncEnabled {
                        // Visible CloudKit status so the beta test isn't blind.
                        Button {
                            checkingICloud = true
                            Task {
                                let s = await HouseholdCloudCoordinator.currentAccountStatusText()
                                await MainActor.run { iCloudStatus = s; checkingICloud = false }
                            }
                        } label: {
                            Label(checkingICloud ? "Checking iCloud…" : "Check iCloud account", systemImage: "person.icloud")
                        }
                        .disabled(checkingICloud)
                        if let iCloudStatus {
                            statusRow("iCloud account", iCloudStatus)
                        }
                        if let ck = appEnv.cloudKit {
                            statusRow("Initial upload", ck.initialUploadComplete ? "complete" : "pending")
                            if ck.isSyncing { statusRow("CloudKit", "syncing…") }
                            if let at = ck.lastSyncedAt {
                                statusRow("Last CloudKit sync", at.formatted(date: .omitted, time: .standard))
                            }
                            statusRow("Records synced this session", "\(ck.zoneRecordCount)")
                            if let acct = ck.accountStatusText { statusRow("Account (at first sync)", acct) }
                            if let err = ck.lastHumanizedError {
                                Text("CloudKit: \(err)")
                                    .font(.footnote)
                                    .foregroundStyle(HerbColor.rose)
                            }
                            if let detail = ck.lastErrorDetail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(HerbColor.inkFaint)
                            }
                        } else {
                            Text("CloudKit sync hasn’t run yet — tap “Sync now”.")
                                .font(.footnote)
                                .foregroundStyle(HerbColor.inkFaint)
                        }

                        // Cross-account sharing (CloudKit). Owner shares the household zone via the
                        // system share sheet; a participant who has joined sees a Leave affordance.
                        if appEnv.isViewingSharedHousehold {
                            statusRow("Household", "shared with you")
                            if let scopeKey = appEnv.participantRecoveryScopeKey {
                                let scopedPendingCount = pendingRecoveryItems.filter { $0.scopeKey == scopeKey }.count
                                if scopedPendingCount > 0 {
                                    Button {
                                        showingJournalRecoveryReview = true
                                    } label: {
                                        Label("Journal items need review (\(scopedPendingCount))", systemImage: "tray.and.arrow.down")
                                    }
                                }
                            }
                            Button(role: .destructive) {
                                Task { await appEnv.leaveSharedHouseholdSurfacingErrors() }
                            } label: {
                                Label("Leave shared garden", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } else {
                            Button {
                                guard !preparingShare else { return }
                                preparingShare = true
                                Task {
                                    let pkg = await appEnv.prepareOwnerShare()
                                    preparingShare = false
                                    if let pkg {
                                        CloudSharingPresenter.present(share: pkg.share, container: pkg.container, title: "Seedkeep garden")
                                    }
                                }
                            } label: {
                                HStack {
                                    Label("Share garden via iCloud", systemImage: "person.crop.circle.badge.plus")
                                    Spacer()
                                    if preparingShare { ProgressView() }
                                }
                            }
                            .disabled(preparingShare)
                        }
                    }
                } header: {
                    Rubric(text: "sync")
                }

                Section {
                    Button {
                        if let newest = ChangelogData.releases.map(\.build).max() {
                            WhatsNewGate.markSeen(build: newest)
                        }
                        showingWhatsNew = true
                    } label: {
                        HStack {
                            Label("What's New", systemImage: "sparkles")
                            Spacer()
                            if whatsNewUnseen {
                                Circle().fill(HerbColor.rose).frame(width: 8, height: 8)
                            }
                        }
                    }
                } header: {
                    Rubric(text: "changelog")
                }

                Section {
                    Text("SEEDKEEP · BUILD \(buildRoman) · ANNO MMXXVI")
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
        .sheet(isPresented: $showingJournalRecoveryReview) {
            NavigationStack {
                JournalRecoveryReviewView()
            }
        }
        .sheet(isPresented: $showingWhatsNew) {
            if let latest = ChangelogData.releases.max(by: { $0.build < $1.build }) {
                WhatsNewSheet(initialRelease: latest)
            }
        }
    }

    // MARK: - Build stamp

    /// Reads `CFBundleVersion` (the build number set by `release.sh`) and
    /// converts it to Roman numerals for the footer stamp. Falls back to the
    /// raw Arabic number if the build value isn't an integer, and to "?" if
    /// the Info.plist entry is missing entirely — never crashes.
    private var buildRoman: String {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard let n = Int(raw), n > 0 else { return raw.isEmpty ? "?" : raw }
        return HerbRomanNumeral.string(for: n, lowercase: false)
    }

    /// True when the newest authored release is newer than what the user has
    /// last opened — drives the small unseen dot on the What's New row.
    private var whatsNewUnseen: Bool {
        guard let newest = ChangelogData.releases.map(\.build).max() else { return false }
        return newest > (WhatsNewGate.lastSeenBuild() ?? .max)
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

}

/// Thin standalone wrapper — adds a `NavigationStack` around `SettingsContent`
/// for any direct-navigation use (e.g. previews, deep-link entry points).
/// When `SettingsContent` is embedded in `YouView`'s existing stack, use
/// `SettingsContent` directly to avoid a double navigation bar.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            SettingsContent()
        }
    }
}
