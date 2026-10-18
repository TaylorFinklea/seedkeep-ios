import Testing
import Foundation
@testable import Seedkeep
import SeedkeepKit

/// Seeds table, slice B: sorting, search, filters, counts, selection pruning, reveal and the export
/// selection rule. All pure over `SeedTableRow`.
@MainActor
@Suite("Seeds table — sorting, search, filters and selection")
struct SeedsTableModelTests {

    private static func row(
        _ id: String,
        name: String = "",
        variety: String = "",
        type: String = "",
        company: String = "",
        year: Int? = nil,
        packets: Int = 1,
        state: String = "active",
        location: String = "",
        tags: [String] = [],
        notes: String = "",
        verdictLabel: String = ""
    ) -> SeedTableRow {
        SeedTableRow(
            id: id,
            name: name,
            variety: variety,
            type: type,
            company: company,
            year: year,
            packets: packets,
            state: state,
            locationID: nil,
            locationName: location,
            tagIDs: [],
            tagNames: tags,
            notes: notes,
            verdict: nil,
            verdictLabel: verdictLabel,
            catalogID: nil,
            updatedAt: 1
        )
    }

    private static func ids(_ rows: [SeedTableRow]) -> [String] {
        rows.map(\.id)
    }

    // MARK: - Sorting

