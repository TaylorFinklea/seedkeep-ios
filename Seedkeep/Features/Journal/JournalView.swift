import SwiftUI
import SwiftData

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
    @Query private var entries: [LocalJournalEntry]

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
        _entries = Query(filter: predicate, sort: \.occurredOn, order: .reverse)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                List {
                    if filterParent == nil {
                        Section {
                            headingBlock
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                            RetrospectiveCard()
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    if entries.isEmpty {
                        if appEnv.sync.isSyncing {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .herbProgressStyle()
                                    .controlSize(.small)
                                Text("turning the page…")
                                    .font(HerbFont.bodyItalic(size: 12))
                                    .foregroundStyle(HerbColor.inkSoft)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 32))
                                    .foregroundStyle(HerbColor.sepia.opacity(0.6))
                                Text("Begin the daybook")
                                    .font(HerbFont.display(size: 22))
                                    .foregroundStyle(HerbColor.ink)
                                Text("Track what passed in the garden today. Tap + to write the first entry.")
                                    .font(HerbFont.bodyItalic(size: 12))
                                    .foregroundStyle(HerbColor.inkSoft)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
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
            .navigationBarTitleDisplayMode(.inline)
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
            .overlay(alignment: .bottomTrailing) { SproutFAB() }
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
        VStack(alignment: .leading, spacing: 6) {
            FolioStrip(section: "Daybook", folio: max(entries.count, 1))
                .padding(.horizontal, -16)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Daybook")
                        .font(HerbFont.display(size: 38))
                        .foregroundStyle(HerbColor.ink)
                    Text("\(entries.count) entries · the household garden")
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkSoft)
                }
                Spacer()
            }
            ScholarRule(verticalMargin: 8)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LocalJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            dateRoundel(ymd: entry.occurredOn)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.body.isEmpty ? "no entry yet" : entry.body)
                    .font(HerbFont.body(size: 13))
                    .foregroundStyle(HerbColor.ink)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func dateRoundel(ymd: String) -> some View {
        let parts = parseYMD(ymd)
        VStack(spacing: 1) {
            Text(parts.monthAbbrev)
                .font(HerbFont.smallCaps(size: 8))
                .tracking(1.5)
                .foregroundStyle(HerbColor.sepia)
                .textCase(.uppercase)
            Text("\(parts.day)")
                .font(HerbFont.bodyEmph(size: 26))
                .foregroundStyle(HerbColor.ink)
            Text(parts.yearRoman)
                .font(HerbFont.smallCaps(size: 7))
                .tracking(1)
                .foregroundStyle(HerbColor.inkFaint)
        }
    }

    private func parseYMD(_ ymd: String) -> (monthAbbrev: String, day: Int, yearRoman: String) {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = parser.date(from: ymd) else { return ("MAY", 1, "MMXXVI") }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.day, .month, .year], from: date)
        let f = DateFormatter()
        f.dateFormat = "MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return (
            f.string(from: date),
            comps.day ?? 1,
            HerbRomanNumeral.string(for: comps.year ?? 2026, lowercase: false)
        )
    }
}
