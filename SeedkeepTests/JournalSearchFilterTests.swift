import Foundation
import SeedkeepKit
import SwiftData
import Testing
@testable import Seedkeep

/// Tests for the Journal search and filter rules: tokens, the filters, the criteria, the feed's
/// header and empty states, the filter menu, the memoized feed, and the save-time check. The pure rules
/// run on model rows built in memory. The save lookup runs on the in-memory store.
@MainActor
@Suite("Journal — search and filters")
struct JournalSearchFilterTests {
    private static let garden = "garden"

    private static func seed(
        _ id: String,
        _ name: String?,
        household: String = garden,
        deletedAt: Int64? = nil
    ) -> LocalSeed {
        LocalSeed(
            id: id, householdID: household, state: .active, packetCount: 1, source: .store,
            customName: name, createdAt: 0, updatedAt: 0, deletedAt: deletedAt)
    }

    private static func bed(
        _ id: String,
        _ name: String,
        sortOrder: Int = 0,
        household: String = garden,
        deletedAt: Int64? = nil
    ) -> LocalBed {
        LocalBed(
            id: id, householdID: household, name: name, sortOrder: sortOrder,
            createdAt: 0, updatedAt: 0, deletedAt: deletedAt)
    }

    private static func planting(
        _ id: String,
        kind: String = "sowing",
        on date: String = "2026-05-01",
        seed: String? = nil,
        bed: String? = nil,
        notes: String? = nil,
        household: String = garden,
        deletedAt: Int64? = nil
    ) -> LocalPlantingEvent {
        LocalPlantingEvent(
            id: id, householdID: household, bedID: bed, seedID: seed, kindRaw: kind,
            plannedFor: date, notes: notes, createdAt: 0, updatedAt: 0, deletedAt: deletedAt)
    }

