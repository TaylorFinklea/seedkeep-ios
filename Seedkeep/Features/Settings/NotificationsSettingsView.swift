import SwiftUI
import UserNotifications

/// Phase 4C · Settings → Notifications. Frost / heat / watering toggles
/// driven by `WeatherWarningsService`, plus the existing planting-event
/// + plant-pet toggles. Weather status renders from the actor's
/// `@Observable Projection.lastRefreshOutcome` — 13 outcome branches
/// per spec §8.
struct NotificationsSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.openURL) private var openURL

    // Phase 4C — three weather toggles. `frost` key preserved.
    @AppStorage("seedkeep.notif.frost") private var frostEnabled: Bool = false
    @AppStorage("seedkeep.notif.heat") private var heatEnabled: Bool = false
    @AppStorage("seedkeep.notif.water") private var waterEnabled: Bool = false

    @AppStorage("seedkeep.notif.events") private var eventsEnabled: Bool = false
    // Phase 4D — catalog correction outcomes. Default-on; new users
    // opt-in once they file their first suggestion. Disabling sweeps
    // pending + delivered pings (see `clearAllCatalogCorrectionPings`).
    @AppStorage("seedkeep.notif.catalog") private var catalogEnabled: Bool = true
    // Phase 5.1.4 — plant pets. All default-off per spec line 1250.
    @AppStorage("seedkeep.notif.pet.wilted") private var petWiltedEnabled: Bool = false
    @AppStorage("seedkeep.notif.pet.departed") private var petDepartedEnabled: Bool = false
    @AppStorage("seedkeep.notif.pet.roundup") private var petRoundupEnabled: Bool = false

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var refreshing: Bool = false

    private var weatherWatchVisible: Bool {
        frostEnabled || heatEnabled || waterEnabled
    }

    var body: some View {
        ZStack {
            VellumBackground()
            Form {
                Section {
                    permissionBanner
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 6, trailing: 20))
                        .listRowSeparator(.hidden)
                }

                Section {
                    Toggle(isOn: $frostEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Frost warnings", systemImage: "snowflake")
                            Text("8am the morning before any forecast low ≤ 33°F")
                                .font(HerbFont.bodyItalic(size: 11))
                                .foregroundStyle(HerbColor.inkSoft)
                        }
                    }
                    .onChange(of: frostEnabled) { _, newValue in
                        Task { await applyWeather(kind: .frost, enabled: newValue) }
                    }
                    Toggle(isOn: $heatEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Heat warnings", systemImage: "thermometer.sun")
                            Text("7pm the evening before a heat-index ≥ 100°F day or a 4+ day heatwave")
                                .font(HerbFont.bodyItalic(size: 11))
                                .foregroundStyle(HerbColor.inkSoft)
                        }
                    }
                    .onChange(of: heatEnabled) { _, newValue in
                        Task { await applyWeather(kind: .heat, enabled: newValue) }
                    }
                    Toggle(isOn: $waterEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Watering reminders", systemImage: "drop")
                            Text("8am after 5 dry days with no soaking rain in the 3-day forecast")
                                .font(HerbFont.bodyItalic(size: 11))
                                .foregroundStyle(HerbColor.inkSoft)
                        }
                    }
                    .onChange(of: waterEnabled) { _, newValue in
                        Task { await applyWeather(kind: .water, enabled: newValue) }
                    }
                    Toggle(isOn: $eventsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Planting reminders", systemImage: "calendar")
                            Text("7am on the morning of any planned planting event")
                                .font(HerbFont.bodyItalic(size: 11))
                                .foregroundStyle(HerbColor.inkSoft)
                        }
                    }
                    .onChange(of: eventsEnabled) { _, newValue in
                        Task { await applyEvents(enabled: newValue) }
                    }
                    Toggle(isOn: $catalogEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Correction outcomes", systemImage: "doc.text.magnifyingglass")
                            Text("When off, new corrections still appear in House → your contributions. Past notifications already on your lock screen aren't removed.")
                                .font(HerbFont.bodyItalic(size: 11))
                                .foregroundStyle(HerbColor.inkSoft)
                        }
                    }
                    .onChange(of: catalogEnabled) { _, newValue in
                        if !newValue {
                            Task { await NotificationsCenter.shared.clearAllCatalogCorrectionPings() }
                        }
                    }
                } header: {
                    Rubric(text: "what to notify")
                } footer: {
                    Text("All notifications are scheduled on-device. Seedkeep doesn't send anything through Apple's push servers.")
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkSoft)
                }

                if FeatureFlags.plantPetsEnabled {
                    Section {
                        Toggle(isOn: $petWiltedEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Wilting warnings", systemImage: "leaf")
                                Text("When a pet's mood drops to wilted")
                                    .font(HerbFont.bodyItalic(size: 11))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        }
                        .onChange(of: petWiltedEnabled) { _, newValue in
                            Task { await applyPetWilted(enabled: newValue) }
                        }
                        Toggle(isOn: $petDepartedEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Departure farewells", systemImage: "envelope.open")
                                Text("When a pet leaves with a goodbye note")
                                    .font(HerbFont.bodyItalic(size: 11))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        }
                        .onChange(of: petDepartedEnabled) { _, newValue in
                            Task { await applyPetDeparted(enabled: newValue) }
                        }
                        Toggle(isOn: $petRoundupEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Sunday roundup", systemImage: "calendar.badge.clock")
                                Text("Weekly summary of every companion's mood")
                                    .font(HerbFont.bodyItalic(size: 11))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                        }
                        .onChange(of: petRoundupEnabled) { _, newValue in
                            Task { await applyPetRoundup(enabled: newValue) }
                        }
                    } header: {
                        Rubric(text: "plant pets")
                    }
                }

                if weatherWatchVisible {
                    Section {
                        WarningStatusSection(
                            outcome: appEnv.weatherWarnings.projection.lastRefreshOutcome,
                            frostEnabled: frostEnabled,
                            heatEnabled: heatEnabled,
                            waterEnabled: waterEnabled,
                            openURL: openURL
                        )
                        Button {
                            Task { await manualRefresh() }
                        } label: {
                            HStack(spacing: 6) {
                                if refreshing {
                                    ProgressView().controlSize(.small).tint(HerbColor.sepia)
                                } else {
                                    Text("↻").foregroundStyle(HerbColor.sepia)
                                }
                                Text("Refresh forecast")
                                    .font(HerbFont.smallCaps(size: 10))
                                    .tracking(1.4)
                                    .foregroundStyle(HerbColor.sepia)
                                    .textCase(.uppercase)
                            }
                        }
                        .disabled(refreshing)
                    } header: {
                        Rubric(text: "weather watch")
                    } footer: {
                        // Apple WeatherKit attribution — App Store
                        // review requirement (spec §8).
                        Button {
                            if let url = URL(string: "https://weatherkit.apple.com/legal-attribution.html") {
                                openURL(url)
                            }
                        } label: {
                            Text("Weather")
                                .font(HerbFont.bodyItalic(size: 11))
                                .foregroundStyle(HerbColor.inkSoft)
                                .underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            authStatus = await NotificationsCenter.shared.authorizationStatus()
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch authStatus {
        case .denied:
            HerbBanner(
                severity: .warning,
                title: "Notifications blocked",
                message: "Enable in iOS Settings → Seedkeep → Notifications to use the switches below."
            )
            .padding(.vertical, 4)
        default:
            EmptyView()
        }
    }

    // MARK: - Toggle handlers

    private func applyWeather(kind: WarningKind, enabled: Bool) async {
        if enabled {
            _ = await NotificationsCenter.shared.requestAuthorization()
            _ = await appEnv.weatherWarnings.refreshAll(reason: .toggleEnable(kind))
        } else {
            await appEnv.weatherWarnings.clearKind(kind)
        }
        authStatus = await NotificationsCenter.shared.authorizationStatus()
    }

    private func applyEvents(enabled: Bool) async {
        // Events are scheduled when the event is created; we just need
        // permission. Toggling off cancels per-event when the user
        // completes or deletes — no bulk-purge here.
        if enabled {
            _ = await NotificationsCenter.shared.requestAuthorization()
        }
        authStatus = await NotificationsCenter.shared.authorizationStatus()
    }

    private func applyPetWilted(enabled: Bool) async {
        if enabled {
            _ = await NotificationsCenter.shared.requestAuthorization()
        } else {
            // Sweep any pending wilted notifications.
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier)
                .filter { $0.hasPrefix(NotificationsCenter.IdPrefix.petWilted) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        authStatus = await NotificationsCenter.shared.authorizationStatus()
    }

    private func applyPetDeparted(enabled: Bool) async {
        if enabled {
            _ = await NotificationsCenter.shared.requestAuthorization()
        } else {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier)
                .filter { $0.hasPrefix(NotificationsCenter.IdPrefix.petDeparted) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        authStatus = await NotificationsCenter.shared.authorizationStatus()
    }

    private func applyPetRoundup(enabled: Bool) async {
        if enabled {
            // Best-effort initial schedule with zero counts until the
            // next sync re-bakes the body.
            await NotificationsCenter.shared.schedulePetWeeklyRoundup(
                thrivingCount: 0, wiltingCount: 0
            )
        } else {
            NotificationsCenter.shared.clearPetWeeklyRoundup()
        }
        authStatus = await NotificationsCenter.shared.authorizationStatus()
    }

    private func manualRefresh() async {
        refreshing = true
        defer { refreshing = false }
        _ = await appEnv.weatherWarnings.refreshAll(reason: .manualRefresh)
    }
}

// MARK: - Status section

/// Renders one row per refresh-outcome case per spec §8. The view is
/// driven by `appEnv.weatherWarnings.projection.lastRefreshOutcome`,
/// which is `@Observable` so Settings reacts to every refresh.
private struct WarningStatusSection: View {
    let outcome: RefreshOutcome
    let frostEnabled: Bool
    let heatEnabled: Bool
    let waterEnabled: Bool
    let openURL: OpenURLAction

    var body: some View {
        switch outcome {
        case .success(let scheduledByKind, _):
            perKindRows(scheduledByKind: scheduledByKind)
        case .successNoWarnings(let perKindEmpty):
            perKindEmptyRows(perKindEmpty: perKindEmpty)
        case .missingLocation:
            errorRow(text: "Set a home location first (Settings → Home location).")
        case .noActivePlantings:
            mutedRow(text: "Nothing planted to watch over.")
        case .permissionDenied(let url):
            tappableRow(
                text: "Notifications are off for Seedkeep in iOS Settings.",
                color: HerbColor.rose,
                deepLink: url
            )
        case .provisionalDelivery:
            tappableRow(
                text: "Notifications deliver quietly — tap to allow alerts.",
                color: HerbColor.ochre,
                deepLink: nil
            )
        case .partialData(let validDays, _, let waterSuppressed):
            VStack(alignment: .leading, spacing: 4) {
                errorRow(text: partialDataMessage(validDays: validDays, waterSuppressed: waterSuppressed))
                if waterSuppressed {
                    mutedRow(text: "Water reminder collects 3 days of rain history before firing.")
                }
            }
        case .clockSkew:
            errorRow(text: "Device clock changed — rebuilding warnings.")
        case .weatherKitUnauthorized:
            errorRow(text: "Weather service unavailable for this build. Contact support.")
        case .weatherKitFailedUsingStale(let age):
            let hours = max(1, Int(age / 3600))
            errorRow(text: "Using a forecast from \(hours)h ago — couldn't reach WeatherKit just now.")
        case .weatherKitFailed:
            errorRow(text: "Couldn't reach the forecast. Tap refresh to try again.")
        case .allSchedulingFailed:
            errorRow(text: "Couldn't schedule warnings (system busy). Tap refresh to retry.")
        case .queueBudgetReachedWithDropped(let scheduledByKind, let dropped):
            VStack(alignment: .leading, spacing: 4) {
                perKindRows(scheduledByKind: scheduledByKind)
                mutedRow(text: "Watching the nearest warnings; \(dropped) further-out ones will schedule as nearer ones fire.")
            }
        }
    }

    @ViewBuilder
    private func perKindRows(scheduledByKind: [WarningKind: Int]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if frostEnabled {
                let count = scheduledByKind[.frost] ?? 0
                if count > 0 {
                    watchingRow(text: "Watching the forecast")
                } else {
                    mutedRow(text: "No frost in the next 10 days.")
                }
            }
            if heatEnabled {
                let count = scheduledByKind[.heat] ?? 0
                if count > 0 {
                    watchingRow(text: "Watching for heat")
                } else {
                    mutedRow(text: "Nothing dangerous in sight.")
                }
            }
            if waterEnabled {
                let count = scheduledByKind[.water] ?? 0
                if count > 0 {
                    watchingRow(text: "Watching for dry stretches")
                } else {
                    mutedRow(text: "No dry stretch in sight.")
                }
            }
        }
    }

    @ViewBuilder
    private func perKindEmptyRows(perKindEmpty: [WarningKind: Bool]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if frostEnabled {
                mutedRow(text: "No frost in the next 10 days.")
            }
            if heatEnabled {
                mutedRow(text: "Nothing dangerous in sight.")
            }
            if waterEnabled {
                mutedRow(text: "No dry stretch in sight.")
            }
            // Suppress unused-parameter warning while keeping the
            // dict in the API surface for future per-kind detail.
            let _ = perKindEmpty
        }
    }

    @ViewBuilder
    private func watchingRow(text: String) -> some View {
        HStack(spacing: 8) {
            Text("✓").foregroundStyle(HerbColor.verdictNow)
            Text(text)
                .font(HerbFont.bodyItalic(size: 13))
                .foregroundStyle(HerbColor.ink)
        }
    }

    @ViewBuilder
    private func mutedRow(text: String) -> some View {
        Text(text)
            .font(HerbFont.bodyItalic(size: 11))
            .foregroundStyle(HerbColor.inkSoft)
    }

    @ViewBuilder
    private func errorRow(text: String) -> some View {
        Text(text)
            .font(HerbFont.bodyItalic(size: 11))
            .foregroundStyle(HerbColor.rose)
    }

    @ViewBuilder
    private func tappableRow(text: String, color: Color, deepLink: URL?) -> some View {
        Button {
            if let deepLink {
                openURL(deepLink)
            }
        } label: {
            Text(text)
                .font(HerbFont.bodyItalic(size: 11))
                .foregroundStyle(color)
                .underline(deepLink != nil)
        }
        .buttonStyle(.plain)
        .disabled(deepLink == nil)
    }

    private func partialDataMessage(validDays: Int, waterSuppressed: Bool) -> String {
        let base = "Forecast was incomplete (\(validDays) days)."
        return waterSuppressed
            ? base + " Water reminder needs 3+ days — waiting for next refresh."
            : base
    }
}
