import SwiftUI
import SwiftData

enum JournalDatePresentation {
    static func parts(
        for ymd: String,
        timeZone: TimeZone
    ) -> (monthAbbrev: String, day: Int, year: String) {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        guard let date = parser.date(from: ymd) else { return ("MAY", 1, "2026") }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.day, .year], from: date)

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.timeZone = timeZone
        return (
            monthFormatter.string(from: date).uppercased(with: Locale(identifier: "en_US_POSIX")),
            components.day ?? 1,
            String(components.year ?? 2026)
        )
    }

    static func accessibleDate(
        for ymd: String,
        timeZone: TimeZone,
        locale: Locale = .current
    ) -> String {
        format(ymd, dateStyle: .long, timeZone: timeZone, locale: locale)
    }

    /// The locale's abbreviated date, e.g. "Oct 20, 2026" in English.
    static func abbreviatedDate(
        for ymd: String,
        timeZone: TimeZone,
        locale: Locale = .current
    ) -> String {
        format(ymd, dateStyle: .medium, timeZone: timeZone, locale: locale)
    }

    private static func format(
        _ ymd: String,
        dateStyle: DateFormatter.Style,
        timeZone: TimeZone,
        locale: Locale
    ) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        guard let date = parser.date(from: ymd) else { return ymd }

        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .none
        formatter.locale = locale
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

