import Testing
@testable import Seedkeep

@Suite("Workbench command palette")
struct WorkbenchPaletteTests {
    @Test("prefix matches rank before word-start and substring matches")
    func rankingPrefersPrefixThenWordStartThenSubstring() {
        let rows = [
            seedRow(id: "substring", name: "Aabeaned"),
            seedRow(id: "word-start", name: "Az bean"),
            seedRow(id: "prefix", name: "Bean seed")
        ]

        let results = CommandPaletteSearch.results(query: "bean", rows: rows)
        #expect(results.map(\.id) == ["seed:prefix", "seed:word-start", "seed:substring"])
    }

    @Test("matching is case-insensitive across title, hint, and group")
    func matchingIgnoresCaseAcrossAllFields() {
        let rows: [SeedTableRow] = []
        let titleMatch = CommandPaletteSearch.results(query: "NEW SEED", rows: rows)
        let hintMatch = CommandPaletteSearch.results(query: "CREATE A SEED", rows: rows)
        let groupMatches = CommandPaletteSearch.results(query: "aCtIoNs", rows: rows)

        #expect(titleMatch.contains { $0.id == "action:newSeed" })
        #expect(hintMatch.contains { $0.id == "action:newSeed" })
        #expect(groupMatches.map(\.id) == ["action:exportCSV", "action:focusSearch", "action:newSeed"])
    }

    @Test("ties sort Actions, Go to, then Seeds and alphabetically within each group")
    func tiesUseGroupAndAlphabeticalOrder() {
        let rows = [seedRow(id: "zulu", name: "Zulu"), seedRow(id: "alpha", name: "Alpha")]

        let ids = CommandPaletteSearch.results(query: "", rows: rows).map(\.id)
        #expect(ids == [
            "action:exportCSV", "action:focusSearch", "action:newSeed",
            "route:garden", "route:journal", "route:seeds", "route:settings", "route:today",
            "seed:alpha"
        ])
    }

    @Test("results are capped at nine")
    func resultsAreCappedAtNine() {
        let rows = (0..<20).map { seedRow(id: "seed-\($0)", name: "Seed \($0)") }
        #expect(CommandPaletteSearch.results(query: "", rows: rows).count == 9)
        #expect(CommandPaletteSearch.results(query: "seed", rows: rows).count == 9)
    }

    @Test("word-start matching checks overlapping occurrences")
    func wordStartSearchChecksOverlappingOccurrences() {
        let rows = [
            seedRow(id: "overlap", name: "xa-a-a"),
            seedRow(id: "substring", name: "aa-aX")
        ]

        #expect(CommandPaletteSearch.results(query: "a-a", rows: rows).map(\.id) == ["seed:overlap", "seed:substring"])
    }

    @Test("choosing a seed reveals it and closes the palette")
    @MainActor
    func choosingSeedUsesRevealContract() throws {
        let model = WorkbenchModel()
        model.route = .garden
        model.isPaletteOpen = true
        model.isInspectorOpen = false
        let row = seedRow(id: "seed-1", name: "Tomato")
        let item = try #require(CommandPaletteSearch.results(query: "Tomato", rows: [row]).first)

        CommandPaletteSelection.apply(item, to: model)

        #expect(model.route == .seeds)
        #expect(model.selectedSeedIDs == ["seed-1"])
        #expect(model.isInspectorOpen)
        #expect(model.revealedSeedID == "seed-1")
        #expect(!model.isPaletteOpen)
    }

    @Test("empty and whitespace queries return the sorted default suggestions")
    func emptyQueryReturnsDefaults() {
        let rows = [seedRow(id: "alpha", name: "Alpha"), seedRow(id: "beta", name: "Beta")]
        let expected = [
            "action:exportCSV", "action:focusSearch", "action:newSeed",
            "route:garden", "route:journal", "route:seeds", "route:settings", "route:today", "seed:alpha"
        ]

        #expect(CommandPaletteSearch.results(query: "", rows: rows).map(\.id) == expected)
        #expect(CommandPaletteSearch.results(query: "  \n", rows: rows).map(\.id) == expected)
    }
}

private func seedRow(id: String, name: String) -> SeedTableRow {
    SeedTableRow(
        id: id, name: name, variety: "", type: "", company: "", year: nil, packets: 1,
        state: "active", locationID: nil, locationName: "", tagIDs: [], tagNames: [], notes: "",
        verdict: nil, verdictLabel: "", catalogID: nil, updatedAt: 0
    )
}
