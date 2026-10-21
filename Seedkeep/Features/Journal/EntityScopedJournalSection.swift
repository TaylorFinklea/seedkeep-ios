import SwiftUI
import SwiftData

/// Collapsible "Journal" section embedded inside a parent entity's
/// detail view. Shows the most recent N entries for that entity with a
/// "See all" link that pushes the full Journal feed pre-filtered.
///
/// Workbench rows: a thin accent rule on each row, the date in mono above the body.
struct EntityScopedJournalSection: View {
    enum Parent: Hashable {
        case seed(String)
        case bed(String)
        case plantingEvent(String)
    }

    let parent: Parent
    var maxEntries: Int = 3

    @Environment(AppEnvironment.self) private var appEnv
    @Query private var allEntries: [LocalJournalEntry]

    init(parent: Parent, maxEntries: Int = 3) {
        self.parent = parent
        self.maxEntries = maxEntries
        let predicate: Predicate<LocalJournalEntry>
        switch parent {
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
        Section {
            if entries.isEmpty {
                Text("No entries yet")
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
            } else {
                ForEach(entries.prefix(maxEntries)) { entry in
                    NavigationLink {
                        JournalEntryView(entryID: entry.id)
                    } label: {
                        entryRow(entry)
                    }
                }
                if entries.count > maxEntries {
                    Text("\(entries.count - maxEntries) more")
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                }
            }
            NavigationLink {
                JournalView(filterParent: parent)
            } label: {
                Text("See all journal entries")
                    .font(.wbCallout.weight(.semibold))
                    .foregroundStyle(WBColor.accent)
            }
        } header: {
            WBSectionHeader("Journal")
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LocalJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(WBColor.accent.opacity(0.6))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate(entry.occurredOn))
                    .font(.wbMonoCaption)
                    .foregroundStyle(WBColor.muted)
                Text(entry.body.isEmpty ? "no entries" : entry.body)
                    .font(.wbCallout)
                    .foregroundStyle(WBColor.ink)
                    .lineLimit(2)
            }
        }
    }

    private func formattedDate(_ ymd: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = parser.date(from: ymd) else { return ymd }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
}