    private static func entry(
        _ id: String,
        _ body: String,
        on date: String = "2026-05-02",
        seed: String? = nil,
        bed: String? = nil,
        planting: String? = nil,
        household: String = garden,
        updatedAt: Int64 = 0,
        deletedAt: Int64? = nil
    ) -> LocalJournalEntry {
        LocalJournalEntry(
            id: id, householdID: household, occurredOn: date, body: body,
            seedID: seed, bedID: bed, plantingEventID: planting,
            createdAt: 0, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    private static func index(
        seeds: [LocalSeed] = [],
        beds: [LocalBed] = [],
        plantings: [LocalPlantingEvent] = []
    ) -> JournalEntityIndex {
        JournalEntityIndex(householdID: garden, seeds: seeds, beds: beds, plantings: plantings)
    }

    private static func apply(
        _ rows: [LocalJournalEntry],
        search: String = "",
        filter: JournalTarget? = nil,
        index: JournalEntityIndex
    ) -> [String] {
        JournalFilter.apply(rows, searchText: search, filter: filter, index: index).map(\.id)
    }

    // MARK: - Search

    @Test func blankSearchIsNoSearch() {
        #expect(JournalFilter.tokens(for: "").isEmpty)
        #expect(JournalFilter.tokens(for: " \n\t ").isEmpty)
        #expect(!JournalCriteria(searchText: "   ").isActive)
        #expect(JournalCriteria(searchText: " tomato ").isActive)
    }

    @Test func blankSearchShowsEveryRow() {
        let rows = [Self.entry("a", "one"), Self.entry("b", "two")]
        #expect(Self.apply(rows, search: "   ", index: Self.index()) == ["a", "b"])
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        let rows = [Self.entry("e1", "Café tomatoes, watered"), Self.entry("e2", "Beans")]
        #expect(Self.apply(rows, search: "cAFE TOMATOÉS", index: Self.index()) == ["e1"])
        #expect(JournalFilter.tokens(for: "  CAFÉ   Tomatoes ") == ["cafe", "tomatoes"])
    }

    @Test func everyTokenMustMatchSomeField() {
        let index = Self.index(seeds: [Self.seed("s", "Brandywine")])
        let rows = [Self.entry("e1", "Watered the beans", seed: "s")]
        #expect(Self.apply(rows, search: "brandywine beans", index: index) == ["e1"])
        #expect(Self.apply(rows, search: "watered brandywine", index: index) == ["e1"])
        #expect(Self.apply(rows, search: "brandywine zucchini", index: index).isEmpty)
    }

    @Test func searchReachesBedAndPlantingNames() {
        let index = Self.index(
            seeds: [Self.seed("s", "Brandywine")],
            beds: [Self.bed("b", "North bed")],
            plantings: [Self.planting("p", seed: "s")])
        let rows = [
            Self.entry("onBed", "Mulched", bed: "b"),
            Self.entry("onPlanting", "Thinned", planting: "p"),
        ]
        #expect(Self.apply(rows, search: "north mulched", index: index) == ["onBed"])
        #expect(Self.apply(rows, search: "sow brandywine", index: index) == ["onPlanting"])
    }

    @Test func deletedAttachmentStillMatchesOnBody() {
        let index = Self.index(seeds: [Self.seed("s", "Brandywine", deletedAt: 5)])
        let rows = [Self.entry("e1", "Tomato sauce", seed: "s")]
        #expect(Self.apply(rows, search: "tomato", index: index) == ["e1"])
        #expect(Self.apply(rows, search: "brandywine", index: index).isEmpty)
    }

    @Test func plantingLabelDoesNotSearchTheNoteText() {
        let index = Self.index(plantings: [Self.planting("p", kind: "harvest", notes: "First ripe")])
        let rows = [Self.entry("e1", "Picked", planting: "p")]
        #expect(Self.apply(rows, search: "ripe", index: index).isEmpty)
        #expect(Self.apply(rows, search: "harvest note", index: index) == ["e1"])
    }

    // MARK: - Filters

    @Test func seedFilterReachesEntriesOnItsPlantings() {
        let index = Self.index(
            seeds: [Self.seed("s", "Brandywine"), Self.seed("t", "Cherokee")],
            plantings: [Self.planting("p", seed: "s"), Self.planting("q", seed: "t")])
        let rows = [
            Self.entry("onSeed", "a", seed: "s"),
            Self.entry("onPlantingOfSeed", "b", planting: "p"),
            Self.entry("onOtherPlanting", "c", planting: "q"),
            Self.entry("onOtherSeed", "d", seed: "t"),
            Self.entry("garden", "e"),
        ]
        #expect(Self.apply(rows, filter: .seed("s"), index: index) == ["onSeed", "onPlantingOfSeed"])
    }

    @Test func bedFilterReachesEntriesOnPlantingsInTheBed() {
        let index = Self.index(
            beds: [Self.bed("b1", "North"), Self.bed("b2", "South")],
            plantings: [Self.planting("p", bed: "b1"), Self.planting("q", bed: "b2")])
        let rows = [
            Self.entry("onBed", "a", bed: "b1"),
            Self.entry("onPlanting", "b", planting: "p"),
            Self.entry("onOtherBed", "c", bed: "b2"),
            Self.entry("onOtherPlanting", "d", planting: "q"),
        ]
        #expect(Self.apply(rows, filter: .bed("b1"), index: index) == ["onBed", "onPlanting"])
    }

    @Test func plantingFilterMatchesOnlyThatPlanting() {
        let index = Self.index(
            seeds: [Self.seed("s", "Brandywine")],
            plantings: [Self.planting("p", seed: "s"), Self.planting("q", seed: "s")])
        let rows = [
            Self.entry("onP", "a", planting: "p"),
            Self.entry("onQ", "b", planting: "q"),
            Self.entry("onSeed", "c", seed: "s"),
        ]
        #expect(Self.apply(rows, filter: .plantingEvent("p"), index: index) == ["onP"])
    }

    @Test func filterAndSearchBothHold() {
        let index = Self.index(seeds: [Self.seed("s", "Brandywine"), Self.seed("t", "Cherokee")])
        let rows = [
            Self.entry("match", "frost came", seed: "s"),
            Self.entry("wrongWord", "watered", seed: "s"),
            Self.entry("wrongSeed", "frost came", seed: "t"),
        ]
        #expect(Self.apply(rows, search: "frost", filter: .seed("s"), index: index) == ["match"])
    }

    @Test func deletedPlantingStillCarriesItsEntriesToSeedAndBedFilters() {
        // P was on seed S and bed B, and is now deleted. Its surviving entry still belongs to S and B.
        let index = Self.index(
            seeds: [Self.seed("s", "Brandywine")],
            beds: [Self.bed("b", "North")],
            plantings: [Self.planting("p", seed: "s", bed: "b", deletedAt: 5)])
        let rows = [
            Self.entry("onDeletedPlanting", "Sowed", planting: "p"),
            Self.entry("onSeed", "Watered", seed: "s"),
            Self.entry("onBed", "Mulched", bed: "b"),
            Self.entry("garden", "Other"),
        ]
        #expect(Self.apply(rows, filter: .seed("s"), index: index) == ["onDeletedPlanting", "onSeed"])
        #expect(Self.apply(rows, filter: .bed("b"), index: index) == ["onDeletedPlanting", "onBed"])
    }

    @Test func deletedPlantingIsOutOfTheMenuAndItsOwnFilterIsDropped() {
        let index = Self.index(plantings: [Self.planting("p", deletedAt: 5), Self.planting("q")])
        #expect(index.plantingOptions.map(\.target) == [.plantingEvent("q")])
        #expect(!index.contains(.plantingEvent("p")))
        var criteria = JournalCriteria(filter: .plantingEvent("p"))
        criteria.dropFilterIfMissing(from: index)
        #expect(criteria.filter == nil)
    }

    @Test func filterMenuOffersEveryLiveRowNotJustTheLatestTwenty() {
        let plantings = (1...25).map { day in
            Self.planting("p\(day)", on: "2026-04-\(String(format: "%02d", day))")
        }
        let index = Self.index(
            plantings: plantings + [
                Self.planting("deleted", on: "2026-06-01", deletedAt: 5),
                Self.planting("elsewhere", on: "2026-06-02", household: "other"),
            ])
        let options = index.plantingOptions
        #expect(options.count == 25)
        // Most recent first.
        #expect(options.first?.target == .plantingEvent("p25"))
        #expect(options.last?.target == .plantingEvent("p1"))
    }

    @Test func menuListsSeedsByNameAndBedsInGardenOrder() {
        let index = Self.index(
            seeds: [
                Self.seed("z", "Zucchini"),
                Self.seed("a", "apple"),
                Self.seed("u", nil),
                Self.seed("gone", "Gone", deletedAt: 5),
                Self.seed("other", "Other garden", household: "other"),
            ],
            beds: [Self.bed("late", "Late", sortOrder: 2), Self.bed("early", "Early", sortOrder: 1)])
        #expect(index.seedOptions.map(\.label) == ["apple", "Untitled seed", "Zucchini"])
        #expect(index.bedOptions.map(\.target) == [.bed("early"), .bed("late")])
    }

    // MARK: - Labels

    @Test func plantingLabelIsKindDateAndSeedOrNote() {
        let index = Self.index(
            seeds: [Self.seed("s", "Brandywine")],
            plantings: [
                Self.planting("withSeed", kind: "sowing", seed: "s"),
                Self.planting("noSeed", kind: "harvest"),
                Self.planting("bare", kind: "note"),
            ])
        #expect(index.label(for: .plantingEvent("withSeed")) == "Sow · 2026-05-01 · Brandywine")
        #expect(index.label(for: .plantingEvent("noSeed")) == "Harvest · 2026-05-01 · Note")
        #expect(index.label(for: .plantingEvent("bare")) == "Note · 2026-05-01 · Note")
    }

    @Test func plantingLabelNeverShowsTheFreeTextNote() {
        let index = Self.index(plantings: [Self.planting("p", kind: "harvest", notes: "First ripe")])
        #expect(index.label(for: .plantingEvent("p")) == "Harvest · 2026-05-01 · Note")
        #expect(index.plantingOptions.map(\.label) == ["Harvest · 2026-05-01 · Note"])
        #expect(JournalFeedPresentation.chipTitle(.plantingEvent("p"), label: "Harvest · 2026-05-01 · Note")
            == "Planting: Harvest · 2026-05-01 · Note")
    }

    @Test func indexLeavesOutOtherHouseholdsAndDeletedRows() {
        let index = Self.index(
            seeds: [Self.seed("a", "Apple"), Self.seed("b", "Banana", household: "other")],
            plantings: [Self.planting("gone", seed: "a", deletedAt: 5)])
        #expect(index.seedOptions.map(\.target) == [.seed("a")])
        #expect(index.plantingOptions.isEmpty)
        #expect(index.label(for: .plantingEvent("gone")) == nil)
        #expect(!index.contains(.seed("b")))
    }

    // MARK: - Criteria and feed

    @Test func initialFilterIsTheParentAndClearingShowsTheWholeFeed() {
        let index = Self.index(seeds: [Self.seed("s", "Brandywine")])
        let rows = [Self.entry("onSeed", "a", seed: "s"), Self.entry("garden", "b")]
        var criteria = JournalCriteria(filter: .seed("s"))
        #expect(criteria.filter == .seed("s"))
        #expect(criteria.isActive)
        #expect(Self.apply(rows, filter: criteria.filter, index: index) == ["onSeed"])

        criteria.clear()
        #expect(!criteria.isActive)
        #expect(Self.apply(rows, filter: criteria.filter, index: index) == ["onSeed", "garden"])
    }

    @Test func householdChangeClearsTheFilterAndKeepsTheSearch() {
        var criteria = JournalCriteria(filter: .seed("s"), searchText: "frost")
        criteria.clearFilter()
        #expect(criteria.filter == nil)
        #expect(criteria.searchText == "frost")
    }

    @Test func deletingTheFilteredRowDropsTheFilter() {
        var criteria = JournalCriteria(filter: .seed("s"))
        criteria.dropFilterIfMissing(from: Self.index(seeds: [Self.seed("s", "Brandywine")]))
        #expect(criteria.filter == .seed("s"))
        criteria.dropFilterIfMissing(from: Self.index(seeds: [Self.seed("s", "Brandywine", deletedAt: 5)]))
        #expect(criteria.filter == nil)
    }

    @Test func feedCountsTheHouseholdAndTheCriteria() {
        let index = Self.index(seeds: [Self.seed("s", "Brandywine")])
        var entries = (1...41).map { Self.entry("e\($0)", "entry \($0)") }
        entries[0] = Self.entry("onSeed1", "frost", seed: "s")
        entries[1] = Self.entry("onSeed2", "frost", seed: "s")
        entries[2] = Self.entry("onSeed3", "frost", seed: "s")
        entries.append(Self.entry("deleted", "gone", deletedAt: 5))
        entries.append(Self.entry("elsewhere", "other garden", household: "other"))

        let unfiltered = JournalFeed(
            householdID: Self.garden, entries: entries, index: index, criteria: JournalCriteria())
        #expect(unfiltered.total == 41)
        #expect(unfiltered.shown.count == 41)
        #expect(JournalFeedPresentation.subtitle(total: unfiltered.total, shown: unfiltered.shown.count, isActive: false)
            == "41 entries · the household garden")

        let filtered = JournalFeed(
            householdID: Self.garden, entries: entries, index: index,
            criteria: JournalCriteria(filter: .seed("s"), searchText: "frost"))
        #expect(filtered.total == 41)
        #expect(filtered.shown.count == 3)
        #expect(JournalFeedPresentation.subtitle(total: filtered.total, shown: filtered.shown.count, isActive: true)
            == "3 of 41 entries")
    }

    @Test func feedWithNoHouseholdShowsNothing() {
        let index = JournalEntityIndex(householdID: nil, seeds: [], beds: [], plantings: [])
        let feed = JournalFeed(
            householdID: nil, entries: [Self.entry("e", "a")], index: index, criteria: JournalCriteria())
        #expect(feed.total == 0)
        #expect(feed.shown.isEmpty)
    }

    // MARK: - Memoized feed

    @Test func entityIndexIsBuiltOncePerDataChange() {
        let cache = JournalFeedCache()
        let seed = Self.seed("s", "Brandywine")
        let entries = [Self.entry("e1", "a", seed: "s")]
        _ = cache.feed(
            householdID: Self.garden, entries: entries, seeds: [seed], beds: [], plantings: [],
            criteria: JournalCriteria(searchText: "a"))
        _ = cache.feed(
            householdID: Self.garden, entries: entries, seeds: [seed], beds: [], plantings: [],
            criteria: JournalCriteria(filter: .seed("s")))
        _ = cache.feed(
            householdID: Self.garden, entries: entries, seeds: [seed], beds: [], plantings: [],
            criteria: JournalCriteria(filter: .seed("s"), searchText: "brandy"))
        #expect(cache.indexBuildCount == 1)

        seed.customName = "Cherokee"
        _ = cache.feed(
            householdID: Self.garden, entries: entries, seeds: [seed], beds: [], plantings: [],
            criteria: JournalCriteria(searchText: "a"))
        #expect(cache.indexBuildCount == 2)
    }

    @Test func cachedBodyFollowsAnEntryEdit() {
        let cache = JournalFeedCache()
        let before = cache.feed(
            householdID: Self.garden, entries: [Self.entry("e1", "Frost on the beans", updatedAt: 1)],
            seeds: [], beds: [], plantings: [], criteria: JournalCriteria(searchText: "frost"))
        #expect(before.shown.map(\.id) == ["e1"])

        let after = cache.feed(
            householdID: Self.garden, entries: [Self.entry("e1", "Watered the beans", updatedAt: 2)],
            seeds: [], beds: [], plantings: [], criteria: JournalCriteria(searchText: "frost"))
        #expect(after.shown.isEmpty)
    }

    @Test func threeThousandEntrySearchRunsWithinABound() {
        let seeds = (1...5).map { Self.seed("s\($0)", "Seed \($0)") }
        let plantings = (1...200).map { Self.planting("p\($0)", seed: "s\($0 % 5 + 1)") }
        let entries = (1...3_000).map { n -> LocalJournalEntry in
            let body = n % 100 == 0 ? "Frost on the beans \(n)" : "Watered the tomatoes \(n)"
            let attached: String? = n % 2 == 0 ? "p\(n % 200 + 1)" : nil
            return Self.entry("e\(n)", body, planting: attached)
        }
        let cache = JournalFeedCache()

        var first: JournalFeed?
        let firstTime = ContinuousClock().measure {
            first = cache.feed(
                householdID: Self.garden, entries: entries, seeds: seeds, beds: [], plantings: plantings,
                criteria: JournalCriteria(searchText: "frost"))
        }
        #expect(first?.shown.count == 30)
        #expect(firstTime < .seconds(2))

        var second: JournalFeed?
        let secondTime = ContinuousClock().measure {
            second = cache.feed(
                householdID: Self.garden, entries: entries, seeds: seeds, beds: [], plantings: plantings,
                criteria: JournalCriteria(searchText: "frost beans"))
        }
        #expect(second?.shown.count == 30)
        #expect(secondTime < .seconds(2))
        #expect(cache.indexBuildCount == 1)
    }

    // MARK: - Presentation

    @Test func headerReadsTheCountWhileFilteredAndNotOtherwise() {
        #expect(JournalFeedPresentation.subtitle(total: 41, shown: 3, isActive: true) == "3 of 41 entries")
        #expect(JournalFeedPresentation.subtitle(total: 1, shown: 1, isActive: true) == "1 of 1 entry")
        #expect(JournalFeedPresentation.subtitle(total: 41, shown: 41, isActive: false)
            == "41 entries · the household garden")
        #expect(JournalFeedPresentation.subtitle(total: 1, shown: 1, isActive: false)
            == "1 entry · the household garden")
    }

    @Test func emptyStatesAreLoadingNoMatchesOrStart() {
        #expect(JournalFeedPresentation.emptyState(shownIsEmpty: false, isSyncing: true, isActive: true) == nil)
        #expect(JournalFeedPresentation.emptyState(shownIsEmpty: true, isSyncing: true, isActive: true) == .loading)
        #expect(JournalFeedPresentation.emptyState(shownIsEmpty: true, isSyncing: false, isActive: true) == .noMatches)
        #expect(JournalFeedPresentation.emptyState(shownIsEmpty: true, isSyncing: false, isActive: false) == .startJournal)
    }

    @Test func resultAnnouncementSaysNoMatchOrTheCount() {
        #expect(JournalFeedPresentation.resultAnnouncement(total: 41, shown: 0) == "No entries match")
        #expect(JournalFeedPresentation.resultAnnouncement(total: 41, shown: 3) == "3 of 41 entries")
    }

    @Test func chipAndRemoveLabelsNameTheKind() {
        #expect(JournalFeedPresentation.chipTitle(.seed("s"), label: "Brandywine") == "Seed: Brandywine")
        #expect(JournalFeedPresentation.chipTitle(.bed("b"), label: "North bed") == "Bed: North bed")
        #expect(JournalFeedPresentation.chipTitle(.plantingEvent("p"), label: "Sow · May 1 · Brandywine")
            == "Planting: Sow · May 1 · Brandywine")
        #expect(JournalFeedPresentation.removeFilterLabel(.seed("s"), label: "Brandywine")
            == "Remove filter, seed Brandywine")
    }

    // MARK: - New entry, and the save check

    @Test func newEntryPrefillsTheFilteredParentWithAtMostOneAttachment() {
        #expect(JournalAttachment(.bed("b")) == JournalAttachment(seedID: nil, bedID: "b", plantingEventID: nil))
        #expect(JournalAttachment(.bed("b")).target == .bed("b"))
        #expect(JournalAttachment(.plantingEvent("p")).target == .plantingEvent("p"))
        #expect(JournalAttachment(nil).target == nil)
    }

    @Test func noGardenWhenTheDraftOpenedRefusesWithAnAccurateMessage() {
        let check = JournalSaveCheck.decide(
            draftHouseholdID: nil, activeHouseholdID: Self.garden, target: nil, loaded: nil, row: nil)
        #expect(check == .noGarden)
        #expect(check.message == "Open a garden to save this entry.")
    }

    @Test func noActiveGardenNowRefusesWithTheSameMessage() {
        let check = JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: nil, target: nil, loaded: nil, row: nil)
        #expect(check.message == "Open a garden to save this entry.")
    }

    @Test func unattachedSaveAfterAGardenSwitchIsRefused() {
        let check = JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: "other", target: nil, loaded: nil, row: nil)
        #expect(check == .gardenChanged)
        #expect(check.message?.contains("active garden changed") == true)
    }

    @Test func removedPrefillAfterAGardenSwitchIsRefused() {
        // A new entry was pre-filled with a seed, the user detached it, then the garden changed.
        let check = JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: "other", target: nil, loaded: nil, row: nil)
        #expect(check == .gardenChanged)
        // An existing entry whose stored attachment was detached, then the garden changed, is refused too.
        let edit = JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: "other", target: nil, loaded: .seed("s"),
            row: JournalAttachmentRow(householdID: Self.garden, isLive: true))
        #expect(edit == .gardenChanged)
    }

    @Test func unattachedSaveInTheSameGardenProceeds() {
        #expect(JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: Self.garden, target: nil, loaded: nil, row: nil)
            == .proceed)
    }

    @Test func liveAttachmentInTheDraftGardenProceeds() {
        #expect(JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: Self.garden, target: .seed("s"), loaded: nil,
            row: JournalAttachmentRow(householdID: Self.garden, isLive: true)) == .proceed)
    }

    @Test func aNewAttachmentThatIsDeletedIsUnavailable() {
        let check = JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: Self.garden, target: .seed("s"), loaded: nil,
            row: JournalAttachmentRow(householdID: Self.garden, isLive: false))
        #expect(check == .attachmentUnavailable(kind: "seed"))
        #expect(check.message == "The seed is no longer in this garden. Choose another and try again.")
    }

    @Test func aNewAttachmentInAnotherGardenIsUnavailable() {
        let check = JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: Self.garden, target: .bed("b"), loaded: nil,
            row: JournalAttachmentRow(householdID: "other", isLive: true))
        #expect(check == .attachmentUnavailable(kind: "bed"))
    }

    @Test func aMissingNewAttachmentIsUnavailable() {
        let check = JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: Self.garden, target: .plantingEvent("p"),
            loaded: nil, row: nil)
        #expect(check == .attachmentUnavailable(kind: "planting"))
    }

    @Test func aStoredAttachmentThatWasDeletedSaysToSetItToGarden() {
        // An edit of an entry whose seed was deleted, with the attachment left as it was.
        let check = JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: Self.garden, target: .seed("s"), loaded: .seed("s"),
            row: JournalAttachmentRow(householdID: Self.garden, isLive: false))
        #expect(check == .storedAttachmentDeleted(kind: "seed"))
        #expect(check.message == "This entry's seed was deleted. Set Attached to Garden to keep editing.")
    }

    @Test func aStoredAttachmentThatIsStillLiveSaves() {
        #expect(JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: Self.garden, target: .bed("b"), loaded: .bed("b"),
            row: JournalAttachmentRow(householdID: Self.garden, isLive: true)) == .proceed)
    }

    @Test func detachingAStoredDeletedAttachmentSaves() {
        // Setting Attached to Garden clears the deleted attachment, so the save goes ahead.
        #expect(JournalSaveCheck.decide(
            draftHouseholdID: Self.garden, activeHouseholdID: Self.garden, target: nil, loaded: .seed("s"),
            row: nil) == .proceed)
    }

    @Test func liveRowReadsTheStoreForEachKind() throws {
        let container = makeTestContainer(name: "journalLiveRowKinds")
        let context = ModelContext(container)
        context.insert(Self.seed("live", "Brandywine"))
        context.insert(Self.seed("gone", "Cherokee", deletedAt: 5))
        context.insert(Self.seed("foreign", "Other", household: "other"))
        context.insert(Self.bed("goneBed", "Old bed", deletedAt: 5))
        context.insert(Self.planting("goneP", deletedAt: 5))
        try context.save()

        #expect(JournalSaveCheck.liveRow(for: .seed("live"), in: context)
            == JournalAttachmentRow(householdID: Self.garden, isLive: true))
        #expect(JournalSaveCheck.liveRow(for: .seed("gone"), in: context)
            == JournalAttachmentRow(householdID: Self.garden, isLive: false))
        #expect(JournalSaveCheck.liveRow(for: .seed("foreign"), in: context)
            == JournalAttachmentRow(householdID: "other", isLive: true))
        #expect(JournalSaveCheck.liveRow(for: .seed("missing"), in: context) == nil)
        #expect(JournalSaveCheck.liveRow(for: .bed("goneBed"), in: context)
            == JournalAttachmentRow(householdID: Self.garden, isLive: false))
        #expect(JournalSaveCheck.liveRow(for: .plantingEvent("goneP"), in: context)
            == JournalAttachmentRow(householdID: Self.garden, isLive: false))
        #expect(JournalSaveCheck.liveRow(for: nil, in: context) == nil)
    }
}
