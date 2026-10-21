import Testing
@testable import Seedkeep

@Suite("AuditLaunch")
struct AuditLaunchTests {

    @Test("the audit argument is matched exactly")
    func requestsAuditMatchesExactly() {
        #expect(AuditLaunch.requestsAudit(arguments: ["-SeedkeepAuditLaunch"]))
        #expect(AuditLaunch.requestsAudit(arguments: ["-SeedkeepFixture", "-SeedkeepAuditLaunch", "-AppleLocale", "en_US"]))
        #expect(!AuditLaunch.requestsAudit(arguments: ["-SeedkeepAuditLaunchX"]))
        #expect(!AuditLaunch.requestsAudit(arguments: []))
    }

    @Test("an audit launch refuses to start unless it is sample-garden mode")
    func auditLaunchFailsClosed() {
        let arguments = ["-SeedkeepAuditLaunch"]
        #expect(AuditLaunch.decision(arguments: arguments, sampleGarden: false) == .refuse)
        #expect(AuditLaunch.decision(arguments: arguments, sampleGarden: true) == .proceed)
    }

    @Test("a launch without the audit argument always proceeds")
    func ordinaryLaunchProceeds() {
        #expect(AuditLaunch.decision(arguments: [], sampleGarden: false) == .proceed)
        #expect(AuditLaunch.decision(arguments: ["-SeedkeepFixture"], sampleGarden: true) == .proceed)
        #expect(AuditLaunch.decision(arguments: ["-SeedkeepFixture"], sampleGarden: false) == .proceed)
    }

    #if DEBUG
    @Test("the appearance override reads light and dark, and only in a sample-garden launch")
    func appearanceOverrideParsing() {
        let fixture = ["-SeedkeepFixture"]
        #expect(AuditLaunch.appearanceOverride(arguments: fixture + ["-SeedkeepAppearance", "light"]) == .light)
        #expect(AuditLaunch.appearanceOverride(arguments: fixture + ["-SeedkeepAppearance", "dark"]) == .dark)
        // Anything else is ignored, so the configuration stays at System.
        #expect(AuditLaunch.appearanceOverride(arguments: fixture + ["-SeedkeepAppearance", "system"]) == nil)
        #expect(AuditLaunch.appearanceOverride(arguments: fixture + ["-SeedkeepAppearance", "Dark"]) == nil)
        #expect(AuditLaunch.appearanceOverride(arguments: fixture + ["-SeedkeepAppearance"]) == nil)
        #expect(AuditLaunch.appearanceOverride(arguments: fixture) == nil)
        // Read only with `-SeedkeepFixture`.
        #expect(AuditLaunch.appearanceOverride(arguments: ["-SeedkeepAppearance", "dark"]) == nil)
        #expect(AuditLaunch.appearanceOverride(arguments: []) == nil)
    }
    #endif
}
