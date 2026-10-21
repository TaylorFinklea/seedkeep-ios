import Foundation
import Testing
@testable import Seedkeep
import SeedkeepKit

/// The Garden screens' pure rules (R3 G2): the New and Edit bed form, the bed switcher, the iPhone
/// bed-list row, the legend, the add-a-bed prompt, the Plan handoff and "Place in bed".
@MainActor
struct GardenScreensTests {
    private static let en = Locale(identifier: "en_US")

    // MARK: - New bed

    @Test func aNewBedDefaultsToFourByEight() throws {
        var form = BedForm.new()
        #expect(form.width == "4")
        #expect(form.length == "8")
        form.name = "  North  "
        let input = try #require(form.createInput)
        #expect(input.name == "North")
        #expect(input.width_feet == 4)
        #expect(input.length_feet == 8)
        #expect(input.description == nil)
    }

    @Test func aNewBedNeedsAName() {
        var form = BedForm.new()
        form.name = "   "
        #expect(!form.canSave)
        #expect(form.createInput == nil)
    }

    @Test func sizesAreDecimalFeetFromOneToFifty() {
        #expect(BedForm.parse("4.5") == .value(4.5))
        #expect(BedForm.parse("4,5") == .value(4.5))
        #expect(BedForm.parse(" 1 ") == .value(1))
        #expect(BedForm.parse("50") == .value(50))
        #expect(BedForm.parse("") == .value(nil))
        #expect(BedForm.parse("   ") == .value(nil))
        for bad in ["0", "-1", "0.5", "50.01", "51", "nan", "inf", "-inf", "infinity", "abc", "1e400"] {
            #expect(BedForm.parse(bad) == .invalid(BedForm.sizeRangeMessage), "\(bad)")
        }
    }

    @Test func aBlankSizeMakesABedWithoutAGrid() throws {
        var form = BedForm.new()
        form.name = "Pots"
        form.width = ""
        form.length = ""
        let input = try #require(form.createInput)
        #expect(input.width_feet == nil)
        #expect(input.length_feet == nil)
    }

    @Test func anInvalidSizeBlocksSaving() {
        var form = BedForm.new()
        form.name = "North"
        form.width = "0"
        #expect(!form.canSave)
        #expect(form.message(.width) == BedForm.sizeRangeMessage)
        #expect(form.message(.length) == nil)
        #expect(form.createInput == nil)
    }

    // MARK: - Edit bed

    private func edit(width: Double?, length: Double?, description: String? = "Raised") -> BedForm {
        BedForm.edit(.init(name: "North", description: description, widthFeet: width, lengthFeet: length))
    }

    @Test func anUntouchedEditSendsNothing() {
        #expect(edit(width: 4, length: 8).updateInput == nil)
        #expect(edit(width: 4, length: 8).canSave)
    }

    @Test func untouchedDecimalMissingAndOversizeSizesAreKept() {
        for (width, length) in [(4.5, 8.25), (60, 8), (4, 120)] as [(Double, Double)] {
            let form = edit(width: width, length: length)
            #expect(form.size(.width) == .unchanged)
            #expect(form.size(.length) == .unchanged)
            #expect(form.canSave, "\(width) × \(length)")
            #expect(form.updateInput == nil)
        }
        let missing = edit(width: nil, length: nil)
        #expect(missing.width.isEmpty)
        #expect(missing.size(.width) == .unchanged)
        #expect(missing.updateInput == nil)
    }

    @Test func anEditSendsOnlyTheChangedFields() throws {
        var form = edit(width: 60, length: 8)
        form.name = "North bed"
        let nameOnly = try #require(form.updateInput)
        #expect(nameOnly.name == "North bed")
        #expect(nameOnly.description == nil)
        #expect(nameOnly.width_feet == nil)
        #expect(nameOnly.length_feet == nil)

        var resize = edit(width: 4.5, length: 8)
        resize.length = "6"
        let lengthOnly = try #require(resize.updateInput)
        #expect(lengthOnly.length_feet == 6)
        #expect(lengthOnly.width_feet == nil)
        #expect(lengthOnly.name == nil)
    }

    @Test func anEditedOversizeSizeMustBeValid() {
        var form = edit(width: 60, length: 8)
        form.width = "70"
        #expect(form.message(.width) == BedForm.sizeRangeMessage)
        #expect(!form.canSave)
        form.width = "10"
        #expect(form.updateInput?.width_feet == 10)
    }

