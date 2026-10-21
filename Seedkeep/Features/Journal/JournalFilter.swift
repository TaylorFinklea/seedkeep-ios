import Foundation
import SeedkeepKit
import SwiftData

/// A seed, bed or planting: what a journal entry can be attached to, and what the feed can be
/// filtered by.
typealias JournalTarget = EntityScopedJournalSection.Parent

/// The one attachment a journal entry carries, as its three nullable IDs.
struct JournalAttachment: Equatable {
    var seedID: String?
    var bedID: String?
    var plantingEventID: String?

    init(seedID: String?, bedID: String?, plantingEventID: String?) {
        self.seedID = seedID
        self.bedID = bedID
        self.plantingEventID = plantingEventID
    }

    init(_ target: JournalTarget?) {
        switch target {
        case .seed(let id):
            self.init(seedID: id, bedID: nil, plantingEventID: nil)
        case .bed(let id):
            self.init(seedID: nil, bedID: id, plantingEventID: nil)
        case .plantingEvent(let id):
            self.init(seedID: nil, bedID: nil, plantingEventID: id)
        case nil:
            self.init(seedID: nil, bedID: nil, plantingEventID: nil)
        }
    }

    /// The attached seed, bed or planting, or nil for a garden-level entry.
    var target: JournalTarget? {
        if let seedID { return .seed(seedID) }
        if let bedID { return .bed(bedID) }
        if let plantingEventID { return .plantingEvent(plantingEventID) }
        return nil
    }
}

/// One row in the Journal filter menu: a live seed, bed or planting and its label.
struct JournalFilterOption: Hashable {
    let target: JournalTarget
    let label: String
}

/// The household's seeds, beds and plantings, indexed for Journal search, filter labels, the filter
/// menu and the attachment picker. `JournalFeedCache` builds it once per data change.
///
/// Labels and menu options cover live rows only. The entry-to-planting relation covers every planting
/// in the household, deleted ones included. So a deleted planting's entries still show under its seed
/// or bed filter, and the deleted planting itself stays out of the menu.
struct JournalEntityIndex {
    /// The label of each live seed, bed and planting, as the menu and the chip show it.
    private let labels: [JournalTarget: String]
    /// The same labels folded for comparison, for search.
    private let foldedLabels: [JournalTarget: String]
    /// Every planting in the household, deleted or not, by ID. Only its seed and bed are read.
    private let plantingsByID: [String: LocalPlantingEvent]

    /// Every live seed, by display name.
    let seedOptions: [JournalFilterOption]
    /// Every live bed, in the garden's own order.
    let bedOptions: [JournalFilterOption]
    /// Every live planting, most recent first.
    let plantingOptions: [JournalFilterOption]

