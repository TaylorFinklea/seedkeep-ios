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
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        guard let date = parser.date(from: ymd) else { return ymd }

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = locale
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

/// Top-level Journal tab. Read-only feed of `LocalJournalEntry` rows
/// reverse-sorted by `occurredOn`. Pull-to-refresh hits the server feed
/// via `JournalStore.refresh()`. Rows + the toolbar "+" both push into
/// `JournalEntryView`.
///
/// Pass `filterParent` to scope the feed (and refresh calls) to a single
/// seed / bed / planting event — used by `EntityScopedJournalSection`'s
/// "See all" link.
struct JournalView: View {
    @Environment(AppEnvironment.self) private var appEnv

    enum Route: Hashable {
        case existing(String)   // entry id
        case new
    }

    let filterParent: EntityScopedJournalSection.Parent?
    @Query private var allEntries: [LocalJournalEntry]

    init(filterParent: EntityScopedJournalSection.Parent? = nil) {
        self.filterParent = filterParent
        let predicate: Predicate<LocalJournalEntry>
        switch filterParent {
        case .none:
            predicate = #Predicate<LocalJournalEntry> { $0.deletedAt == nil }
        case .seed(let id):
            predicate = #Predicate<LocalJournalEntry> { $0.seedID == id && $0.deletedAt == nil }
        case .bed(let id):
            predicate = #Predicate<LocalJournalEntry> { $0.bedID == id && $0.deletedAt == nil }
        case .plantingEvent(let id):
            predicate = #Predicate<LocalJournalEntry> { $0.plantingEventID == id && $0.deletedAt == nil }
        }
        _allEntries = Query(filter: predicate, sort: \.occurredOn, order: .reverse)
    }

    private var entries: [LocalJournalEntry] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return allEntries.filter { $0.householdID == householdID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WBScreenBackground()
                List {
                    if filterParent == nil {
                        Section {
                            headingBlock
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                            RetrospectiveCard()
                                .listRowInsets(EdgeInsets(
                                    top: 4, leading: WBMetrics.screenGutter,
                                    bottom: 8, trailing: WBMetrics.screenGutter))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    if entries.isEmpty {
                        if appEnv.isSyncingForDisplay {
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
                        } else {
                            WBEmptyState(
                                title: "Start your journal",
                                message: "Write down what happened in the garden today. Tap + to write the first entry.",
                                systemImage: "book.closed"
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } else {
                        ForEach(entries) { entry in
                            NavigationLink(value: Route.existing(entry.id)) {
                                entryRow(entry)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .publishesAssistantContext(pageType: "journal")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .existing(let id):
                    JournalEntryView(entryID: id)
                case .new:
                    // TODO: when arriving from EntityScopedJournalSection's
                    // "See all", pre-fill the parent on the new entry.
                    JournalEntryView(entryID: nil)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: Route.new) {
                        Label("New entry", systemImage: "plus")
                    }
                }
            }
            .refreshable {
                await refresh()
            }
            .task {
                await refresh()
            }
        }
    }

    private func refresh() async {
        switch filterParent {
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

    @ViewBuilder
    private var headingBlock: some View {
        WBScreenTitle("Journal", subtitle: "\(entries.count) entries · the household garden")
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func entryRow(_ entry: LocalJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            dateRoundel(ymd: entry.occurredOn)
                .frame(minWidth: 44)
            VStack(alignment: .leading, spacing: 6) {
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