    @Test("name sorts both ways, and ties break by id")
    func nameSortAndTies() {
        let rows = [
            Self.row("c", name: "Basil"),
            Self.row("a", name: "Arugula"),
            Self.row("b", name: "Basil"),
        ]
        let ascending = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.name, order: .forward)])
        let descending = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.name, order: .reverse)])

        #expect(Self.ids(ascending) == ["a", "b", "c"], "equal names fall back to id ascending")
        #expect(Self.ids(descending) == ["b", "c", "a"], "reverse order still breaks ties by id")
    }

    @Test("blank text sorts last in both directions")
    func blanksLastForText() {
        let rows = [
            Self.row("blank", variety: ""),
            Self.row("zed", variety: "Zebra"),
            Self.row("ace", variety: "Ace"),
        ]
        let ascending = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.variety, order: .forward)])
        let descending = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.variety, order: .reverse)])

        #expect(Self.ids(ascending) == ["ace", "zed", "blank"])
        #expect(Self.ids(descending) == ["zed", "ace", "blank"], "blank stays last when reversed")
    }

    @Test("blank years sort last in both directions")
    func blanksLastForYear() {
        let rows = [
            Self.row("none"),
            Self.row("old", year: 2010),
            Self.row("new", year: 2024),
        ]
        let ascending = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.yearSortKey, order: .forward)])
        let descending = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.yearSortKey, order: .reverse)])

        #expect(Self.ids(ascending) == ["old", "new", "none"])
        #expect(Self.ids(descending) == ["new", "old", "none"], "a missing year is never first")
    }

    @Test("numbers sort numerically, not as text")
    func numericPackets() {
        let rows = [
            Self.row("ten", packets: 10),
            Self.row("two", packets: 2),
            Self.row("zero", packets: 0),
        ]
        let sorted = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.packets, order: .forward)])
        #expect(Self.ids(sorted) == ["zero", "two", "ten"])
    }

    @Test("sorting by the stored state uses the raw value")
    func sortsByStatus() {
        let rows = [
            Self.row("w", state: "wishlist"),
            Self.row("a", state: "active"),
            Self.row("r", state: "archived"),
        ]
        let sorted = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.state, order: .forward)])
        #expect(Self.ids(sorted) == ["a", "r", "w"])
    }

    @Test("a comparator on a column that is not sortable is ignored, and no comparator keeps id order")
    func unknownComparatorIgnored() {
        let rows = [Self.row("b"), Self.row("a")]
        let sorted = SeedsTableModel.sorted(rows, using: [])
        #expect(Self.ids(sorted) == ["a", "b"])
    }

    // MARK: - Search

    @Test("search matches name, variety, company, type and notes, ignoring case")
    func searchFields() {
        let rows = [
            Self.row("name", name: "Cherokee Purple"),
            Self.row("variety", variety: "Brandywine"),
            Self.row("company", company: "Baker Creek"),
            Self.row("type", type: "Pepper"),
            Self.row("notes", notes: "Sow in March"),
            Self.row("tag", tags: ["Winter"]),
        ]
        func matches(_ query: String) -> [String] {
            Self.ids(SeedsTableModel.filtered(rows, SeedsFilter(search: query)))
        }

        #expect(matches("CHEROKEE") == ["name"])
        #expect(matches("brandy") == ["variety"])
        #expect(matches("baker") == ["company"])
        #expect(matches("pepper") == ["type"])
        #expect(matches("march") == ["notes"])
        #expect(matches("winter").isEmpty, "tags are not part of search")
        #expect(matches("   ").count == rows.count, "a blank query shows everything")
    }

    // MARK: - Filters and counts

    @Test("the lifecycle tab filters by stored state")
    func stateFilter() {
        let rows = [
            Self.row("a", state: "active"),
            Self.row("w", state: "wishlist"),
            Self.row("s", state: "saved"),
            Self.row("r", state: "archived"),
        ]
        var filter = SeedsFilter()
        filter.stateTab = .wishlist
        #expect(Self.ids(SeedsTableModel.filtered(rows, filter)) == ["w"])
        filter.stateTab = .all
        #expect(SeedsTableModel.filtered(rows, filter).count == 4)
    }

    @Test("the type filter matches the exact type")
    func typeFilter() {
        let rows = [
            Self.row("p1", type: "Pepper"),
            Self.row("t1", type: "Tomato"),
            Self.row("none"),
        ]
        var filter = SeedsFilter()
        filter.type = "Tomato"
        #expect(Self.ids(SeedsTableModel.filtered(rows, filter)) == ["t1"])
        #expect(SeedsTableModel.typeOptions(rows) == ["Pepper", "Tomato"], "blank types are not offered")
    }

    @Test("counts show every tab, honour search and type, and ignore the tab itself")
    func counts() {
        let rows = [
            Self.row("a1", name: "Basil", type: "Herb", state: "active"),
            Self.row("a2", name: "Thyme", type: "Herb", state: "active"),
            Self.row("w1", name: "Basil Thai", type: "Herb", state: "wishlist"),
            Self.row("s1", name: "Tomato", type: "Fruit", state: "saved"),
            Self.row("r1", name: "Basil old", type: "Herb", state: "archived"),
        ]
        var filter = SeedsFilter()
        filter.stateTab = .active
        let all = SeedsTableModel.counts(rows, filter: filter)

        #expect(all[.all] == 5, "with no search or type, every row counts toward All, whatever the tab")
        #expect(all[.active] == 2)
        #expect(all[.wishlist] == 1)
        #expect(all[.saved] == 1)
        #expect(all[.archived] == 1)

        filter.search = "basil"
        filter.type = "Herb"
        let searched = SeedsTableModel.counts(rows, filter: filter)
        #expect(searched[.all] == 3)
        #expect(searched[.active] == 1)
        #expect(searched[.wishlist] == 1)
        #expect(searched[.archived] == 1)
    }

    // MARK: - Selection and reveal

    @Test("selection pruning keeps only live ids and ignores hidden rows")
    func pruning() {
        let live: Set<String> = ["a", "b", "c"]
        #expect(SeedsTableModel.pruned(["a", "gone"], liveIDs: live) == ["a"])
        #expect(SeedsTableModel.pruned([], liveIDs: live).isEmpty)
    }

    @Test("revealing a hidden seed clears only the filters that hide it")
    func revealClearsHidingFilters() {
        let wishlist = Self.row("w", name: "Basil", type: "Herb", state: "wishlist")

        var filter = SeedsFilter()
        filter.stateTab = .active
        filter.type = "Fruit"
        filter.search = "zzz"
        let revealed = SeedsTableModel.revealing(wishlist, from: filter)

        #expect(revealed.stateTab == .all)
        #expect(revealed.type == nil)
        #expect(revealed.search == "")

        var keep = SeedsFilter()
        keep.type = "Herb"
        let unchanged = SeedsTableModel.revealing(wishlist, from: keep)
        #expect(unchanged.type == "Herb", "a filter that already shows the seed is kept")
        #expect(unchanged.stateTab == .all)
    }

    @Test("the export rows are the selection in table order, or else the filtered and sorted rows")
    func exportRowsRule() {
        let rows = [
            Self.row("c", name: "Carrot", state: "active"),
            Self.row("a", name: "Apple", state: "wishlist"),
            Self.row("b", name: "Bean", state: "active"),
        ]
        let sort = [KeyPathComparator(\SeedTableRow.name, order: .forward)]

        var filter = SeedsFilter()
        filter.stateTab = .active
        let filteredOnly = SeedsTableModel.exportRows(rows: rows, filter: filter, selection: [], sortOrder: sort)
        #expect(Self.ids(filteredOnly) == ["b", "c"], "no selection exports the filtered, sorted rows")

        let selected = SeedsTableModel.exportRows(rows: rows, filter: filter, selection: ["a", "c"], sortOrder: sort)
        #expect(Self.ids(selected) == ["a", "c"], "a selection exports those rows even when a filter hides them")
    }

    @Test("state labels come from the stored raw value")
    func stateLabels() {
        #expect(SeedsTableModel.stateLabel("wishlist") == "Wishlist")
        #expect(SeedsTableModel.stateLabel("archived") == "Archived")
        #expect(SeedsTableModel.stateLabel("mystery") == "Mystery")
    }

    // MARK: - Performance

    @Test("mapping and sorting 1,000 seeds takes under 50 ms")
    func mapAndSortPerformance() {
        func makeSeeds(_ count: Int) -> [LocalSeed] {
            (0..<count).map { index in
                LocalSeed(
                    id: "perf_\(index)",
                    householdID: "hh_perf",
                    catalogID: index.isMultiple(of: 2) ? "cat_\(index)" : nil,
                    state: index.isMultiple(of: 3) ? .wishlist : .active,
                    packetCount: index % 7,
                    locationID: index.isMultiple(of: 5) ? "loc_shed" : nil,
                    yearPacked: index.isMultiple(of: 4) ? nil : 2000 + index % 26,
                    source: .store,
                    customName: "Seed \(index * 37 % 1000)",
                    customVariety: index.isMultiple(of: 3) ? nil : "Variety \(index % 40)",
                    customCompany: "Company \(index % 12)",
                    customType: "Type \(index % 9)",
                    notes: "Notes \(index)",
                    tagIDs: ["tag_a", "tag_b"],
                    createdAt: 1,
                    updatedAt: Int64(index)
                )
            }
        }
        let seeds = makeSeeds(1_000)
        let locations = [LocalLocation(id: "loc_shed", householdID: "hh_perf", name: "Shed", sortOrder: 0, createdAt: 1, updatedAt: 1)]
        let tags = [
            LocalTag(id: "tag_a", householdID: "hh_perf", name: "Heirloom", createdAt: 1, updatedAt: 1),
            LocalTag(id: "tag_b", householdID: "hh_perf", name: "Winter", createdAt: 1, updatedAt: 1),
        ]

        // Warm up once so one-time costs are not counted.
        _ = SeedTableRow.rows(seeds: Array(seeds.prefix(10)), locations: locations, tags: tags, recommendations: [:])

        let clock = ContinuousClock()
        var sortedCount = 0
        let elapsed = clock.measure {
            let rows = SeedTableRow.rows(seeds: seeds, locations: locations, tags: tags, recommendations: [:])
            let sorted = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.name, order: .forward)])
            let byYear = SeedsTableModel.sorted(sorted, using: [KeyPathComparator(\SeedTableRow.yearSortKey, order: .reverse)])
            sortedCount = byYear.count
        }

        #expect(sortedCount == 1_000)
        #expect(elapsed < .milliseconds(50), "mapping and sorting 1,000 seeds took \(elapsed)")
    }
}

