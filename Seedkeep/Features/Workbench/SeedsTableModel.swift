// Filter, search, count, sort and selection rules for the Seeds table (redesign R1, slice B).
// Pure functions over `SeedTableRow`, so the rules are testable without a window or a store.
import Foundation
import SeedkeepKit

/// The lifecycle tabs. Raw values match `SeedState`, so a tab maps straight to a stored state.
enum SeedStateFilter: String, CaseIterable, Identifiable, Sendable {
    case all, active, wishlist, saved, archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .wishlist: return "Wishlist"
        case .saved: return "Saved"
        case .archived: return "Archived"
        }
    }

    /// The `SeedState` raw value this tab shows, or nil for All.
    var stateRaw: String? {
        self == .all ? nil : rawValue
    }
}

/// What the table shows: one lifecycle tab, an optional type, and search text.
struct SeedsFilter: Equatable, Sendable {
    var stateTab: SeedStateFilter = .all
    var type: String?
    var search: String = ""

    func matches(_ row: SeedTableRow) -> Bool {
        if let raw = stateTab.stateRaw, row.state != raw { return false }
        if let type, row.type != type { return false }
        return Self.matchesSearch(row, query: search)
    }

    /// Case-insensitive match against name, variety, company, type and notes.
    static func matchesSearch(_ row: SeedTableRow, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return [row.name, row.variety, row.company, row.type, row.notes].contains {
            $0.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

/// The columns that can sort, keyed to the same key paths the `Table` columns use.
enum SeedsSortField: CaseIterable {
    case name, variety, type, company, year, packets, state, location, tags, window

    var keyPath: PartialKeyPath<SeedTableRow> {
        switch self {
        case .name: return \SeedTableRow.name
        case .variety: return \SeedTableRow.variety
        case .type: return \SeedTableRow.type
        case .company: return \SeedTableRow.company
        case .year: return \SeedTableRow.yearSortKey
        case .packets: return \SeedTableRow.packets
        case .state: return \SeedTableRow.state
        case .location: return \SeedTableRow.locationName
        case .tags: return \SeedTableRow.tagsText
        case .window: return \SeedTableRow.verdictLabel
        }
    }

    /// The sort value for a row, or nil when the field is blank (blank always sorts last).
    func value(_ row: SeedTableRow) -> SeedSortValue? {
        switch self {
        case .name: return SeedSortValue.nonBlank(row.name)
        case .variety: return SeedSortValue.nonBlank(row.variety)
        case .type: return SeedSortValue.nonBlank(row.type)
        case .company: return SeedSortValue.nonBlank(row.company)
        case .year: return row.year.map { SeedSortValue.number($0) }
        case .packets: return SeedSortValue.number(row.packets)
        case .state: return SeedSortValue.nonBlank(row.state)
        case .location: return SeedSortValue.nonBlank(row.locationName)
        case .tags: return SeedSortValue.nonBlank(row.tagsText)
        case .window: return SeedSortValue.nonBlank(row.verdictLabel)
        }
    }
}

enum SeedSortValue: Equatable, Sendable {
    case text(String)
    case number(Int)

    /// Text that is empty or only whitespace counts as blank.
    static func nonBlank(_ value: String) -> SeedSortValue? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(value)
    }
}

enum SeedsTableModel {
    /// Name ascending, the table's first sort.
    static var defaultSortOrder: [KeyPathComparator<SeedTableRow>] {
        [KeyPathComparator(\SeedTableRow.name, order: .forward)]
    }

    static func filtered(_ rows: [SeedTableRow], _ filter: SeedsFilter) -> [SeedTableRow] {
        rows.filter { filter.matches($0) }
    }

    /// Sorts explicitly, the way the table shows rows. Blanks sort last in both directions, and
    /// ties break by id, so the order is deterministic. Comparators whose key path is not a
    /// sortable column are ignored.
    static func sorted(
        _ rows: [SeedTableRow],
        using comparators: [KeyPathComparator<SeedTableRow>]
    ) -> [SeedTableRow] {
        let keys: [(field: SeedsSortField, order: SortOrder)] = comparators.compactMap { comparator in
            guard let field = SeedsSortField.allCases.first(where: { $0.keyPath == comparator.keyPath }) else {
                return nil
            }
            return (field: field, order: comparator.order)
        }

        // Compute each row's keys once rather than on every comparison.
        struct Keyed {
            let row: SeedTableRow
            let values: [SeedSortValue?]
        }
        let keyed = rows.map { row in
            Keyed(row: row, values: keys.map { $0.field.value(row) })
        }

        let ordered = keyed.sorted { lhs, rhs in
            for (index, key) in keys.enumerated() {
                switch (lhs.values[index], rhs.values[index]) {
                case (nil, nil):
                    continue
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case let (left?, right?):
                    let ordering = compare(left, right)
                    if ordering == 0 { continue }
                    return key.order == .forward ? ordering < 0 : ordering > 0
                }
            }
            return lhs.row.id < rhs.row.id
        }
        return ordered.map(\.row)
    }

    private static func compare(_ left: SeedSortValue, _ right: SeedSortValue) -> Int {
        switch (left, right) {
        case let (.number(a), .number(b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        case let (.text(a), .text(b)):
            switch a.localizedStandardCompare(b) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        default:
            return 0
        }
    }

    /// Counts for each lifecycle tab. The counts ignore the tab itself but honour the search and
    /// type, so each tab shows how many seeds it would reveal.
    static func counts(_ rows: [SeedTableRow], filter: SeedsFilter) -> [SeedStateFilter: Int] {
        var base = filter
        base.stateTab = .all
        var result: [SeedStateFilter: Int] = [:]
        for tab in SeedStateFilter.allCases { result[tab] = 0 }
        for row in rows where base.matches(row) {
            result[.all, default: 0] += 1
            if let tab = SeedStateFilter.allCases.first(where: { $0.stateRaw == row.state }) {
                result[tab, default: 0] += 1
            }
        }
        return result
    }

    /// Distinct, non-empty types, sorted for the type menu.
    static func typeOptions(_ rows: [SeedTableRow]) -> [String] {
        let types = Set(rows.map(\.type).filter { !$0.isEmpty })
        return types.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Keeps only selected ids that are still live. Pass the household's rows, not the visible
    /// ones, so a seed hidden by a filter stays selected.
    static func pruned(_ selection: Set<String>, liveIDs: Set<String>) -> Set<String> {
        selection.intersection(liveIDs)
    }

    /// The filter after revealing `row`: each criterion that would hide it is cleared, and the
    /// others stay as they are.
    static func revealing(_ row: SeedTableRow, from filter: SeedsFilter) -> SeedsFilter {
        var result = filter
        if let raw = result.stateTab.stateRaw, row.state != raw {
            result.stateTab = .all
        }
        if let type = result.type, row.type != type {
            result.type = nil
        }
        if !SeedsFilter.matchesSearch(row, query: result.search) {
            result.search = ""
        }
        return result
    }

    /// The rows to export: the selected seeds if any are selected (in table order), otherwise the
    /// current filtered and sorted rows.
    static func exportRows(
        rows: [SeedTableRow],
        filter: SeedsFilter,
        selection: Set<String>,
        sortOrder: [KeyPathComparator<SeedTableRow>]
    ) -> [SeedTableRow] {
        if !selection.isEmpty {
            return sorted(rows.filter { selection.contains($0.id) }, using: sortOrder)
        }
        return sorted(filtered(rows, filter), using: sortOrder)
    }

    /// Display label for a stored state raw value.
    static func stateLabel(_ raw: String) -> String {
        SeedStateFilter(rawValue: raw)?.title ?? raw.capitalized
    }
}

/// What revealing a seed should do, given the rows loaded so far.
enum SeedRevealOutcome: Equatable {
    case found(SeedTableRow)
    /// No rows are loaded yet, so the request waits for them.
    case pending
    /// Rows are loaded and this seed is not among them (deleted, or another household's).
    case missing
}

extension SeedsTableModel {
    static func revealOutcome(for seedID: String, in rows: [SeedTableRow]) -> SeedRevealOutcome {
        if let row = rows.first(where: { $0.id == seedID }) {
            return .found(row)
        }
        return rows.isEmpty ? .pending : .missing
    }

    /// The selection with an edited or revealed seed included. Other selected seeds stay selected.
    static func selectionAfterEdit(_ selection: Set<String>, seedID: String) -> Set<String> {
        selection.union([seedID])
    }

    /// The keyboard Delete (table focus on Mac) acts only with a selection and outside text editing.
    /// The bulk bar's Delete button is not gated by this, since clicking it moves focus.
    static func canRequestDelete(selectionCount: Int, isEditingText: Bool) -> Bool {
        selectionCount > 0 && !isEditingText
    }
}
