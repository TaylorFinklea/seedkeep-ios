// Sample-garden mode, for screenshots and manual QA. DEBUG builds only: the whole file is compiled
// out of Release. Launch with `-SeedkeepFixture`, and `AppEnvironment.live()` then runs over an
// in-memory store seeded by `FixtureSampleGarden`, with a fixed identity and no CloudKit.
#if DEBUG
import CloudKit
import Foundation
import SeedkeepCloudKit

enum FixtureMode {
    static let launchArgument = "-SeedkeepFixture"
    /// Its own defaults suite, so the real app's identity cache, home ZIP and garden marker are never touched.
    static let defaultsSuiteName = "app.seedkeep.fixture"

    /// True when the app launched with `-SeedkeepFixture`, outside XCTest.
    static var isEnabled: Bool {
        isEnabled(arguments: CommandLine.arguments, isRunningUnitTests: FeatureFlags.isRunningUnitTests)
    }

    static func isEnabled(arguments: [String], isRunningUnitTests: Bool) -> Bool {
        !isRunningUnitTests && arguments.contains(launchArgument)
    }
}

/// A fixed iCloud identity for sample-garden mode: an available account that owns one garden.
struct FixtureCloudIdentityProvider: CloudIdentityProviding {
    static let userRecordName = "_fixtureUser"
    static let householdID = "6f1c2a4e-0b7d-4e5a-9c3b-5a1d2e8f0a11"

    func accountStatus() async -> CloudAccountStatus {
        .available
    }

    func currentUserRecordName() async throws -> String {
        Self.userRecordName
    }

    func listGardenZones(_ scope: GardenDatabaseScope) async throws -> [GardenZoneSummary] {
        guard scope == .owned else { return [] }
        return [GardenZoneSummary(
            householdID: Self.householdID,
            zoneName: SeedkeepRecordNames.zoneName(householdID: Self.householdID),
            ownerName: CKCurrentUserDefaultName,
            scope: .owned,
            name: "Sample garden",
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_000_000
        )]
    }
}

/// Holds no token. Sample-garden mode never signs in, and the Keychain is never read or written.
struct FixtureTokenStore: TokenStoring {
    func load() -> String? { nil }
    func save(_ token: String) {}
    func clear() {}
}
#endif