/// Reveal, the edit selection and the keyboard Delete gate.
@MainActor
@Suite("Seeds table — reveal, edit selection and the Delete gate")
struct SeedsTableReviewTests {
    private static func row(_ id: String) -> SeedTableRow {
        SeedTableRow(
            id: id, name: id, variety: "", type: "", company: "", year: nil, packets: 1,
            state: "active", locationID: nil, locationName: "", tagIDs: [], tagNames: [],
            notes: "", verdict: nil, verdictLabel: "", catalogID: nil, updatedAt: 1
        )
    }

    @Test("a reveal waits while no rows are loaded, and is dropped once rows are loaded without the seed")
    func revealOutcomes() {
        #expect(SeedsTableModel.revealOutcome(for: "a", in: []) == .pending)
        #expect(SeedsTableModel.revealOutcome(for: "a", in: [Self.row("b")]) == .missing)
        #expect(SeedsTableModel.revealOutcome(for: "a", in: [Self.row("a"), Self.row("b")]) == .found(Self.row("a")))
    }

    @Test("an edited or revealed seed joins the selection without dropping the others")
    func selectionAfterEdit() {
        #expect(SeedsTableModel.selectionAfterEdit(["x"], seedID: "a") == ["x", "a"])
        #expect(SeedsTableModel.selectionAfterEdit(["a"], seedID: "a") == ["a"])
    }

    @Test("keyboard Delete needs a selection, and must not fire while text is being edited")
    func deleteGate() {
        #expect(!SeedsTableModel.canRequestDelete(selectionCount: 0, isEditingText: false))
        #expect(!SeedsTableModel.canRequestDelete(selectionCount: 2, isEditingText: true))
        #expect(SeedsTableModel.canRequestDelete(selectionCount: 2, isEditingText: false))
    }
}
