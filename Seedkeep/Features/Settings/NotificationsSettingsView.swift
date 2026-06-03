import SwiftUI
import UserNotifications

/// Phase 4 C · Settings → Notifications. Two toggles wired to local
/// scheduling: frost warnings (10-day WeatherKit forecast) and
/// planting-event reminders (scheduled at event-create time).
struct NotificationsSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @AppStorage("seedkeep.notif.frost") private var frostEnabled: Bool = false
    @AppStorage("seedkeep.notif.events") private var eventsEnabled: Bool = false
    // Phase 5.1.4 — plant pets. All default-off per spec line 1250.
    @AppStorage("seedkeep.notif.pet.wilted") private var petWiltedEnabled: Bool = false
    @AppStorage("seedkeep.notif.pet.departed") private var petDepartedEnabled: Bool = false
    @AppStorage("seedkeep.notif.pet.roundup") private var petRoundupEnabled: Bool = false

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var hasFrostScheduled: Bool = false
    @State private var refreshing: Bool = false
    @State private var refreshError: String?

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
                        Task { await applyFrost(enabled: newValue) }
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
                } header: {
                    Rubric(text: "what to notify")
                } footer: {
                    Text("All notifications are scheduled on-device. Seedkeep doesn't send anything through Apple's push servers.")
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkSoft)
                }

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

                if frostEnabled {
                    Section {
                        if hasFrostScheduled {
                            HStack(spacing: 8) {
                                Text("✓").foregroundStyle(HerbColor.verdictNow)
                                Text("Watching the forecast")
                                    .font(HerbFont.bodyItalic(size: 13))
                                    .foregroundStyle(HerbColor.ink)
                            }
                        } else {
                            Text("No frost in the next 10 days.")
                                .font(HerbFont.bodyItalic(size: 13))
                                .foregroundStyle(HerbColor.inkSoft)
                        }
                        Button {
                            Task { await refresh() }
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
                        if let refreshError {
                            Text(refreshError)
                                .font(HerbFont.bodyItalic(size: 11))
                                .foregroundStyle(HerbColor.rose)
                        }
                    } header: {
                        Rubric(text: "frost watch")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            authStatus = await NotificationsCenter.shared.authorizationStatus()
            hasFrostScheduled = await NotificationsCenter.shared.hasScheduledFrostWarnings()
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch authStatus {
        case .denied:
            HStack(alignment: .top, spacing: 10) {
                Text("⚠")
                    .font(.system(size: 14))
                    .foregroundStyle(HerbColor.ochre)
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOTIFICATIONS BLOCKED")
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.5)
                        .foregroundStyle(HerbColor.ink)
                    Text("Enable in iOS Settings → Seedkeep → Notifications to use the switches below.")
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkSoft)
                }
            }
            .padding(.vertical, 4)
        default:
            EmptyView()
        }
    }

    private func applyFrost(enabled: Bool) async {
        if enabled {
            await refresh()
        } else {
            await NotificationsCenter.shared.clearFrostWarnings()
            hasFrostScheduled = false
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

    private func refresh() async {
        guard let lat = appEnv.preferences.cachedLatitude,
              let lon = appEnv.preferences.cachedLongitude else {
            refreshError = "Set a home location first (Settings → Home location)."
            return
        }
        refreshing = true
        refreshError = nil
        defer { refreshing = false }
        await NotificationsCenter.shared.refreshFrostWarnings(latitude: lat, longitude: lon)
        hasFrostScheduled = await NotificationsCenter.shared.hasScheduledFrostWarnings()
    }
}
