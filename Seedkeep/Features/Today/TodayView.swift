import SwiftUI
import SwiftData
import SeedkeepKit

/// Today: the daylight panel, the Due queue, and the newest journal entry since yesterday.
///
/// `todayString` / `yesterdayString` are held as `@State` here and
/// refreshed on `NSCalendarDayChanged` + foreground. The date-dependent
/// `@Query` predicates live in `TodayQueryView` (a child that takes the
/// strings as init params) so SwiftData rebuilds them when the dates
/// roll over — the parent can't re-init its own `@Query` without a re-init.
struct TodayView: View {
    @Environment(AppEnvironment.self) private var appEnv

    /// The workbench's model when the regular-width shell hosts Today. Nil in the compact tab shell, where
    /// Open Garden switches the tab instead.
    private let workbench: WorkbenchModel?

    /// Drives the "Set home location" sheet from the daylight empty state.
    @State private var showHomeLocationSheet: Bool = false

    /// Date strings used as @Query predicate keys. Refreshed at midnight
    /// (NSCalendarDayChanged) and on foreground resume so the due-events
    /// list stays current without restarting the app.
    @State private var todayString: String = Self.currentTodayString()
    @State private var yesterdayString: String = Self.currentYesterdayString()

    private static func makeDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    static func currentTodayString() -> String {
        makeDateFormatter().string(from: Date())
    }

    static func currentYesterdayString() -> String {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return makeDateFormatter().string(from: yesterday)
    }

    init(workbench: WorkbenchModel? = nil) {
        self.workbench = workbench
    }

    private func refreshDateStrings() {
        todayString = Self.currentTodayString()
        yesterdayString = Self.currentYesterdayString()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WBScreenBackground()
                ScrollView {
                    TodayQueryView(
                        todayString: todayString,
                        yesterdayString: yesterdayString,
                        showHomeLocationSheet: $showHomeLocationSheet,
                        workbench: workbench
                    )
                }
            }
            .navigationTitle("")
            .publishesAssistantContext(pageType: "today")
            .navigationDestination(for: PetDetailDestination.self) { dest in
                PetDetailView(plantingEventID: dest.plantingEventID)
            }
            .sheet(isPresented: $showHomeLocationSheet) {
                NavigationStack {
                    HomeLocationSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showHomeLocationSheet = false }
                            }
                        }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                refreshDateStrings()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: PlatformLifecycle.willEnterForeground)) { _ in
                refreshDateStrings()
            }
        }
    }
}

enum TodayHouseholdScope {
    static func events(_ rows: [LocalPlantingEvent], householdID: String) -> [LocalPlantingEvent] {
        rows.filter { $0.householdID == householdID }
    }

    static func seeds(_ rows: [LocalSeed], householdID: String) -> [LocalSeed] {
        rows.filter { $0.householdID == householdID }
    }

    static func journals(_ rows: [LocalJournalEntry], householdID: String) -> [LocalJournalEntry] {
        rows.filter { $0.householdID == householdID }
    }

    static func departures(
        _ rows: [LocalPetDeparture],
        belongingTo events: [LocalPlantingEvent],
        householdID: String
    ) -> [LocalPetDeparture] {
        let eventIDs = Set(events.filter { $0.householdID == householdID }.map(\.id))
        return rows.filter { $0.deletedAt == nil && eventIDs.contains($0.plantingEventID) }
    }
}

// MARK: - TodayQueryView (date-bucketed child)

/// Child view that holds the date-dependent `@Query` predicates.
/// Re-initialised by `TodayView` whenever `todayString` / `yesterdayString`
/// change, which rebuilds the queries and updates the UI at midnight.
private struct TodayQueryView: View {
    @Environment(AppEnvironment.self) private var appEnv

    /// Today's + overdue events (deletedAt nil, completedAt nil, planned for today or earlier)
    @Query private var dueEvents: [LocalPlantingEvent]
    /// Recent journal entries for the Journal section.
    @Query private var recentJournal: [LocalJournalEntry]
    /// Active seeds for pulling the seed name on a planting event.
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var seeds: [LocalSeed]
    /// Live pets for the Garden roll-call strip.
    @Query private var liveCandidates: [LocalPlantingEvent]
    /// Departure rows are excluded from the strip.
    @Query private var departures: [LocalPetDeparture]

    @Binding var showHomeLocationSheet: Bool

    /// The workbench's model when the regular-width shell hosts Today; nil in the compact tab shell.
    private let workbench: WorkbenchModel?

    /// The `yyyy-MM-dd` day the queries were built for. Due-row day labels are measured from it.
    private let today: String