/// Top-level Journal tab. Read-only feed of `LocalJournalEntry` rows
/// reverse-sorted by `occurredOn`. Pull-to-refresh calls
/// `JournalStore.refresh()`. Rows + the toolbar "+" both push into
/// `JournalEntryView`.
///
/// `filterParent` is the starting filter, from `EntityScopedJournalSection`'s
/// "See all" link. The feed can then be searched, and the filter changed or
/// cleared. A new entry started with a filter pre-fills that parent.
struct JournalView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Route: Hashable {
        case existing(String)    // entry id
        case new(JournalTarget?) // the active filter, which the new entry starts with
    }

    /// What the user has typed and picked. The search the feed filters by lags the typed text by a
    /// short pause (`debouncedSearch`); the filter applies at once.
    @State private var criteria: JournalCriteria
    @State private var debouncedSearch = ""
    /// Bumped on each change to the criteria. Drives the debounced result count announcement.
    @State private var criteriaRevision = 0
    @State private var feedCache = JournalFeedCache()

    @Query private var allEntries: [LocalJournalEntry]
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var allSeeds: [LocalSeed]
    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil }) private var allBeds: [LocalBed]
    /// Every planting, deleted ones included. An entry on a deleted planting still belongs to its seed
    /// or bed in the filter. The filter menu lists only live plantings.
    @Query private var allPlantings: [LocalPlantingEvent]

    init(filterParent: JournalTarget? = nil) {
        _criteria = State(initialValue: JournalCriteria(filter: filterParent))
        _allEntries = Query(
            filter: #Predicate<LocalJournalEntry> { $0.deletedAt == nil },
            sort: \.occurredOn,
            order: .reverse)
    }

    /// The criteria the feed filters by: the debounced search and the immediate filter.
    private var appliedCriteria: JournalCriteria {
        JournalCriteria(filter: criteria.filter, searchText: debouncedSearch)
    }

    private func makeFeed() -> JournalFeed {
        feedCache.feed(
            householdID: appEnv.activeGardenHouseholdID,
            entries: allEntries,
            seeds: allSeeds,
            beds: allBeds,
            plantings: allPlantings,
            criteria: appliedCriteria)
    }

    var body: some View {
        let feed = makeFeed()
        NavigationStack {
            ZStack {
                WBScreenBackground()
                List {
                    Section {
                        headingBlock(feed)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        if let filter = criteria.filter {
                            filterChip(filter, feed: feed)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(
                                    top: 0, leading: WBMetrics.screenGutter,
                                    bottom: 4, trailing: WBMetrics.screenGutter))
                                .listRowSeparator(.hidden)
                        }
                        if !appliedCriteria.isActive {
                            RetrospectiveCard()
                                .listRowInsets(EdgeInsets(
                                    top: 4, leading: WBMetrics.screenGutter,
                                    bottom: 8, trailing: WBMetrics.screenGutter))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    feedRows(feed)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            #if os(iOS)
            .searchable(text: $criteria.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search journal")
            #else
            .searchable(text: $criteria.searchText, prompt: "Search journal")
            #endif
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .existing(let id):
                    JournalEntryView(entryID: id)
                case .new(let filtered):
                    JournalEntryView(entryID: nil, initialParent: filtered)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    filterMenu(feed)
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: Route.new(criteria.filter)) {
                        Label("New entry", systemImage: "plus")
                    }
                }
            }
            .refreshable {
                await refresh()
            }
            .task(id: criteria.filter) {
                await refresh()
            }
            .task(id: criteria.searchText) {
                await applySearchAfterPause()
            }
            .task(id: criteriaRevision) {
                await announceResultCount()
            }
            .onChange(of: criteria) { _, _ in
                criteriaRevision += 1
            }
            .onChange(of: appEnv.activeGardenHouseholdID) { _, _ in
                criteria.clearFilter()
            }
            .onChange(of: filterIsLive(feed), initial: true) { _, _ in
                criteria.dropFilterIfMissing(from: feed.index)
            }
        }
    }

    /// False only while a filter names a seed, bed or planting that is no longer live.
    private func filterIsLive(_ feed: JournalFeed) -> Bool {
        criteria.filter.map { feed.index.contains($0) } ?? true
    }

    private func clearCriteria() {
        criteria.clear()
        debouncedSearch = ""
    }

    private func refresh() async {
        switch criteria.filter {
        case .none:
            await appEnv.journal.refresh()
        case .seed(let id):
            await appEnv.journal.refresh(seedID: id)
        case .bed(let id):
            await appEnv.journal.refresh(bedID: id)
        case .plantingEvent(let id):
            await appEnv.journal.refresh(plantingEventID: id)
        }
    }

    /// Applies the typed search after a short pause, so the feed filters once per pause rather than on
    /// every keystroke. Clearing the text applies at once.
    private func applySearchAfterPause() async {
        let typed = criteria.searchText
        guard !typed.isEmpty else {
            debouncedSearch = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        debouncedSearch = typed
    }

    /// Speaks the result count once typing pauses, not on each keystroke. The first render is skipped.
    private func announceResultCount() async {
        guard criteriaRevision > 0 else { return }
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled, appliedCriteria.isActive else { return }
        let feed = makeFeed()
        AccessibilityNotification.Announcement(
            JournalFeedPresentation.resultAnnouncement(total: feed.total, shown: feed.shown.count)
        ).post()
    }

    @ViewBuilder
    private func headingBlock(_ feed: JournalFeed) -> some View {
        WBScreenTitle(
            "Journal",
            subtitle: JournalFeedPresentation.subtitle(
                total: feed.total,
                shown: feed.shown.count,
                isActive: appliedCriteria.isActive))
            .padding(.vertical, 8)
    }

    /// The active filter, with a remove button. Removing it shows the whole feed again.
    @ViewBuilder
    private func filterChip(_ target: JournalTarget, feed: JournalFeed) -> some View {
        let label = feed.index.label(for: target) ?? "(removed)"
        HStack(spacing: 4) {
            Text(JournalFeedPresentation.chipTitle(target, label: label))
                .font(.wbCaption.weight(.semibold))
                .foregroundStyle(WBColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                criteria.clearFilter()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(WBColor.muted)
                    .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(JournalFeedPresentation.removeFilterLabel(target, label: label))
            .accessibilityIdentifier("journal.filter.remove")
        }
        .padding(.leading, 12)
        // A capsule at one line (44pt tall); when large text wraps it onto more lines, the corners stay
        // 22pt instead of curving across the text.
        .background(WBColor.accentSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(WBColor.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal.filter.chip")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The filter menu: "All entries", then every live seed, bed and planting in the household, each kind in
    /// its own submenu so a long garden stays navigable.
    private func filterMenu(_ feed: JournalFeed) -> some View {
        Menu {
            Button {
                criteria.filter = nil
            } label: {
                filterItemLabel("All entries", isSelected: criteria.filter == nil)
            }
            .accessibilityAddTraits(criteria.filter == nil ? .isSelected : [])
            filterSubmenu("Seeds", feed.index.seedOptions)
            filterSubmenu("Beds", feed.index.bedOptions)
            filterSubmenu("Plantings", feed.index.plantingOptions)
        } label: {
            Image(systemName: criteria.filter == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .contentShape(Rectangle())
                // Toolbar items size themselves on the Mac. The 44pt target is for touch on iOS.
                #if os(iOS)
                .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                #endif
        }
        .accessibilityLabel("Filter journal")
        .accessibilityIdentifier("journal.filter.menu")
    }

    @ViewBuilder
    private func filterSubmenu(_ title: String, _ options: [JournalFilterOption]) -> some View {
        if !options.isEmpty {
            Menu(title) {
                ForEach(options, id: \.target) { option in
                    let isSelected = criteria.filter == option.target
                    Button {
                        criteria.filter = option.target
                    } label: {
                        filterItemLabel(option.label, isSelected: isSelected)
                    }
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    /// A menu item's label, with a checkmark when it is the active filter.
    @ViewBuilder
    private func filterItemLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func feedRows(_ feed: JournalFeed) -> some View {
        if let state = JournalFeedPresentation.emptyState(
            shownIsEmpty: feed.shown.isEmpty,
            isSyncing: appEnv.isSyncingForDisplay,
            isActive: appliedCriteria.isActive) {
            emptyRow(state)
        } else {
            ForEach(feed.shown) { entry in
                NavigationLink(value: Route.existing(entry.id)) {
                    entryRow(entry)
                }
                .accessibilityIdentifier("journal.entry.\(entry.id)")
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private func emptyRow(_ state: JournalFeedPresentation.EmptyState) -> some View {
        switch state {
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .tint(WBColor.accent)
                    .controlSize(.small)
                Text("Loading…")
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        case .noMatches:
            WBEmptyState(
                title: "No entries match",
                message: "Try different words, or clear the search and filter.",
                systemImage: "magnifyingglass",
                action: (label: "Clear", handler: { clearCriteria() })
            )
            .accessibilityIdentifier("journal.noMatches")
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        case .startJournal:
            WBEmptyState(
                title: "Start your journal",
                message: "Write down what happened in the garden today. Tap + to write the first entry.",
                systemImage: "book.closed"
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LocalJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                dateRoundel(ymd: entry.occurredOn)
                    .frame(minWidth: 44)
            }
            VStack(alignment: .leading, spacing: 6) {
                // At accessibility sizes the date moves above the text, on one line that may wrap.
                if dynamicTypeSize.isAccessibilitySize {
                    Text(abbreviatedDateString(ymd: entry.occurredOn))
                        .font(.wbCaption.weight(.semibold))
                        .foregroundStyle(WBColor.muted)
                }
                Text(entry.body.isEmpty ? "no entry yet" : entry.body)
                    .font(.wbCallout)
                    .foregroundStyle(WBColor.ink)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entryRowAccessibilityLabel(entry))
    }

    /// Synthesized VoiceOver label combining the date roundel + body summary
    /// so screen readers announce one item per row instead of fragments.
    private func entryRowAccessibilityLabel(_ entry: LocalJournalEntry) -> String {
        let dateString = accessibleDateString(ymd: entry.occurredOn)
        let bodySummary = entry.body.isEmpty ? "no entry yet" : entry.body
        return "\(dateString), \(bodySummary)"
    }

    private func accessibleDateString(ymd: String) -> String {
        JournalDatePresentation.accessibleDate(for: ymd, timeZone: .current)
    }

    private func abbreviatedDateString(ymd: String) -> String {
        JournalDatePresentation.abbreviatedDate(for: ymd, timeZone: .current)
    }

    @ViewBuilder
    private func dateRoundel(ymd: String) -> some View {
        let parts = JournalDatePresentation.parts(for: ymd, timeZone: .current)
        VStack(spacing: 1) {
            Text(parts.monthAbbrev)
                .font(.wbCaption.weight(.semibold))
                .foregroundStyle(WBColor.muted)
            Text("\(parts.day)")
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .foregroundStyle(WBColor.ink)
            Text(parts.year)
                .font(.wbMonoCaption)
                .foregroundStyle(WBColor.muted)
        }
    }

}
