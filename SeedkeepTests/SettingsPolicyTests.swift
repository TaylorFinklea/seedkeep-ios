import Foundation
import Testing
@testable import Seedkeep

@Suite("Settings blocks and legacy cleanup")
struct SettingsPolicyTests {
    @Test("with an open garden, every block is shown in order")
    func openGardenShowsEveryBlock() {
        #expect(SettingsPolicy.blocks(hasActiveGarden: true) == [
            .account, .appearance, .seeds, .homeAndAlerts, .ai, .sync, .about
        ])
    }

    @Test("with no garden open, Settings explains instead of the household rows and keeps the app-wide rows")
    func noGardenExplainsInPlaceOfHouseholdRows() {
        let blocks = SettingsPolicy.blocks(hasActiveGarden: false)

        #expect(blocks == [.gardenUnavailable, .appearance, .homeAndAlerts, .ai, .about])
        for householdBlock in [SettingsPolicy.Block.account, .seeds, .sync] {
            #expect(!blocks.contains(householdBlock))
        }
        #expect(blocks.contains(.appearance))
        #expect(blocks.contains(.about))
    }

    @Test("the retired Server and Subscription blocks are gone")
    func legacyBlocksAreGone() {
        #expect(SettingsPolicy.Block.allCases.count == 8)
        let names = SettingsPolicy.Block.allCases.map { String(describing: $0).lowercased() }
        #expect(!names.contains { $0.contains("server") || $0.contains("subscription") })
    }

    @Test("the AI provider picker offers Free and BYOK only")
    func aiProviderOptionsExcludeHosted() {
        #expect(SettingsPolicy.selectableAIProviders() == [.free, .byok])
    }

    @Test("the Mac Settings window's scope changes with the garden and on sign-out, and is stable otherwise")
    func scopeIdentityTracksTheGarden() {
        #expect(SettingsPolicy.scopeIdentity(householdID: "garden-a") == SettingsPolicy.scopeIdentity(householdID: "garden-a"))
        #expect(SettingsPolicy.scopeIdentity(householdID: "garden-a") != SettingsPolicy.scopeIdentity(householdID: "garden-b"))
        #expect(SettingsPolicy.scopeIdentity(householdID: nil) != SettingsPolicy.scopeIdentity(householdID: "garden-a"))
        #expect(SettingsPolicy.scopeIdentity(householdID: nil) == SettingsPolicy.scopeIdentity(householdID: nil))
    }

    @Test("the no-garden explanation is set")
    func noGardenExplanationIsSet() {
        #expect(!SettingsText.gardenUnavailableExplanation.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @MainActor
    @Test("a stored Hosted choice reads as Free, and the stored value is left alone")
    func storedHostedReadsAsFree() throws {
        let suite = "settings-policy-hosted-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("hosted", forKey: "seedkeep.aiProvider")

        let preferences = AppPreferences(defaults: defaults)

        // Hosted's server is retired: the stored choice reads as Free (on-device), the app's default,
        // so scanning keeps working without a key.
        #expect(preferences.aiProvider == .free)
        #expect(defaults.string(forKey: "seedkeep.aiProvider") == "hosted")
    }

    @MainActor
    @Test("stored Free and BYOK choices are kept, and an unset choice is Free")
    func storedChoicesAreKept() throws {
        let suite = "settings-policy-choices-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppPreferences(defaults: defaults).aiProvider == .free)

        defaults.set("byok", forKey: "seedkeep.aiProvider")
        #expect(AppPreferences(defaults: defaults).aiProvider == .byok)

        defaults.set("free", forKey: "seedkeep.aiProvider")
        #expect(AppPreferences(defaults: defaults).aiProvider == .free)
    }
}