    private var activeSeeds: [LocalSeed] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return TodayHouseholdScope.seeds(seeds, householdID: householdID)
    }

    /// The Due queue: scoped to the active household, then cut to the first six rows.
    private var queue: [LocalPlantingEvent] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return TodayDue.queue(dueEvents, householdID: householdID, today: today)
    }

    private var activeLiveCandidates: [LocalPlantingEvent] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return TodayHouseholdScope.events(liveCandidates, householdID: householdID)
    }

    private var activeDepartures: [LocalPetDeparture] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return TodayHouseholdScope.departures(
            departures,
            belongingTo: activeLiveCandidates,
            householdID: householdID
        )
    }

    private var activeRecentJournal: [LocalJournalEntry] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return TodayHouseholdScope.journals(recentJournal, householdID: householdID)
    }

    init(
        todayString: String,
        yesterdayString: String,
        showHomeLocationSheet: Binding<Bool>,
        workbench: WorkbenchModel?
    ) {
        let today = todayString
        let yesterday = yesterdayString
        self.today = today
        self.workbench = workbench
        _dueEvents = Query(
            filter: #Predicate<LocalPlantingEvent> { event in
                event.deletedAt == nil
                && event.completedAt == nil
                && event.plannedFor <= today
            },
            sort: \.plannedFor,
            order: .forward)
        _recentJournal = Query(
            filter: #Predicate<LocalJournalEntry> { entry in
                entry.deletedAt == nil
                && entry.occurredOn >= yesterday
            },
            sort: \.occurredOn,
            order: .reverse)
        _liveCandidates = Query(
            filter: #Predicate<LocalPlantingEvent> { event in
                event.deletedAt == nil && event.completedAt == nil
            })
        _showHomeLocationSheet = showHomeLocationSheet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WBMetrics.gapLarge * 2) {
            WBScreenTitle("Today", subtitle: scholarlyDate)
                .padding(.top, WBMetrics.gapLarge)

            frostBanner

            daylightBlock
                .padding(.horizontal, WBMetrics.screenGutter)

            gardenRollCallBlock
                .padding(.horizontal, WBMetrics.screenGutter)

            dueBlock

            if let marginEntry {
                journalBlock(entry: marginEntry)
                    .padding(.horizontal, WBMetrics.screenGutter)
            }

            Color.clear.frame(height: 80)
        }
    }

    // MARK: - Garden roll-call (Phase 5.1.3)

    /// Live pets (alive/wilted/departing) excluding ones with a departure
    /// row. Sorted by mood-label ascending so wilted/departing surface
    /// first; stable tiebreak by createdAt ascending.
    @MainActor
    private var livePets: [LocalPlantingEvent] {
        let depIDs = Set(activeDepartures.map { $0.plantingEventID })
        return activeLiveCandidates
            .filter { $0.petSeed != nil && !depIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let lr = moodRank(lhs.petMoodLabel)
                let rr = moodRank(rhs.petMoodLabel)
                if lr != rr { return lr < rr }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private func moodRank(_ label: PetMoodLabel) -> Int {
        switch label {
        case .departingImminent: return 0
        case .wilted:            return 1
        case .quiet:             return 2
        case .content:           return 3
        case .thriving:          return 4
        }
    }

    @ViewBuilder
    private var gardenRollCallBlock: some View {
        let pets = livePets
        if FeatureFlags.plantPetsEnabled, !pets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Rubric(text: "garden roll-call")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pets) { pet in
                            NavigationLink(value: PetDetailDestination(plantingEventID: pet.id)) {
                                PetCard(pet: pet, variant: .rollCall)
                                    .frame(width: 64)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var scholarlyDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - Frost

    private var host: TodayFrost.Host {
        workbench == nil ? .compactTab : .workbenchRoute
    }

    /// The live plantings from today through the next 13 days that a frost check flags, for this household.
    private var frostWarningCount: Int {
        guard let householdID = appEnv.activeGardenHouseholdID else { return 0 }
        return TodayFrost.warningCount(
            events: liveCandidates,
            seeds: activeSeeds,
            householdID: householdID,
            climate: appEnv.preferences.homeClimate,
            // The same day the Due section uses, so the banner and the list never disagree.
            today: CalendarDay.parse(today) ?? CalendarDay.today()
        )
    }

    @ViewBuilder
    private var frostBanner: some View {
        let count = frostWarningCount
        if count > 0 {
            WBBanner(
                severity: .warning,
                title: TodayFrost.warningTitle(count: count),
                action: (label: TodayFrost.openGardenLabel, handler: openGarden)
            )
            .accessibilityIdentifier("today.frostBanner")
            .padding(.horizontal, WBMetrics.screenGutter)
        }
    }

    /// Switches to Garden from the host shell: the compact tab's `requestedTab`, or the workbench's route.
    private func openGarden() {
        switch TodayFrost.GardenRoute.route(for: host) {
        case .gardenTab:
            appEnv.requestedTab = .garden
        case .gardenRoute:
            workbench?.route = .garden
        }
    }

    // MARK: - Daylight

    /// Home coordinates from the cached preferences; nil until a home location is set.
    private var cachedHome: (latitude: Double, longitude: Double)? {
        guard
            let lat = appEnv.preferences.cachedLatitude,
            let lon = appEnv.preferences.cachedLongitude
        else { return nil }
        return (lat, lon)
    }

    @ViewBuilder
    private var daylightBlock: some View {
        if let home = cachedHome {
            if let dayLight = Solar.dayLight(latitude: home.latitude, longitude: home.longitude, on: Date()) {
                WBDaylightPanel(sunrise: dayLight.sunrise, sunset: dayLight.sunset, now: Date())
            } else {
                // Polar day or night: there is a home location, so don't ask for one.
                Text("No sunrise or sunset at your home location today.")
                    .font(.wbCallout)
                    .foregroundStyle(WBColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .wbPanel()
            }
        } else {
            VStack(alignment: .leading, spacing: WBMetrics.gap) {
                Text("Set a home location to see today's daylight.")
                    .font(.wbCallout)
                    .foregroundStyle(WBColor.muted)
                Button {
                    showHomeLocationSheet = true
                } label: {
                    Text("Set home location")
                        .frame(minHeight: WBMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .tint(WBColor.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .wbPanel()
        }
    }

    // MARK: - Due

    @ViewBuilder
    private var dueBlock: some View {
        VStack(alignment: .leading, spacing: WBMetrics.gap) {
            WBSectionHeader("Due")

            if queue.isEmpty {
                if appEnv.isSyncingForDisplay {
                    ProgressView("Syncing…")
                        .tint(WBColor.accent)
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    Text("Nothing due.")
                        .font(.wbCallout)
                        .foregroundStyle(WBColor.muted)
                        .padding(.vertical, WBMetrics.gapLarge)
                }
            } else {
                ForEach(queue) { event in
                    DueRow(
                        event: event,
                        seed: seed(for: event),
                        today: today,
                        climate: appEnv.preferences.homeClimate
                    )
                }
            }
        }
        .padding(.horizontal, WBMetrics.screenGutter)
    }

    private func seed(for event: LocalPlantingEvent) -> LocalSeed? {
        guard let seedID = event.seedID else { return nil }
        return activeSeeds.first { $0.id == seedID }
    }

    // MARK: - Journal

    @ViewBuilder
    private func journalBlock(entry: LocalJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: WBMetrics.gap) {
            WBSectionHeader("Journal")
            Text(entry.body.isEmpty ? "—" : entry.body)
                .font(.wbBody)
                .foregroundStyle(WBColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wbPanel()
        }
    }

    private var marginEntry: LocalJournalEntry? {
        guard let householdID = appEnv.activeGardenHouseholdID else { return nil }
        return activeRecentJournal.first { $0.householdID == householdID }
    }
}

// MARK: - Due row

private struct DueRow: View {
    let event: LocalPlantingEvent
    let seed: LocalSeed?
    let today: String
    let climate: HomeClimate?

    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 13
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var name: String {
        seed?.displayName ?? "Untitled seed"
    }

    private var kind: String {
        TodayDue.kindLabel(event.kindRaw)
    }

    private var offset: Int {
        TodayDue.dayOffset(plannedFor: event.plannedFor, today: today)
    }

    private var dayLabel: String {
        TodayDue.dayLabel(offset: offset)
    }

    /// A frost-flagged row shows the frost glyph and says "frost risk" to VoiceOver.
    private var frostRisk: Bool {
        FrostCheck.check(event, seed: seed, climate: climate).isFlagged
    }

    var body: some View {
        // At accessibility sizes the day label goes under the name; beside it, both break mid-word.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WBMetrics.gap))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: WBMetrics.gapLarge))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.wbBody)
                    .foregroundStyle(WBColor.ink)
                Text(TodayDue.rowSubtitle(kind: kind, type: seed?.customType))
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
            }

            if !stacked {
                Spacer(minLength: WBMetrics.gap)
            }

            HStack(spacing: 4) {
                if offset < 0 {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: iconSize))
                        .foregroundStyle(WBColor.warn)
                        .accessibilityHidden(true)
                }
                if frostRisk {
                    Image(systemName: "snowflake")
                        .font(.system(size: iconSize))
                        .foregroundStyle(WBColor.warn)
                        .accessibilityHidden(true)
                }
                Text(dayLabel)
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WBMetrics.gapLarge)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WBColor.line)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            TodayDue.rowAccessibilityLabel(name: name, kind: kind, dayLabel: dayLabel, frostRisk: frostRisk)
        )
    }
}
