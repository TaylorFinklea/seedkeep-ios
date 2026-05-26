import SwiftUI
import SwiftData

/// Collapsible "Daybook" section embedded inside a parent entity's
/// detail view. Shows the most recent N entries for that entity with a
/// "See all" link that pushes the full Journal feed pre-filtered.
///
/// Herbarium chrome: sepia Rubric header, sage left-border on each row,
/// italic date + body in Spectral.
struct EntityScopedJournalSection: View {
    enum Parent: Hashable {
        case seed(String)
        case bed(String)
        case plantingEvent(String)
    }

    let parent: Parent
    var maxEntries: Int = 3

    @Query private var entries: [LocalJournalEntry]

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
        _entries = Query(filter: predicate, sort: \.occurredOn, order: .reverse)
    }

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("No entries yet")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
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
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkSoft)
                }
            }
            NavigationLink {
                JournalView(filterParent: parent)
            } label: {
                HStack(spacing: 6) {
                    Text("◇")
                        .foregroundStyle(HerbColor.sepia)
                    Text("See all daybook entries")
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.4)
                        .foregroundStyle(HerbColor.sepia)
                        .textCase(.uppercase)
                }
            }
        } header: {
            Rubric(text: "daybook")
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LocalJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(HerbColor.sage.opacity(0.6))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate(entry.occurredOn))
                    .font(HerbFont.smallCaps(size: 9))
                    .tracking(1.3)
                    .foregroundStyle(HerbColor.sepia)
                    .textCase(.uppercase)
                Text(entry.body.isEmpty ? "(empty)" : entry.body)
                    .font(HerbFont.body(size: 13))
                    .foregroundStyle(HerbColor.ink)
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
        f.locale = .current
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
}
