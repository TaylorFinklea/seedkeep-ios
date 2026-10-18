import Testing
import Foundation
@testable import Seedkeep
import SeedkeepKit

/// Seeds table, slice B: `SeedTableRow.rows(...)` maps live models to display rows.
@MainActor
@Suite("Seeds table — row mapping")
struct SeedsTableRowTests {
    private static let household = "hh_rows"

    private static func seed(
        id: String,
        name: String? = "Cherokee Purple",
        variety: String? = nil,
        type: String? = nil,
        company: String? = nil,
        year: Int? = nil,
        packets: Int = 1,
        state: SeedState = .active,
        locationID: String? = nil,
        tagIDs: [String] = [],
        notes: String? = nil,
        catalogID: String? = nil,
        updatedAt: Int64 = 10,
        deletedAt: Int64? = nil
    ) -> LocalSeed {
        LocalSeed(
            id: id,
            householdID: household,
            catalogID: catalogID,
            state: state,
            packetCount: packets,
            locationID: locationID,
            yearPacked: year,
            source: .store,
            customName: name,
            customVariety: variety,
            customCompany: company,
            customType: type,
            notes: notes,
            tagIDs: tagIDs,
            createdAt: 1,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    private static func recommendation(catalogID: String, verdict: String) -> LocalRecommendation {
        LocalRecommendation(
            catalogSeedID: catalogID,
            locationSignature: "sig",
            computedAt: 1,
            source: "rule",
            confidence: 1,
            verdict: verdict,
            rangeStart: nil,
            rangeEnd: nil,
            indoorStart: nil,
            indoorEnd: nil,
            scoresAnchorDate: "2026-10-17",
            dailyScoresJSON: "[]",
            reasoning: nil,
            fetchedAt: 1
        )
    }

    private static func location(_ id: String, _ name: String, deleted: Bool = false) -> LocalLocation {
        LocalLocation(
            id: id,
            householdID: household,
            name: name,
            sortOrder: 0,
            createdAt: 1,
            updatedAt: 1,
            deletedAt: deleted ? 2 : nil
        )
    }

    private static func tag(_ id: String, _ name: String, deleted: Bool = false) -> LocalTag {
        LocalTag(
            id: id,
            householdID: household,
            name: name,
            createdAt: 1,
            updatedAt: 1,
            deletedAt: deleted ? 2 : nil
        )
    }

    @Test("maps the display fields, state and update time")
    func mapsDisplayFields() {
        let seeds = [
            Self.seed(
                id: "s1",
                name: "Cherokee Purple",
                variety: "  Heirloom  ",
                type: "Tomato",
                company: "Baker Creek",
                year: 2024,
                packets: 3,
                state: .saved,
                notes: "Sunny bed",
                catalogID: "cat_1",
                updatedAt: 42
            ),
        ]
        let rows = SeedTableRow.rows(seeds: seeds, locations: [], tags: [], recommendations: [:])

        let row = try! #require(rows.first)
        #expect(row.id == "s1")
        #expect(row.name == "Cherokee Purple")
        #expect(row.variety == "Heirloom", "variety is trimmed")
        #expect(row.type == "Tomato")
        #expect(row.company == "Baker Creek")
        #expect(row.year == 2024)
        #expect(row.yearSortKey == 2024)
        #expect(row.packets == 3)
        #expect(row.state == "saved")
        #expect(row.notes == "Sunny bed")
        #expect(row.catalogID == "cat_1")
        #expect(row.updatedAt == 42)
    }

    @Test("a seed without a name shows the Library fallback, and blank fields become empty strings")
    func fallbacks() {
        let seeds = [Self.seed(id: "s1", name: nil, variety: "   ", type: nil, company: "")]
        let row = try! #require(SeedTableRow.rows(seeds: seeds, locations: [], tags: [], recommendations: [:]).first)

        #expect(row.name == "Untitled seed")
        #expect(row.variety == "")
        #expect(row.type == "")
        #expect(row.company == "")
        #expect(row.year == nil)
        #expect(row.yearSortKey == 0)
    }

    @Test("resolves location and tag names, and drops names for deleted or unknown ones")
    func resolvesNames() {
        let seeds = [
            Self.seed(id: "s1", locationID: "loc_shed", tagIDs: ["tag_a", "tag_deleted", "tag_gone"]),
            Self.seed(id: "s2", locationID: "loc_old"),
        ]
        let locations = [Self.location("loc_shed", "Shed"), Self.location("loc_old", "Attic", deleted: true)]
        let tags = [Self.tag("tag_a", "Heirloom"), Self.tag("tag_deleted", "Retired", deleted: true)]

        let rows = SeedTableRow.rows(seeds: seeds, locations: locations, tags: tags, recommendations: [:])
        let first = try! #require(rows.first { $0.id == "s1" })
        let second = try! #require(rows.first { $0.id == "s2" })

        #expect(first.locationName == "Shed")
        #expect(first.locationID == "loc_shed")
        #expect(first.tagNames == ["Heirloom"])
        #expect(first.tagIDs == ["tag_a", "tag_deleted", "tag_gone"], "writes must keep every tag id")
        #expect(first.tagsText == "Heirloom")
        #expect(second.locationName == "", "a deleted location is not shown")
        #expect(second.locationID == "loc_old")
    }

    @Test("skips deleted seeds")
    func skipsDeleted() {
        let seeds = [
            Self.seed(id: "live"),
            Self.seed(id: "gone", deletedAt: 5),
        ]
        let rows = SeedTableRow.rows(seeds: seeds, locations: [], tags: [], recommendations: [:])
        #expect(rows.map(\.id) == ["live"])
    }

    @Test("verdict is keyed by catalog id and worded as the app already words it")
    func verdictMapping() {
        let seeds = [
            Self.seed(id: "planted", catalogID: "cat_now"),
            Self.seed(id: "unknown", catalogID: "cat_odd"),
            Self.seed(id: "none", catalogID: "cat_missing"),
            Self.seed(id: "manual"),
        ]
        let recommendations = [
            "cat_now": Self.recommendation(catalogID: "cat_now", verdict: "plant_now"),
            "cat_odd": Self.recommendation(catalogID: "cat_odd", verdict: "mystery"),
        ]
        let rows = SeedTableRow.rows(seeds: seeds, locations: [], tags: [], recommendations: recommendations)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        #expect(byID["planted"]?.verdict == "plant_now")
        #expect(byID["planted"]?.verdictLabel == "Plant now")
        #expect(byID["unknown"]?.verdict == "mystery")
        #expect(byID["unknown"]?.verdictLabel == "Checking…")
        #expect(byID["none"]?.verdict == nil)
        #expect(byID["none"]?.verdictLabel == "")
        #expect(byID["manual"]?.verdict == nil, "a seed without a catalog link has no verdict")
    }

    @Test("verdict labels match the Library's wording")
    func verdictLabels() {
        #expect(SeedTableRow.verdictLabel(for: "plant_now") == "Plant now")
        #expect(SeedTableRow.verdictLabel(for: "plant_soon") == "Plant soon")
        #expect(SeedTableRow.verdictLabel(for: "too_early") == "Too early")
        #expect(SeedTableRow.verdictLabel(for: "late") == "Window closing")
        #expect(SeedTableRow.verdictLabel(for: "too_late") == "Missed this year")
        #expect(SeedTableRow.verdictLabel(for: "anything else") == "Checking…")
    }
}
