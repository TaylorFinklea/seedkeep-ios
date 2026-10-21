import Foundation
import SeedkeepKit
import SwiftData
import SwiftUI
import Testing
@testable import Seedkeep

struct WorkbenchTypeTests {
    @Test func everyRoleIsASystemTextStyleWithAWeightAndNoPointSize() {
        // A role is a text style and an optional weight, nothing else, so Dynamic Type scales it.
        #expect(WBType.largeTitle == WBTextRole(style: .largeTitle, weight: .semibold))
        #expect(WBType.title == WBTextRole(style: .title2, weight: .semibold))
        #expect(WBType.headline == WBTextRole(style: .headline, weight: nil))
        #expect(WBType.callout == WBTextRole(style: .callout, weight: nil))
        #expect(WBType.footnote == WBTextRole(style: .footnote, weight: nil))
        #expect(WBType.sectionLabel == WBTextRole(style: .caption, weight: .semibold))
    }
}

@MainActor
struct WorkbenchStatusChipTests {
    @Test(arguments: [
        WBStatusChip.Tone.neutral,
        .accent,
        .warn,
        .verdict("plant_now"),
        .verdict("too_late"),
    ])
    func everyToneSpeaksItsText(tone: WBStatusChip.Tone) {
        let chip = WBStatusChip("Plant soon", tone: tone)
        #expect(chip.accessibilityText.contains("Plant soon"))
    }

    @Test func warningSaysSoInWords() {
        #expect(WBStatusChip("Late", tone: .warn).accessibilityText == "Warning: Late")
    }

    @Test func otherTonesSpeakOnlyTheirText() {
        #expect(WBStatusChip("Plant now", tone: .verdict("plant_now")).accessibilityText == "Plant now")
        #expect(WBStatusChip("Saved", tone: .accent).accessibilityText == "Saved")
        #expect(WBStatusChip("Archived", tone: .neutral).accessibilityText == "Archived")
    }
}

#if DEBUG
struct FixtureModeTests {
    @Test func staysOffUnderXCTest() {
        #expect(!FixtureMode.isEnabled(arguments: ["-SeedkeepFixture"], isRunningUnitTests: true))
        // This process is the test host, so the live flag is off too.
        #expect(!FixtureMode.isEnabled)
    }

    @Test func needsTheLaunchArgumentOutsideXCTest() {
        #expect(FixtureMode.isEnabled(arguments: ["-SeedkeepFixture"], isRunningUnitTests: false))
        #expect(!FixtureMode.isEnabled(arguments: [], isRunningUnitTests: false))
    }

    @Test func identityIsAvailableWithOneOwnedGardenAndNoSharedOnes() async throws {
        let identity = FixtureCloudIdentityProvider()
        #expect(await identity.accountStatus() == .available)
        let owned = try await identity.listGardenZones(.owned)
        #expect(owned.map(\.householdID) == [FixtureCloudIdentityProvider.householdID])
        #expect(try await identity.listGardenZones(.shared).isEmpty)
    }

    @MainActor @Test func sampleGardenHasEveryStateAndAFullSetOfRecords() throws {
        let container = makeTestContainer(name: "fixture-sample-garden")
        let suite = "app.seedkeep.tests.fixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults, bundleDefaultURL: URL(string: "https://seedkeep.invalid")!)

        try FixtureSampleGarden.seed(
            into: container.mainContext,
            householdID: FixtureCloudIdentityProvider.householdID,
            preferences: preferences
        )

        let context = container.mainContext
        let seeds = try context.fetch(FetchDescriptor<LocalSeed>())
        #expect(seeds.count == 20)
        #expect(Set(seeds.map(\.state)) == Set(SeedState.allCases))
        #expect(seeds.allSatisfy { $0.householdID == FixtureCloudIdentityProvider.householdID })
        // Every seed has growing info, so its planting window can show.
        #expect(seeds.allSatisfy { $0.growingInfo?.days_to_maturity_min != nil })
        #expect(try context.fetchCount(FetchDescriptor<LocalBed>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<LocalPlantingEvent>()) == 9)
        #expect(try context.fetchCount(FetchDescriptor<LocalJournalEntry>()) == 5)
        #expect(try context.fetchCount(FetchDescriptor<LocalJournalChecklistItem>()) == 8)
        #expect(try context.fetchCount(FetchDescriptor<LocalTag>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<LocalLocation>()) == 3)
        #expect(preferences.homeClimate?.zip == FixtureSampleGarden.homeZip)
    }
}
#endif
