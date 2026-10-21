import SwiftUI
import SwiftData
import SeedkeepKit

/// Stack-less content view for Settings. The host (the Settings tab or the Workbench `.settings`
/// route) wraps it in a `NavigationStack`; every `NavigationLink` pushes onto that stack.
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
    @AppStorage(AppAppearance.storageKey, store: DevicePreferences.store) private var storedAppearance: String = AppAppearance.system.rawValue
    @Query(filter: #Predicate<LocalJournalRecoveryItem> { $0.status == "pending" })
    private var pendingRecoveryItems: [LocalJournalRecoveryItem]

    @ViewBuilder private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(WBColor.muted)
            Spacer()
            Text(value).foregroundStyle(WBColor.ink)
        }
        .font(.wbFootnote)
    }

    /// An error message. The text is `ink`; the warning icon carries the status colour.
    private func errorRow(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.wbFootnote)
                .foregroundStyle(WBColor.ink)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(WBColor.warn)
        }
    }

    var body: some View {
        Form {
            if case .signedIn(_, let household) = auth.state {
                Section {
                    // N1: the iCloud account is the identity; there is no Seedkeep account.
                    LabeledContent("Account") {
                        Text("iCloud account")
                            .font(.wbBody)
                            .foregroundStyle(WBColor.ink)
                    }
                    LabeledContent("Your household") {
                        Text(household.name)
                            .font(.wbBody)
                            .foregroundStyle(WBColor.ink)
                    }
                    LabeledContent("Household ID") {
                        Text(household.id)
                            .font(.wbMonoCaption)
                            .foregroundStyle(WBColor.muted)
                    }
                } header: {
                    WBSectionHeader("Account")
                }
            }

            Section {
                // Through `resolve`, so an unknown stored value shows as System, which is what applies.
                Picker("Appearance", selection: Binding(
                    get: { AppAppearance.resolve(storedAppearance) },
                    set: { storedAppearance = $0.rawValue }
                )) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            } header: {
                WBSectionHeader("Appearance")
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
                WBSectionHeader("Seeds")
            }

            Section {
                NavigationLink {
                    HomeLocationSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Home location", systemImage: "location")
                        Text(homeLocationSummary)
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.muted)
                    }
                }
                NavigationLink {
                    NotificationsSettingsView()
                } label: {
                    Label("Notifications", systemImage: "bell")
                }
            } header: {
                WBSectionHeader("Home and alerts")
            }

            if !ServerRetirement.isRetired {
                Section {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Server", systemImage: "server.rack")
                            Text(appEnv.preferences.effectiveServerURL.absoluteString)
                                .font(.wbMonoCaption)
                                .foregroundStyle(WBColor.muted)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    WBSectionHeader("Server")
                }
            }

            Section {
                NavigationLink {
                    AIProviderSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("AI provider", systemImage: "sparkles")
                        Text(appEnv.preferences.aiProvider.displayName)
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.muted)
                    }
                }
                NavigationLink {
                    APIKeysSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("API keys", systemImage: "key.fill")
                        Text(apiKeysStatusText)
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.muted)
                    }
                }
                if !ServerRetirement.isRetired && AppPreferences.isHostedTierEnabled {
                    NavigationLink {
                        SubscriptionSettingsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Subscription", systemImage: "creditcard")
                            Text(subscriptionStatusText)
                                .font(.wbCaption)
                                .foregroundStyle(WBColor.muted)
                        }
                    }
                }
            } header: {
                WBSectionHeader("AI")
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
                        // N1: with CloudKit on, only a completed CloudKit pass counts; none
                        // runs while paused (`cloudKit` is nil then).
                        let cloudKitClean = !FeatureFlags.cloudKitHouseholdSyncEnabled
                            || (appEnv.cloudKit.map { $0.lastPassCompleted && $0.lastHumanizedError == nil } ?? false)
                        let clean = appEnv.sync.lastError == nil && cloudKitClean
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
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(WBColor.accent)
                        }
                    }
                }
                .disabled(isSyncingNow)
                if let err = appEnv.sync.lastError {
                    errorRow(err)
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
                            errorRow("CloudKit: \(err)")
                        }
                        if let detail = ck.lastErrorDetail {
                            Text(detail)
                                .font(.wbCaption)
                                .foregroundStyle(WBColor.muted)
                        }
                    } else if let reason = appEnv.cloudKitPauseReason {
                        Text("iCloud sync is paused — \(reason).")
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                    } else {
                        Text("CloudKit sync hasn’t run yet — tap “Sync now”.")
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
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
                        // N1: leaving needs a confirmed iCloud identity (CloudKit not paused).
                        .disabled(!appEnv.canUseCloudKit)
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
                WBSectionHeader("Sync")
            }

            if appEnv.pausedDeletionCheckpointCount > 0 {
                Section {
                    statusRow(
                        "Account deletion",
                        "\(appEnv.pausedDeletionCheckpointCount) pending checkpoint(s) paused"
                    )
                } header: {
                    WBSectionHeader("Diagnostics")
                }
            }

            Section {
                Button {
                    if let newest = ChangelogData.releases.map(\.build).max() {
                        WhatsNewGate.markSeen(build: newest, defaults: DevicePreferences.store)
                    }
                    showingWhatsNew = true
                } label: {
                    HStack {
                        Label("What's New", systemImage: "sparkles")
                        Spacer()
                        if whatsNewUnseen {
                            Circle().fill(WBColor.warn).frame(width: 8, height: 8)
                        }
                    }
                }

                Text("Data sources")
                    .font(.wbCaption.weight(.semibold))
                    .foregroundStyle(WBColor.muted)
                Text("USDA ARS Plant Hardiness Zone Map (2023)")
                    .font(.wbBody)
                    .foregroundStyle(WBColor.ink)
                Text("U.S. Census Bureau")
                    .font(.wbBody)
                    .foregroundStyle(WBColor.ink)
                Text("Frost dates estimated from the hardiness zone")
                    .font(.wbCaption)
                    .foregroundStyle(WBColor.muted)
                // App Review §5.1.1(i): the privacy policy must be reachable in the app.
                Link("Privacy Policy", destination: URL(string: "https://seedkeep.app/privacy")!)
                Link("Support", destination: URL(string: "https://seedkeep.app/support")!)
                if let versionText = SettingsText.versionText(version: AppInfo.currentVersion, build: AppInfo.currentBuild) {
                    Text(versionText)
                        .font(.wbMonoCaption)
                        .foregroundStyle(WBColor.muted)
                }
            } header: {
                WBSectionHeader("About")
            }
        }
        .wbForm()
        .navigationTitle("Settings")
        .publishesAssistantContext(pageType: "settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
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

    // MARK: - Helpers

    /// True when the newest authored release is newer than what the user has
    /// last opened — drives the small unseen dot on the What's New row.
    private var whatsNewUnseen: Bool {
        guard let newest = ChangelogData.releases.map(\.build).max() else { return false }
        return newest > (WhatsNewGate.lastSeenBuild(defaults: DevicePreferences.store) ?? .max)
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