    @Test func retypingTheSameSizeIsUnchanged() {
        var form = edit(width: 4, length: 8)
        form.width = "4.0"
        #expect(form.size(.width) == .unchanged)
        #expect(form.updateInput == nil)
    }

    @Test func aStoredSizeCantBeCleared() {
        var form = edit(width: 4, length: 8)
        form.width = ""
        #expect(form.message(.width) == BedForm.sizeClearMessage)
        #expect(!form.canSave)
    }

    @Test func aMissingSizeCanBeSet() {
        var form = edit(width: nil, length: nil)
        form.width = "3"
        form.length = "6"
        let input = form.updateInput
        #expect(input?.width_feet == 3)
        #expect(input?.length_feet == 6)
    }

    @Test func clearingTheDescriptionSendsAnEmptyString() {
        var form = edit(width: 4, length: 8)
        form.description = "  "
        #expect(form.updateInput?.description == "")
        #expect(form.updateInput?.name == nil)
    }

    @Test func feetAreFormattedStably() {
        #expect(BedForm.format(4) == "4")
        #expect(BedForm.format(4.5) == "4.5")
        #expect(BedForm.format(60) == "60")
    }

    // MARK: - Bed switcher

    @Test func theSwitcherIsSegmentedUpToFiveBedsThenAMenu() {
        #expect(BedSwitcherStyle.choose(bedCount: 0) == .none)
        #expect(BedSwitcherStyle.choose(bedCount: 1) == .segmented)
        #expect(BedSwitcherStyle.choose(bedCount: 5) == .segmented)
        #expect(BedSwitcherStyle.choose(bedCount: 6) == .menu)
        #expect(BedSwitcherStyle.choose(bedCount: 40) == .menu)
    }

    // MARK: - iPhone bed list

    private func event(
        _ id: String, kind: String = "sowing", planned: String, done: Bool = false, frost: Bool = false,
        seed: String? = "s1"
    ) -> GridEvent {
        GridEvent(id: id, bedID: "b1", seedID: seed, kind: kind, plannedFor: planned, isCompleted: done,
                  x: nil, y: nil, isFrostFlagged: frost)
    }

    @Test func theBedListRowShowsSizeNextEventAndFrostCount() {
        let row = GardenBedListRow.make(
            name: "North", widthFeet: 4, lengthFeet: 8,
            events: [
                event("e3", planned: "2026-05-20", frost: true),
                event("e1", planned: "2026-04-01", done: true, frost: true),
                event("e2", kind: "transplant", planned: "2026-05-04", frost: true),
            ],
            seedNames: ["s1": "Basil"], locale: Self.en
        )
        #expect(row.sizeText == "4 × 8 ft")
        #expect(row.nextEventText == "Next: Transplant Basil, May 4")
        // The completed event doesn't count.
        #expect(row.frostText == "2 frost risks")
        #expect(row.accessibilityLabel == "North, 4 × 8 ft, Next: Transplant Basil, May 4, 2 frost risks")
    }

    @Test func theBedListRowWithoutEventsOrSize() {
        let row = GardenBedListRow.make(name: "Pots", widthFeet: nil, lengthFeet: nil, events: [],
                                        seedNames: [:], locale: Self.en)
        #expect(row.sizeText == "No size")
        #expect(row.nextEventText == "No upcoming events")
        #expect(row.frostText == nil)
        let one = GardenBedListRow.make(
            name: "Herb", widthFeet: 3.5, lengthFeet: nil,
            events: [event("e1", kind: "note", planned: "2026-05-04", frost: true, seed: nil)],
            seedNames: [:], locale: Self.en
        )
        #expect(one.sizeText == "3.5 ft wide")
        #expect(one.nextEventText == "Next: Note, May 4")
        #expect(one.frostText == "1 frost risk")
        #expect(GardenBedListRow.sizeText(widthFeet: nil, lengthFeet: 8) == "8 ft long")
    }

    // MARK: - Legend

    @Test func theLegendNamesEveryMarkAndTheScale() {
        #expect(GardenLegend.items.map(\.title) == ["Sow", "Transplant", "Harvest", "Done", "Frost risk (estimate)"])
        #expect(GardenLegend.items.last?.mark == .frost)
        #expect(GardenLegend.items[3].mark == .swatch(kind: "note"))
        #expect(GardenLegend.scale == "1 square = 1 sq ft")
    }

