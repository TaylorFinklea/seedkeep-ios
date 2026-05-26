import SwiftUI
import SwiftData
import SeedkeepKit

/// Diurnalis — Today's specimens.
///
/// Landing screen for the Herbarium-styled app. Renders the date in the
/// scholarly format, a daylight arc with sunrise/sunset, the queue of
/// planting events due today (or overdue), and a Caveat-handwritten
/// margin note pulling the latest journal entry from the last 48h.
struct TodayView: View {
    @Environment(AppEnvironment.self) private var appEnv

    /// Today's + overdue events (deletedAt nil, completedAt nil, planned for today or earlier)
    @Query private var dueEvents: [LocalPlantingEvent]
    /// Recent journal entries to surface in the margin note.
    @Query private var recentJournal: [LocalJournalEntry]
    /// Active seeds for pulling the seed name on a planting event.
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var seeds: [LocalSeed]

    init() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let today = f.string(from: Date())
        let yesterday = f.string(from: Date().addingTimeInterval(-86400))
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
    }

    var body: some View {
        ZStack {
            VellumBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FolioStrip(section: "Diurnalis", folio: folioNumber)

                    headingBlock
                        .padding(.horizontal, 26)
                        .padding(.top, 4)

                    ScholarRule(verticalMargin: 12)
                        .padding(.horizontal, 22)

                    sunArcBlock
                        .padding(.horizontal, 26)
                        .padding(.bottom, 4)

                    sowingsBlock
                        .padding(.horizontal, 22)
                        .padding(.top, 16)

                    if let marginEntry {
                        marginNoteBlock(entry: marginEntry)
                            .padding(.horizontal, 26)
                            .padding(.top, 16)
                    }

                    Color.clear.frame(height: 80)
                }
            }
            .overlay(alignment: .bottomTrailing) { SproutFAB() }
        }
    }

    // MARK: - Heading

    @ViewBuilder
    private var headingBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(astroSubtitle)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .tracking(0.3)

            Text(scholarlyDate)
                .font(HerbFont.smallCaps(size: 13))
                .tracking(2.5)
                .foregroundStyle(HerbColor.sepia)
                .textCase(.uppercase)
                .padding(.top, 6)

            Text("Today's\nspecimens")
                .font(HerbFont.display(size: 44))
                .foregroundStyle(HerbColor.ink)
                .lineSpacing(0)
                .padding(.top, 2)
        }
    }

    private var scholarlyDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private var astroSubtitle: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private var folioNumber: Int {
        // Day-of-year as the folio (a small joke — the app is "today's leaf"
        // in the gardener's herbarium for the year).
        Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: Date()) ?? 1
    }

    // MARK: - Sun arc

    @ViewBuilder
    private var sunArcBlock: some View {
        if let dayLight = computedDayLight {
            SunArc(sunrise: dayLight.sunrise, sunset: dayLight.sunset, now: Date())
                .padding(.top, 4)
        } else {
            VStack(spacing: 4) {
                Text("Set a home location to see today's daylight arc.")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
                Text("ORDER · HOME LOCATION")
                    .font(HerbFont.smallCaps(size: 9))
                    .tracking(1.5)
                    .foregroundStyle(HerbColor.sepia)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private var computedDayLight: Solar.DayLight? {
        guard
            let lat = appEnv.preferences.cachedLatitude,
            let lon = appEnv.preferences.cachedLongitude
        else { return nil }
        return Solar.dayLight(latitude: lat, longitude: lon, on: Date())
    }

    // MARK: - Sowings queue

    @ViewBuilder
    private var sowingsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rubric(text: "to be sown today")
                .padding(.horizontal, 4)

            if dueEvents.isEmpty {
                Text("No sowings planned. A quiet day in the herbarium.")
                    .font(HerbFont.bodyItalic(size: 13))
                    .foregroundStyle(HerbColor.inkSoft)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            } else {
                ForEach(dueEvents.prefix(6)) { event in
                    SowingRow(event: event, seed: seedFor(eventID: event.id))
                }
            }
        }
    }

    private func seedFor(eventID: String) -> LocalSeed? {
        // Match the planting event's seed_id; fall back to nil if absent.
        guard let evt = dueEvents.first(where: { $0.id == eventID }),
              let sid = evt.seedID else { return nil }
        return seeds.first(where: { $0.id == sid })
    }

    // MARK: - Margin handwritten note

    @ViewBuilder
    private func marginNoteBlock(entry: LocalJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .strokeBorder(HerbColor.sepia, lineWidth: 1)
                    .frame(width: 24, height: 24)
                Text("♃")
                    .font(HerbFont.smallCaps(size: 11))
                    .foregroundStyle(HerbColor.sepia)
            }
            Text(entry.body.isEmpty ? "—" : entry.body)
                .font(HerbFont.handwritten(size: 17))
                .foregroundStyle(HerbColor.sepia)
                .lineSpacing(2)
        }
    }

    private var marginEntry: LocalJournalEntry? {
        recentJournal.first
    }
}

// MARK: - Sowing row

private struct SowingRow: View {
    let event: LocalPlantingEvent
    let seed: LocalSeed?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PressedPlant(kind: PressedPlant.Kind.from(seed?.customType), size: 40)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(HerbFont.body(size: 15))
                    .foregroundStyle(HerbColor.ink)
                Text(scientificName)
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Circle()
                    .fill(daysRemaining < 0 ? HerbColor.rose : HerbColor.verdictNow)
                    .frame(width: 10, height: 10)
                Text(daysLabel)
                    .font(HerbFont.smallCaps(size: 9))
                    .tracking(1.5)
                    .foregroundStyle(HerbColor.sepia)
                    .textCase(.uppercase)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HerbColor.inkFaint)
                .frame(height: 0.5)
        }
    }

    private var displayName: String {
        seed?.customName ?? "Untitled seed"
    }

    private var scientificName: String {
        let raw = (seed?.customType ?? "").trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "—" : raw
    }

    private var daysRemaining: Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let planned = f.date(from: event.plannedFor) else { return 0 }
        let diff = Calendar(identifier: .gregorian).dateComponents([.day], from: Date(), to: planned).day ?? 0
        return diff
    }

    private var daysLabel: String {
        if daysRemaining < 0 {
            let n = -daysRemaining
            return n == 1 ? "1 day past" : "\(n) days past"
        } else if daysRemaining == 0 {
            return "today"
        } else {
            return daysRemaining == 1 ? "1 day left" : "\(daysRemaining) days left"
        }
    }
}