    init(householdID: String?, seeds: [LocalSeed], beds: [LocalBed], plantings: [LocalPlantingEvent]) {
        let liveSeeds = Self.indexed(seeds.filter { $0.householdID == householdID && $0.deletedAt == nil }) { $0.id }
        let liveBeds = Self.indexed(beds.filter { $0.householdID == householdID && $0.deletedAt == nil }) { $0.id }
        let householdPlantings = plantings.filter { $0.householdID == householdID }
        let livePlantings = Self.indexed(householdPlantings.filter { $0.deletedAt == nil }) { $0.id }

        let seedOptions = liveSeeds.values
            .sorted { lhs, rhs in
                let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
            .map { JournalFilterOption(target: .seed($0.id), label: $0.displayName) }
        let bedOptions = liveBeds.values
            .sorted { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder ? lhs.id < rhs.id : lhs.sortOrder < rhs.sortOrder
            }
            .map { JournalFilterOption(target: .bed($0.id), label: Self.bedName($0)) }
        let plantingOptions = livePlantings.values
            .sorted { lhs, rhs in
                lhs.plannedFor == rhs.plannedFor ? lhs.id < rhs.id : lhs.plannedFor > rhs.plannedFor
            }
            .map { JournalFilterOption(target: .plantingEvent($0.id), label: Self.plantingLabel($0, seeds: liveSeeds)) }

        let options = seedOptions + bedOptions + plantingOptions
        self.labels = Dictionary(options.map { ($0.target, $0.label) }, uniquingKeysWith: { first, _ in first })
        self.foldedLabels = Dictionary(
            options.map { ($0.target, JournalFilter.fold($0.label)) },
            uniquingKeysWith: { first, _ in first })
        self.plantingsByID = Self.indexed(householdPlantings) { $0.id }
        self.seedOptions = seedOptions
        self.bedOptions = bedOptions
        self.plantingOptions = plantingOptions
    }

    /// Whether the seed, bed or planting is live in the household.
    func contains(_ target: JournalTarget) -> Bool {
        labels[target] != nil
    }

    /// The label used in the filter menu and the chip. Nil once the row is deleted or missing.
    func label(for target: JournalTarget) -> String? {
        labels[target]
    }

    func option(for target: JournalTarget) -> JournalFilterOption? {
        labels[target].map { JournalFilterOption(target: target, label: $0) }
    }

    /// Whether the entry is attached to the target. A seed or bed also matches entries attached to one
    /// of its plantings, deleted plantings included. A planting matches only its own entries.
    func isAttached(_ entry: LocalJournalEntry, to target: JournalTarget) -> Bool {
        let planting = entry.plantingEventID.flatMap { plantingsByID[$0] }
        switch target {
        case .seed(let id):
            return entry.seedID == id || planting?.seedID == id
        case .bed(let id):
            return entry.bedID == id || planting?.bedID == id
        case .plantingEvent(let id):
            return entry.plantingEventID == id
        }
    }

    /// The folded text a search token can match for the entry: its folded body, then the folded label
    /// of each live attachment. A deleted attachment contributes no label, so the body still matches.
    func searchableText(for entry: LocalJournalEntry, foldedBody: String) -> [String] {
        let attached: [JournalTarget?] = [
            entry.seedID.map(JournalTarget.seed),
            entry.bedID.map(JournalTarget.bed),
            entry.plantingEventID.map(JournalTarget.plantingEvent),
        ]
        return [foldedBody] + attached.compactMap { $0 }.compactMap { foldedLabels[$0] }
    }

    private static func indexed<Row>(_ rows: [Row], id: (Row) -> String) -> [String: Row] {
        Dictionary(rows.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func bedName(_ bed: LocalBed) -> String {
        bed.name.trimmedNonEmpty ?? "Untitled bed"
    }

    /// "<kind> · <date> · <seed or Note>". The date is the stored `yyyy-MM-dd`, as the attachment
    /// picker has always shown it. The seed is its display name when it is live. Otherwise the label
    /// says "Note". A planting's free-text note is never shown.
    private static func plantingLabel(_ event: LocalPlantingEvent, seeds: [String: LocalSeed]) -> String {
        let kind = PlantingEventKind(rawValue: event.kindRaw)?.displayName ?? event.kindRaw
        let source = event.seedID.flatMap { seeds[$0]?.displayName } ?? "Note"
        return "\(kind) · \(event.plannedFor) · \(source)"
    }
}

/// Search and filter rules for the Journal feed. Pure: rows in, rows out.
enum JournalFilter {
    /// The comparison form of text: case and diacritics ignored, and the same in every locale.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The folded search tokens. Blank text gives none, which means no search.
    static func tokens(for searchText: String) -> [String] {
        searchText.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    }

    /// The entries that match the criteria, in the order given. A filter must hold for the entry, and
    /// every search token must match some field of it. Tokens may match different fields.
    /// `foldedBody` supplies each entry's folded body. The feed cache passes a memoized one.
    static func apply(
        _ entries: [LocalJournalEntry],
        searchText: String,
        filter: JournalTarget?,
        index: JournalEntityIndex,
        foldedBody: (LocalJournalEntry) -> String = { JournalFilter.fold($0.body) }
    ) -> [LocalJournalEntry] {
        let tokens = tokens(for: searchText)
        return entries.filter { entry in
            if let filter, !index.isAttached(entry, to: filter) { return false }
            guard !tokens.isEmpty else { return true }
            let fields = index.searchableText(for: entry, foldedBody: foldedBody(entry))
            return tokens.allSatisfy { token in fields.contains { $0.contains(token) } }
        }
    }
}

/// What the Journal feed is narrowed by: the search text and at most one filter. The filter starts
/// as the parent from "See all", and clearing it shows the whole feed.
struct JournalCriteria: Equatable {
    var searchText: String
    var filter: JournalTarget?

    init(filter: JournalTarget? = nil, searchText: String = "") {
        self.filter = filter
        self.searchText = searchText
    }

    /// Whether the search has at least one token. Whitespace-only text is no search.
    var isSearching: Bool {
        !JournalFilter.tokens(for: searchText).isEmpty
    }

    var isActive: Bool {
        isSearching || filter != nil
    }

    mutating func clear() {
        searchText = ""
        filter = nil
    }

    /// Clears the filter and keeps the search. A household change does this.
    mutating func clearFilter() {
        filter = nil
    }

    /// Drops the filter when its seed, bed or planting is no longer live in the household.
    mutating func dropFilterIfMissing(from index: JournalEntityIndex) {
        if let filter, !index.contains(filter) {
            self.filter = nil
        }
    }
}

/// The household's live entries, the index they are labelled from, and the rows the criteria leave
/// showing.
struct JournalFeed {
    /// Every live entry in the household, before the criteria apply.
    let total: Int
    let index: JournalEntityIndex
    let shown: [LocalJournalEntry]

    init(
        householdID: String?,
        entries: [LocalJournalEntry],
        index: JournalEntityIndex,
        criteria: JournalCriteria,
        foldedBody: (LocalJournalEntry) -> String = { JournalFilter.fold($0.body) }
    ) {
        let household = entries.filter { $0.householdID == householdID && $0.deletedAt == nil }
        self.total = household.count
        self.index = index
        self.shown = JournalFilter.apply(
            household,
            searchText: criteria.searchText,
            filter: criteria.filter,
            index: index,
            foldedBody: foldedBody)
    }
}

/// Wording and state for the Journal feed: the header count, the empty states, the filter chip and
/// the announced result count.
enum JournalFeedPresentation {
    enum EmptyState: Equatable {
        case loading
        /// Criteria are active and nothing matches. Offers Clear.
        case noMatches
        case startJournal
    }

    /// The line under the title. While criteria are active it reads "3 of 41 entries".
    static func subtitle(total: Int, shown: Int, isActive: Bool) -> String {
        guard isActive else { return "\(total) \(entryNoun(total)) · the household garden" }
        return "\(shown) of \(total) \(entryNoun(total))"
    }

    /// The empty row, or nil when there are rows to show. Loading wins while a sync is running.
    static func emptyState(shownIsEmpty: Bool, isSyncing: Bool, isActive: Bool) -> EmptyState? {
        guard shownIsEmpty else { return nil }
        if isSyncing { return .loading }
        return isActive ? .noMatches : .startJournal
    }

    /// What VoiceOver hears once typing pauses.
    static func resultAnnouncement(total: Int, shown: Int) -> String {
        shown == 0 ? "No entries match" : "\(shown) of \(total) \(entryNoun(total))"
    }

    /// "seed", "bed" or "planting".
    static func kindName(_ target: JournalTarget) -> String {
        switch target {
        case .seed: return "seed"
        case .bed: return "bed"
        case .plantingEvent: return "planting"
        }
    }

    /// The chip text, such as "Seed: Brandywine".
    static func chipTitle(_ target: JournalTarget, label: String) -> String {
        let kind: String
        switch target {
        case .seed: kind = "Seed"
        case .bed: kind = "Bed"
        case .plantingEvent: kind = "Planting"
        }
        return "\(kind): \(label)"
    }

    /// The chip's remove button, read aloud as "Remove filter, seed Brandywine".
    static func removeFilterLabel(_ target: JournalTarget, label: String) -> String {
        "Remove filter, \(kindName(target)) \(label)"
    }

    private static func entryNoun(_ count: Int) -> String {
        count == 1 ? "entry" : "entries"
    }
}

/// A row an attachment points to, as the save check sees it: its household, and whether it is live.
struct JournalAttachmentRow: Equatable {
    let householdID: String
    let isLive: Bool
}

/// The save-time check on an entry's household and attachment. It runs on every create and every
/// update, attached or not. Nothing is written when it refuses.
enum JournalSaveCheck: Equatable {
    case proceed
    /// No garden was active when the draft opened, or none is active now.
    case noGarden
    /// The active garden is not the one the draft opened in.
    case gardenChanged
    /// The attachment was already stored on the entry and is now deleted or gone.
    case storedAttachmentDeleted(kind: String)
    /// A newly chosen attachment is deleted, gone, or in another garden.
    case attachmentUnavailable(kind: String)

    /// The message to show instead of saving, or nil when the save may go ahead.
    var message: String? {
        switch self {
        case .proceed:
            return nil
        case .noGarden:
            return "Open a garden to save this entry."
        case .gardenChanged:
            return "The active garden changed while this entry was open. Reopen the journal in the garden you want and try again."
        case .storedAttachmentDeleted(let kind):
            return "This entry's \(kind) was deleted. Set Attached to Garden to keep editing."
        case .attachmentUnavailable(let kind):
            return "The \(kind) is no longer in this garden. Choose another and try again."
        }
    }

    /// Decides the save.
    /// - Parameters:
    ///   - draftHouseholdID: the garden the draft opened in, or nil if none was active then.
    ///   - activeHouseholdID: the garden active now.
    ///   - target: the attachment being saved, or nil for a garden-level entry.
    ///   - loaded: the attachment the entry already had when it was opened, or nil for a new entry.
    ///   - row: the attachment's row now, or nil when no such row exists.
    static func decide(
        draftHouseholdID: String?,
        activeHouseholdID: String?,
        target: JournalTarget?,
        loaded: JournalTarget?,
        row: JournalAttachmentRow?
    ) -> JournalSaveCheck {
        guard let draftHouseholdID, let activeHouseholdID else { return .noGarden }
        guard draftHouseholdID == activeHouseholdID else { return .gardenChanged }
        guard let target else { return .proceed }
        if let row, row.isLive, row.householdID == draftHouseholdID {
            return .proceed
        }
        let kind = JournalFeedPresentation.kindName(target)
        return target == loaded ? .storedAttachmentDeleted(kind: kind) : .attachmentUnavailable(kind: kind)
    }

    /// The attached row as stored now, or nil when there is no attachment or no such row.
    static func liveRow(for target: JournalTarget?, in context: ModelContext) -> JournalAttachmentRow? {
        guard let target else { return nil }
        switch target {
        case .seed(let id):
            guard let row = (try? context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id })))?.first else {
                return nil
            }
            return JournalAttachmentRow(householdID: row.householdID, isLive: row.deletedAt == nil)
        case .bed(let id):
            guard let row = (try? context.fetch(FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == id })))?.first else {
                return nil
            }
            return JournalAttachmentRow(householdID: row.householdID, isLive: row.deletedAt == nil)
        case .plantingEvent(let id):
            guard let row = (try? context.fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id })))?.first else {
                return nil
            }
            return JournalAttachmentRow(householdID: row.householdID, isLive: row.deletedAt == nil)
        }
    }
}