    // MARK: - Add-a-bed prompt

    @Test func aBrushWithNoGridBedShowsThePromptNotAStopBar() {
        // Painting with no grid bed anywhere (the bed list or a gridless bed).
        #expect(GardenBanner.choose(mode: .painting, brushSeedID: "s1", gridBedCount: 0) == .addBedPrompt)
        #expect(GardenBanner.choose(mode: .idle, brushSeedID: nil, gridBedCount: 0) == .none)
        #expect(GardenBanner.promptTitle == "Add a bed with a size to plan")
    }

    @Test func stopStaysReachableWheneverAModeIsActive() {
        // Grid beds exist: the Stop or Cancel bar shows on any bed and on the bed list, so switching
        // away from a grid bed never hides Stop.
        for gridBedCount in [1, 2] {
            #expect(GardenBanner.choose(mode: .painting, brushSeedID: "s1", gridBedCount: gridBedCount) == .modeBar)
            #expect(GardenBanner.choose(mode: .moving(eventID: "e1"), brushSeedID: nil,
                                        gridBedCount: gridBedCount) == .modeBar)
            #expect(GardenBanner.choose(mode: .idle, brushSeedID: nil, gridBedCount: gridBedCount) == .none)
        }
        // A move with no grid bed left still shows Cancel.
        #expect(GardenBanner.choose(mode: .moving(eventID: "e1"), brushSeedID: nil, gridBedCount: 0) == .modeBar)
    }

    @Test func aStoredNameWithSurroundingSpaceIsUntouched() {
        let form = BedForm.edit(.init(name: "  North  ", description: nil, widthFeet: 4, lengthFeet: 8))
        #expect(form.updateInput == nil)
        var renamed = form
        renamed.name = "South"
        #expect(renamed.updateInput?.name == "South")
    }

    // MARK: - Plan handoff

    private func scopedSession() -> GardenSession {
        let session = GardenSession()
        session.reconcile(.init(householdID: "h1", isSignedIn: true, bedIDs: ["herb", "pots"], gridBedIDs: ["herb"],
                                eventIDs: [], activeSeedIDs: ["s1"]))
        return session
    }

    private let beds = [
        GardenSession.BedChoice(id: "pots", name: "Pots", sortOrder: 0, hasGrid: false),
        GardenSession.BedChoice(id: "herb", name: "Herb", sortOrder: 1, hasGrid: true),
    ]

    @Test func eitherShellTakesThePlanOnceAndPaintsInItsBed() throws {
        for _ in ["compact", "workbench"] {
            let session = scopedSession()
            session.plan(seedID: "s1", isActive: true, beds: beds)
            // Back on the list before the Garden screen takes it.
            session.showBed(nil)
            let plan = try #require(GardenPlanHandoff.take(from: session, gridBedIDs: ["herb"]))
            #expect(plan == GardenSession.PendingPlan(seedID: "s1", bedID: "herb"))
            #expect(session.bedID == "herb")
            #expect(session.brushSeedID == "s1")
            #expect(session.mode == .painting)
            #expect(session.pendingPlan == nil)
            // A later shell switch finds nothing to take.
            #expect(GardenPlanHandoff.take(from: session, gridBedIDs: ["herb"]) == nil)
        }
    }

    @Test func aPlanWhoseBedLostItsGridIsDroppedByTheReconciler() {
        let session = scopedSession()
        session.plan(seedID: "s1", isActive: true, beds: beds)
        // Not taken while its bed isn't a grid bed; the reconciler drops it.
        #expect(GardenPlanHandoff.take(from: session, gridBedIDs: []) == nil)
        #expect(session.pendingPlan == GardenSession.PendingPlan(seedID: "s1", bedID: "herb"))
        session.reconcile(.init(householdID: "h1", isSignedIn: true, bedIDs: ["herb", "pots"], gridBedIDs: [],
                                eventIDs: [], activeSeedIDs: ["s1"]))
        #expect(session.pendingPlan == nil)
        #expect(GardenPlanHandoff.take(from: session, gridBedIDs: ["herb"]) == nil)
    }

    @Test func aPlanForABedNotYetInTheQueryWaitsUntilItArrives() throws {
        let session = scopedSession()
        let new = GardenSession.BedChoice(id: "new", name: "New", sortOrder: 0, hasGrid: true)
        #expect(session.plan(seedID: "s1", isActive: true, beds: [beds[0]]) == .needsBed)
        #expect(GardenPlanHandoff.resume(session: session, created: new, beds: [beds[0]]) == .planned(bedID: "new"))
        // The old grid beds: the Plan stays waiting.
        #expect(GardenPlanHandoff.take(from: session, gridBedIDs: ["herb"]) == nil)
        #expect(session.pendingPlan == GardenSession.PendingPlan(seedID: "s1", bedID: "new"))
        // The query catches up: the Plan is taken and paints in the new bed.
        let plan = try #require(GardenPlanHandoff.take(from: session, gridBedIDs: ["herb", "new"]))
        #expect(plan == GardenSession.PendingPlan(seedID: "s1", bedID: "new"))
        #expect(session.pendingPlan == nil)
        #expect(session.bedID == "new")
        #expect(session.mode == .painting)
        #expect(session.brushSeedID == "s1")
    }

    @Test func zeroOrGridlessBedsLeaveNothingToTake() {
        for choices in [[], [beds[0]]] {
            let session = scopedSession()
            #expect(session.plan(seedID: "s1", isActive: true, beds: choices) == .needsBed)
            #expect(GardenPlanHandoff.take(from: session, gridBedIDs: []) == nil)
            // The brush stays for the add-a-bed prompt.
            #expect(session.brushSeedID == "s1")
            #expect(GardenBanner.choose(mode: session.mode, brushSeedID: session.brushSeedID, gridBedCount: 0)
                    == .addBedPrompt)
        }
    }

    @Test func newBedResumesThePlanOnlyWithAGridAndABrush() {
        let grid = GardenSession.BedChoice(id: "new", name: "New", sortOrder: 0, hasGrid: true)
        let gridless = GardenSession.BedChoice(id: "new", name: "New", sortOrder: 0, hasGrid: false)
        #expect(GardenPlanHandoff.seedToResume(brushSeedID: "s1", created: grid) == "s1")
        #expect(GardenPlanHandoff.seedToResume(brushSeedID: "s1", created: gridless) == nil)
        #expect(GardenPlanHandoff.seedToResume(brushSeedID: nil, created: grid) == nil)
        #expect(GardenPlanHandoff.seedToResume(brushSeedID: "s1", created: nil) == nil)

        let session = scopedSession()
        #expect(session.plan(seedID: "s1", isActive: true, beds: [beds[0]]) == .needsBed)
        // The new bed isn't in the query yet; resume adds it.
        #expect(GardenPlanHandoff.resume(session: session, created: grid, beds: [beds[0]]) == .planned(bedID: "new"))
        #expect(session.pendingPlan == GardenSession.PendingPlan(seedID: "s1", bedID: "new"))
    }

    // MARK: - Place in bed

    @Test func placeInBedWritesTheSquareCentre() throws {
        let top = try #require(PlaceInBed.coordinates(square: GridSquare(column: 0, rowFromTop: 0), widthFeet: 4, lengthFeet: 8))
        #expect(top.x == 0.5)
        #expect(top.y == 7.5)
        let bottomRight = try #require(PlaceInBed.coordinates(square: GridSquare(column: 3, rowFromTop: 7),
                                                              widthFeet: 4.5, lengthFeet: 8))
        #expect(bottomRight.x == 3.5)
        #expect(bottomRight.y == 0.5)
    }

    @Test func placeInBedWritesNothingWithoutAPickOrAGrid() {
        #expect(PlaceInBed.coordinates(square: nil, widthFeet: 4, lengthFeet: 8) == nil)
        #expect(PlaceInBed.coordinates(square: GridSquare(column: 0, rowFromTop: 0), widthFeet: nil, lengthFeet: 8) == nil)
        #expect(PlaceInBed.coordinates(square: GridSquare(column: 0, rowFromTop: 0), widthFeet: 60, lengthFeet: 8) == nil)
        #expect(PlaceInBed.coordinates(square: GridSquare(column: 4, rowFromTop: 0), widthFeet: 4, lengthFeet: 8) == nil)
    }
}
