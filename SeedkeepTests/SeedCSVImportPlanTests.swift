import Foundation
import Testing
@testable import Seedkeep
import SeedkeepKit

/// CSV import, slice C: matching, ambiguity, duplicates, dependencies, and the round-trip update rules,
/// over value snapshots. Pure.
@Suite("Seeds CSV import — plan")
struct SeedCSVImportPlanTests {
    typealias Plan = SeedCSVImport.Plan
    typealias Named = SeedCSVImport.Snapshot.Named

    static let household = "hh_csv"
    static let shed = Named(id: "loc_shed", name: "Shed")
    static let fridge = Named(id: "loc_fridge", name: "Fridge")
    static let herb = Named(id: "tag_herb", name: "Herb")
    static let annual = Named(id: "tag_annual", name: "Annual")

    /// A seed as export shows it: location and tag names resolved against `locations` and `tags`.
    static func seed(
        _ id: String,
        name: String = "Basil",
        variety: String = "",
        type: String = "",
        company: String = "",
        year: Int? = nil,
        packets: Int = 1,
        state: String = "active",
        locationID: String? = nil,
        tagIDs: [String] = [],
        notes: String = "",
        catalogID: String? = nil,
        updatedAt: Int64 = 10,
        locations: [Named] = [shed, fridge],
        tags: [Named] = [herb, annual]
    ) -> SeedTableRow {
        let locationNames = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0.name) })
        let tagNames = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
        return SeedTableRow(
            id: id, name: name, variety: variety, type: type, company: company, year: year, packets: packets,
            state: state, locationID: locationID, locationName: locationID.flatMap { locationNames[$0] } ?? "",
            tagIDs: tagIDs, tagNames: tagIDs.compactMap { tagNames[$0] }, notes: notes, verdict: nil,
            verdictLabel: "", catalogID: catalogID, updatedAt: updatedAt
        )
    }

    static func snapshot(
        _ seeds: [SeedTableRow],
        locations: [Named] = [shed, fridge],
        tags: [Named] = [herb, annual]
    ) -> SeedCSVImport.Snapshot {
        SeedCSVImport.Snapshot(householdID: household, seeds: seeds, locations: locations, tags: tags)
    }

    static func plan(
        _ csv: String,
        _ snapshot: SeedCSVImport.Snapshot,
        saved: [Int: String] = [:]
    ) throws -> Plan {
        SeedCSVImport.plan(try SeedCSVImport.parse(csv), snapshot: snapshot, savedSeedIDs: saved)
    }

    static let identity = "name,variety,company,year"
    static let full = "name,variety,type,company,year,packets,status,stored_in,tags,notes,window"

    static func changes(_ plan: Plan, line: Int) -> SeedCSVImport.Changes? {
        guard case .update(_, _, let changes) = plan.rows.first(where: { $0.line == line })?.action else { return nil }
        return changes
    }

    static func action(_ plan: Plan, line: Int) -> SeedCSVImport.Action? {
        plan.rows.first(where: { $0.line == line })?.action
    }

    // MARK: - Matching

    @Test("matching uses trimmed, case-folded name, variety and company, and year as a number")
    func matchingKey() throws {
        let snapshot = Self.snapshot([Self.seed("s1", name: "Basil", variety: "Genovese", company: "Baker", year: 2024)])
        let plan = try Self.plan("\(Self.identity)\n  BASIL , genovese,BAKER , 2024\n", snapshot)
        #expect(Self.action(plan, line: 2) == .unchanged(seedID: "s1", targetUpdatedAt: 10))
        #expect(plan.matchingEnabled)
    }

    @Test("blank equals only blank: a blank variety doesn't match a seed with one")
    func blankMatchesOnlyBlank() throws {
        let snapshot = Self.snapshot([
            Self.seed("s1", name: "Basil", variety: "Genovese"),
            Self.seed("s2", name: "Dill", year: 2024),
        ])
        let plan = try Self.plan("\(Self.identity)\nBasil,,,\nDill,,,\n", snapshot)
        guard case .create = Self.action(plan, line: 2) else { Issue.record("expected a create"); return }
        guard case .create = Self.action(plan, line: 3) else { Issue.record("expected a create"); return }
    }

    @Test("names match the exported display name, including Untitled seed")
    func untitled() throws {
        let snapshot = Self.snapshot([Self.seed("s1", name: "Untitled seed", catalogID: "cat_1")])
        let plan = try Self.plan("\(Self.identity)\nuntitled seed,,,\n", snapshot)
        #expect(Self.action(plan, line: 2) == .unchanged(seedID: "s1", targetUpdatedAt: 10))
    }

    @Test("without all four identity columns, every valid row creates, even an exact copy")
    func matchingOff() throws {
        let snapshot = Self.snapshot([Self.seed("s1", name: "Basil", variety: "Genovese", company: "Baker", year: 2024)])
        let plan = try Self.plan("name,variety,company\nBasil,Genovese,Baker\nBasil,Genovese,Baker\n", snapshot)
        #expect(!plan.matchingEnabled)
        #expect(plan.newCount == 2, "no matching and no in-file duplicate check")
        #expect(plan.updatedCount == 0)
    }

    @Test("two existing seeds with the same key make the row ambiguous, and it's skipped")
    func ambiguousSeed() throws {
        let snapshot = Self.snapshot([Self.seed("s1", name: "Basil"), Self.seed("s2", name: "basil")])
        let plan = try Self.plan("\(Self.identity),notes\nBasil,,,,new note\n", snapshot)
        #expect(Self.action(plan, line: 2) == .skipped(.ambiguousSeed(count: 2)))
        #expect(plan.skippedCount == 1)
    }

    @Test("a key repeated in the file: the first valid row wins and later ones are skipped")
    func duplicatesInFile() throws {
        let csv = "\(Self.identity),packets,stored_in\n"
            + "Basil,,,,-1,Attic\n"     // line 2: invalid, doesn't count
            + "Basil,,,,2,Attic\n"      // line 3: first valid
            + "BASIL,,,,3,Garage\n"     // line 4: duplicate
        let plan = try Self.plan(csv, Self.snapshot([]))
        guard case .create(let seed) = Self.action(plan, line: 3) else { Issue.record("expected a create"); return }
        #expect(seed.packets == 2)
        #expect(Self.action(plan, line: 4) == .skipped(.duplicateInFile(firstLine: 3)))
        #expect(plan.errorRowCount == 1)
        #expect(plan.newLocations.map(\.name) == ["Attic"], "the skipped row's location isn't created")
    }

    // MARK: - Locations and tags

    @Test("locations and tags resolve by trimmed, case-folded name")
    func resolveByName() throws {
        let plan = try Self.plan("name,stored_in,tags\nBasil, shed ,HERB; annual\n", Self.snapshot([]))
        guard case .create(let seed) = Self.action(plan, line: 2) else { Issue.record("expected a create"); return }
        #expect(seed.location == .existing("loc_shed"))
        #expect(seed.tags == [.existing("tag_herb"), .existing("tag_annual")])
        #expect(plan.newLocations.isEmpty && plan.newTags.isEmpty)
    }

    @Test("two locations or tags with the same name make the row ambiguous")
    func ambiguousDependencies() throws {
        let locations = [Self.shed, Named(id: "loc_shed2", name: "SHED")]
        let tags = [Self.herb, Named(id: "tag_herb2", name: " herb")]
        let snapshot = Self.snapshot([], locations: locations, tags: tags)
        let plan = try Self.plan("name,stored_in,tags\nA,Shed,\nB,,Herb\nC,,\n", snapshot)
        #expect(Self.action(plan, line: 2) == .skipped(.ambiguousLocation("Shed")))
        #expect(Self.action(plan, line: 3) == .skipped(.ambiguousTag("Herb")))
        #expect(plan.newCount == 1)
    }

    @Test("new locations and tags are created once each, with the file's first spelling, only for rows that run")
    func newDependencies() throws {
        let snapshot = Self.snapshot([Self.seed("s1", name: "Kale"), Self.seed("s2", name: "Dup"), Self.seed("s3", name: "dup")])
        let csv = "\(Self.identity),stored_in,tags\n"
            + "Basil,,,,attic,Spicy; Green\n"
            + "Dill,,,,ATTIC,green; Tall\n"
            + "Dup,,,,Cellar,Skipped\n"      // ambiguous seed: its new names aren't created
            + "Kale,,,,Attic,\n"             // update to a new location
        let plan = try Self.plan(csv, snapshot)
        #expect(plan.newLocations == [SeedCSVImport.NewDependency(key: SeedCSVImport.normalized("attic"), name: "attic")])
        #expect(plan.newTags.map(\.name) == ["Spicy", "Green", "Tall"])
        #expect(Self.changes(plan, line: 5)?.location == .some(.new(SeedCSVImport.normalized("attic"))))
    }

    // MARK: - Creates

    @Test("creates use defaults: active, one packet, and blank text left out")
    func createDefaults() throws {
        let plan = try Self.plan("name,type,notes\nBasil,,\nDill,Herb,Feathery\n", Self.snapshot([]))
        #expect(Self.action(plan, line: 2) == .create(SeedCSVImport.NewSeed(
            name: "Basil", variety: nil, company: nil, year: nil, packets: 1, state: .active,
            location: nil, tags: [], notes: nil, type: nil
        )))
        guard case .create(let dill) = Self.action(plan, line: 3) else { Issue.record("expected a create"); return }
        #expect(dill.type == "Herb")
        #expect(dill.notes == "Feathery")
    }

    @Test("a blank packets on create is 0 on the wishlist and 1 otherwise, as Add Seed sets it")
    func createPacketsDefault() throws {
        let plan = try Self.plan("name,status\nBasil,wishlist\nDill,saved\nKale,\n", Self.snapshot([]))
        let packets = plan.rows.compactMap { row -> Int? in
            if case .create(let seed) = row.action { return seed.packets } else { return nil }
        }
        #expect(packets == [0, 1, 1])
    }

    @Test("a skipped row doesn't claim its key: the next row with that key is used, not a duplicate")
    func skippedRowDoesNotClaimKey() throws {
        let locations = [Self.shed, Named(id: "loc_shed2", name: "shed")]
        let snapshot = Self.snapshot([], locations: locations)
        let csv = "\(Self.identity),stored_in\n"
            + "Basil,,,,Shed\n"     // line 2: ambiguous location, skipped
            + "Basil,,,,Fridge\n"   // line 3: the first row used
            + "Basil,,,,\n"         // line 4: duplicate of line 3
        let plan = try Self.plan(csv, snapshot)
        #expect(Self.action(plan, line: 2) == .skipped(.ambiguousLocation("Shed")))
        guard case .create = Self.action(plan, line: 3) else { Issue.record("expected a create"); return }
        #expect(Self.action(plan, line: 4) == .skipped(.duplicateInFile(firstLine: 3)))
    }

    @Test("creates keep the file's packets and status")
    func createValues() throws {
        let plan = try Self.plan("name,packets,status,year\nBasil,0,wishlist,2023\n", Self.snapshot([]))
        guard case .create(let seed) = Self.action(plan, line: 2) else { Issue.record("expected a create"); return }
        #expect(seed.packets == 0)
        #expect(seed.state == .wishlist)
        #expect(seed.year == 2023)
    }

    // MARK: - Update rules

    @Test("a blank type, notes or stored_in clears it")
    func blanksClear() throws {
        let snapshot = Self.snapshot([Self.seed("s1", type: "Herb", locationID: "loc_shed", notes: "Old")])
        let plan = try Self.plan("\(Self.identity),type,notes,stored_in\nBasil,,,,,,\n", snapshot)
        let changes = try #require(Self.changes(plan, line: 2))
        #expect(changes.type == .some(nil))
        #expect(changes.notes == .some(nil))
        #expect(changes.location == .some(nil))
        #expect(changes.state == nil && changes.packets == nil && changes.tags == nil)
    }

    @Test("a blank packets or status leaves it alone")
    func blanksLeaveAlone() throws {
        let snapshot = Self.snapshot([Self.seed("s1", packets: 4, state: "saved")])
        let plan = try Self.plan("\(Self.identity),packets,status\nBasil,,,,,\n", snapshot)
        #expect(Self.action(plan, line: 2) == .unchanged(seedID: "s1", targetUpdatedAt: 10))
    }

    @Test("a blank stored_in leaves a location that no longer resolves alone; a name replaces it")
    func unresolvedLocation() throws {
        let snapshot = Self.snapshot([Self.seed("s1", locationID: "loc_deleted")])
        let blank = try Self.plan("\(Self.identity),stored_in\nBasil,,,,\n", snapshot)
        #expect(Self.action(blank, line: 2) == .unchanged(seedID: "s1", targetUpdatedAt: 10))
        let named = try Self.plan("\(Self.identity),stored_in\nBasil,,,,Fridge\n", snapshot)
        #expect(Self.changes(named, line: 2)?.location == .some(.existing("loc_fridge")))
    }

    @Test("tags replace the named tags and always keep unresolved ids; a blank clears only named ones")
    func tagsRules() throws {
        let snapshot = Self.snapshot([Self.seed("s1", tagIDs: ["tag_herb", "tag_gone"])])
        let blank = try Self.plan("\(Self.identity),tags\nBasil,,,,\n", snapshot)
        #expect(Self.changes(blank, line: 2)?.tags == [.existing("tag_gone")])

        let replaced = try Self.plan("\(Self.identity),tags\nBasil,,,,Annual; New\n", snapshot)
        #expect(Self.changes(replaced, line: 2)?.tags == [
            .existing("tag_annual"), .new(SeedCSVImport.normalized("New")), .existing("tag_gone"),
        ])

        let same = try Self.plan("\(Self.identity),tags\nBasil,,,,herb\n", snapshot)
        #expect(Self.action(same, line: 2) == .unchanged(seedID: "s1", targetUpdatedAt: 10))
    }

    @Test("reordered tags are not a change")
    func tagOrder() throws {
        let snapshot = Self.snapshot([Self.seed("s1", tagIDs: ["tag_herb", "tag_annual"])])
        let plan = try Self.plan("\(Self.identity),tags\nBasil,,,,Annual; Herb\n", snapshot)
        #expect(Self.action(plan, line: 2) == .unchanged(seedID: "s1", targetUpdatedAt: 10))
    }

    @Test("absent columns leave their fields alone")
    func absentColumns() throws {
        let snapshot = Self.snapshot([Self.seed("s1", type: "Herb", packets: 3, state: "saved",
                                                locationID: "loc_shed", tagIDs: ["tag_herb"], notes: "Keep")])
        let plan = try Self.plan("\(Self.identity)\nBasil,,,\n", snapshot)
        #expect(Self.action(plan, line: 2) == .unchanged(seedID: "s1", targetUpdatedAt: 10))
    }

    @Test("changed values produce only those fields; identity case differences change nothing")
    func onlyChangedFields() throws {
        let snapshot = Self.snapshot([Self.seed("s1", name: "Basil", type: "Herb", packets: 1, notes: "Old")])
        let plan = try Self.plan("\(Self.identity),type,packets,status,notes\nBASIL,,,,Herb,5,active,  Old  \n", snapshot)
        let changes = try #require(Self.changes(plan, line: 2))
        #expect(changes == SeedCSVImport.Changes(packets: 5))
        #expect(!changes.patchIsEmpty)
    }

    @Test("a padded stored type round-trips unchanged")
    func paddedType() throws {
        let snapshot = Self.snapshot([Self.seed("s1", type: " Herb ")])
        let plan = try Self.plan("\(Self.identity),type\nBasil,,,, Herb \n", snapshot)
        #expect(Self.action(plan, line: 2) == .unchanged(seedID: "s1", targetUpdatedAt: 10))
    }

    @Test("a type-only change has an empty patch")
    func typeOnly() throws {
        let snapshot = Self.snapshot([Self.seed("s1", type: "Herb")])
        let plan = try Self.plan("\(Self.identity),type\nBasil,,,,Spice\n", snapshot)
        let changes = try #require(Self.changes(plan, line: 2))
        #expect(changes.type == .some("Spice"))
        #expect(changes.patchIsEmpty)
        #expect(!changes.isEmpty)
    }

    @Test("a retry targets the seed saved from that row, even with matching off")
    func retryReusesSavedSeed() throws {
        let snapshot = Self.snapshot([Self.seed("s_saved", name: "Basil", type: "")])
        let plan = try Self.plan("name,type\nBasil,Herb\nDill,\n", snapshot, saved: [2: "s_saved"])
        #expect(Self.changes(plan, line: 2) == SeedCSVImport.Changes(type: .some("Herb")))
        guard case .create = Self.action(plan, line: 3) else { Issue.record("expected a create"); return }

        let gone = try Self.plan("name,type\nBasil,Herb\n", Self.snapshot([]), saved: [2: "s_saved"])
        #expect(Self.action(gone, line: 2) == .skipped(.savedSeedGone))
    }

    @Test("two rows can't target the same seed: a retry's saved row keeps it and the other row is skipped")
    func oneRowPerSeed() throws {
        let snapshot = Self.snapshot([Self.seed("s1", name: "Basil")])
        // Line 3 saved s1 in an earlier attempt (its name has since changed in the file); line 2 key-matches s1.
        let plan = try Self.plan("\(Self.identity),packets\nBasil,,,,2\nBasil Renamed,,,,3\n", snapshot, saved: [3: "s1"])
        #expect(Self.action(plan, line: 2) == .skipped(.seedUsedByLine(3)))
        #expect(Self.changes(plan, line: 3) == SeedCSVImport.Changes(packets: 3))
    }

    // MARK: - Round trip

    /// Seeds with a catalog link, unresolved tags, a deleted location, guarded text, apostrophes, tag
    /// names with ; and \, multi-line notes, and an untitled seed.
    static let roundTripLocations = [shed, fridge]
    static let roundTripTags = [herb, annual, Named(id: "tag_semi", name: "a;b\\c"), Named(id: "tag_eq", name: "=sum")]
    static let roundTripSeeds: [SeedTableRow] = [
        seed("r1", name: "Cherokee Purple", variety: "Heirloom", type: "Tomato", company: "Baker Creek", year: 2024,
             packets: 3, state: "saved", locationID: "loc_shed", tagIDs: ["tag_herb", "tag_gone"],
             notes: "Sunny, \"warm\"\nspot", catalogID: "cat_1", tags: roundTripTags),
        seed("r2", name: "=cmd", variety: "'quoted", type: "-dash", company: "@co", packets: 0, state: "wishlist",
             locationID: "loc_deleted", tagIDs: ["tag_semi", "tag_eq"], notes: "'apostrophe", tags: roundTripTags),
        seed("r3", name: "Untitled seed", catalogID: "cat_2", tags: roundTripTags),
        seed("r4", name: "Ñandú", year: 1999, packets: 12, state: "archived", locationID: "loc_fridge",
             notes: "  padded  ", tags: roundTripTags),
    ]

    @Test("export, then import into the same snapshot: everything is unchanged")
    func roundTripNoOp() throws {
        let snapshot = Self.snapshot(Self.roundTripSeeds, locations: Self.roundTripLocations, tags: Self.roundTripTags)
        let csv = SeedCSV.make(Self.roundTripSeeds)
        let plan = SeedCSVImport.plan(try SeedCSVImport.parse(data: SeedCSV.data(for: Self.roundTripSeeds)), snapshot: snapshot)
        #expect(plan.issues.isEmpty)
        #expect(plan.unchangedCount == Self.roundTripSeeds.count, "\(plan.rows)")
        #expect(plan.writeCount == 0)
        #expect(plan.newLocations.isEmpty && plan.newTags.isEmpty)
        #expect(!csv.isEmpty)
    }

    @Test("export, edit one non-identity cell, import: only that field changes")
    func roundTripOneEdit() throws {
        let snapshot = Self.snapshot(Self.roundTripSeeds, locations: Self.roundTripLocations, tags: Self.roundTripTags)
        var edited = Self.roundTripSeeds
        edited[1].notes = "new note"
        let plan = SeedCSVImport.plan(try SeedCSVImport.parse(SeedCSV.make(edited)), snapshot: snapshot)
        #expect(plan.updatedCount == 1)
        #expect(plan.unchangedCount == Self.roundTripSeeds.count - 1)
        #expect(Self.changes(plan, line: 4) == SeedCSVImport.Changes(notes: .some("new note")))
    }

    @Test("export, edit an identity cell, import: a new seed is created and nothing is updated")
    func roundTripIdentityEdit() throws {
        let snapshot = Self.snapshot(Self.roundTripSeeds, locations: Self.roundTripLocations, tags: Self.roundTripTags)
        var edited = Self.roundTripSeeds
        edited[0].company = "Johnny's"
        let plan = SeedCSVImport.plan(try SeedCSVImport.parse(SeedCSV.make(edited)), snapshot: snapshot)
        #expect(plan.newCount == 1)
        #expect(plan.updatedCount == 0)
    }

    @Test("an identity edit that collides with two existing seeds is skipped as ambiguous")
    func roundTripIdentityEditAmbiguous() throws {
        var seeds = Self.roundTripSeeds
        seeds.append(Self.seed("r5", name: "Kale", tags: Self.roundTripTags))
        seeds.append(Self.seed("r6", name: "kale", tags: Self.roundTripTags))
        let snapshot = Self.snapshot(seeds, locations: Self.roundTripLocations, tags: Self.roundTripTags)
        var edited = Self.roundTripSeeds
        edited[3].name = "KALE"
        edited[3].year = nil
        let plan = SeedCSVImport.plan(try SeedCSVImport.parse(SeedCSV.make(edited)), snapshot: snapshot)
        #expect(Self.action(plan, line: 6) == .skipped(.ambiguousSeed(count: 2)), "r1's notes span two lines")
    }

    // MARK: - Performance

    @Test("a 5,000-row plan against 5,000 seeds stays within a generous time budget")
    func performance() throws {
        var seeds: [SeedTableRow] = []
        var lines = [Self.full]
        for index in 0..<5_000 {
            seeds.append(Self.seed("s\(index)", name: "Seed \(index)", variety: "V\(index % 50)",
                                   company: "Co \(index % 20)", year: 2000 + index % 25, locationID: "loc_shed",
                                   tagIDs: ["tag_herb"]))
            lines.append("Seed \(index),V\(index % 50),Type,Co \(index % 20),\(2000 + index % 25),2,active,Shed,Herb; Annual,Note \(index),")
        }
        let csv = lines.joined(separator: "\r\n") + "\r\n"
        let snapshot = Self.snapshot(seeds)
        let clock = ContinuousClock()
        var plan: Plan?
        let elapsed = try clock.measure {
            plan = SeedCSVImport.plan(try SeedCSVImport.parse(csv), snapshot: snapshot)
        }
        #expect(plan?.updatedCount == 5_000)
        #expect(elapsed < .seconds(20), "parse + plan took \(elapsed)")
    }
}
