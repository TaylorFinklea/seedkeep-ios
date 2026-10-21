import Foundation
import Testing
@testable import Seedkeep

@Suite("Compact Seeds list helpers")
struct SeedsListTests {
    private func row(
        _ id: String,
        name: String = "",
        type: String = "",
        variety: String = "",
        company: String = "",
        year: Int? = nil,
        state: String = "active",
        notes: String = "",
        verdict: String? = nil,
        verdictLabel: String = "",
        updatedAt: Int64 = 0
    ) -> SeedTableRow {
        SeedTableRow(
            id: id,
            name: name,
            variety: variety,
            type: type,
            company: company,
            year: year,
            packets: 1,
            state: state,
            locationID: nil,
            locationName: "",
            tagIDs: [],
            tagNames: [],
            notes: notes,
            verdict: verdict,
            verdictLabel: verdictLabel,
            catalogID: nil,
            updatedAt: updatedAt
        )
    }

    @Test("recent first sorts by update time and breaks ties by id")
    func recentFirstOrdering() {
        let rows = [row("b", updatedAt: 4), row("c", updatedAt: 8), row("a", updatedAt: 4)]
        #expect(SeedsTableModel.recentFirst(rows).map(\.id) == ["c", "a", "b"])
    }

    @Test("groups trim types, preserve case, sort names deterministically and put untyped seeds last")
    func groupingByType() {
        let rows = [
            row("tomato-old", type: " Tomato ", updatedAt: 1),
            row("tomato-new", type: "Tomato", updatedAt: 2),
            row("lower", type: "tomato", updatedAt: 3),
            row("zucchini", type: "Zucchini"),
            row("blank", type: " \n "),
            row("literal-untyped", type: "Untyped"),
            row("a-upper", type: "A"),
            row("a-lower", type: "a"),
        ]
        let groups = SeedsTableModel.groupedByType(rows)
        #expect(groups.map(\.title) == ["A", "a", "Tomato", "tomato", "Zucchini", "Untyped"])
        #expect(groups.first(where: { $0.title == "Tomato" })?.rows.map(\.id) == ["tomato-new", "tomato-old"])
        // A blank type and a type that is literally "Untyped" share one last group, as the grid did.
        #expect(groups.last?.rawType == nil)
        #expect(groups.last?.rows.map(\.id) == ["blank", "literal-untyped"])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test("state counts follow the search across every state")
    func countsWithSearch() {
        let rows = [
            row("a", name: "Roma", type: "Tomato", state: "active"),
            row("b", name: "Roma", type: "Pepper", state: "wishlist"),
            row("c", name: "Basil", type: "Tomato", state: "active"),
        ]
        let unsearched = SeedsTableModel.libraryStateCounts(rows, search: "")
        #expect(unsearched[.active] == 2)
        #expect(unsearched[.wishlist] == 1)

        let roma = SeedsTableModel.libraryStateCounts(rows, search: "roma")
        #expect(roma[.active] == 1)
        #expect(roma[.wishlist] == 1)

        // Type is searched too, as on iPad and Mac.
        let tomato = SeedsTableModel.libraryStateCounts(rows, search: "tomato")
        #expect(tomato[.active] == 2)
        #expect(tomato[.wishlist] == 0)
    }

    @Test("empty state distinguishes no rows in state from no search match")
    func emptyStateClassification() {
        let row = row("a")
        #expect(SeedsListText.emptyState(rowsInSelectedState: [], searchMatches: []) == .noSeeds)
        #expect(SeedsListText.emptyState(rowsInSelectedState: [row], searchMatches: []) == .noMatches)
        #expect(SeedsListText.emptyState(rowsInSelectedState: [row], searchMatches: [row]) == .hasResults)
    }

    @Test("subtitle uses singular and plural seed wording")
    func subtitle() {
        #expect(SeedsListText.subtitle(total: 1, active: 1) == "1 seed · 1 active")
        #expect(SeedsListText.subtitle(total: 2, active: 1) == "2 seeds · 1 active")
    }

    @Test("row lines skip blank values and keep year plain")
    func rowLines() {
        #expect(SeedsListText.rowLines(for: row("a", type: "Tomato", company: "  ", year: 2024)) == ["Tomato", "2024"])
        #expect(SeedsListText.rowLines(for: row("b", variety: "Roma", company: "Acme", year: 2020)) == ["Roma", "Acme · 2020"])
        #expect(SeedsListText.rowLines(for: row("c")) == [])
    }

    @Test("accessibility label trims missing names and includes company, year and only a present verdict")
    func accessibilityLabel() {
        let noVerdict = row("a", name: "  ", type: " Tomato ", variety: "Roma", company: "Acme", year: 2024, verdictLabel: "Stale")
        #expect(SeedsListText.accessibilityLabel(for: noVerdict) == "Untitled seed, Tomato, Roma, Acme, 2024")

        let unknownVerdict = row("b", name: "Roma", company: "Acme", year: 2024, verdict: "unknown", verdictLabel: "No window")
        #expect(SeedsListText.accessibilityLabel(for: unknownVerdict) == "Roma, Acme, 2024, No window")
    }
}
