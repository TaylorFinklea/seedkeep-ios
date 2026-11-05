// Sample-garden mode, for screenshots and manual QA. DEBUG builds only: the whole file is compiled
// out of Release. Launch with `-SeedkeepFixture`, and `AppEnvironment.live()` then runs over an
// in-memory store seeded by `FixtureSampleGarden`, with a fixed identity and no CloudKit.
#if DEBUG
import CloudKit
import Foundation
import SeedkeepCloudKit
import UserNotifications

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

    /// `-SeedkeepGardenGone owner|participant` (with `-SeedkeepFixture`): the sample garden launches as a
    /// garden that is gone, so the choice screen shows (N2-E G3 screenshots). Nothing is sent anywhere:
    /// CloudKit is off in sample-garden mode, and the guard is in memory.
    static let gardenGoneArgument = "-SeedkeepGardenGone"

    enum GoneWording: String {
        case owner, participant
    }

    static func gardenGone(arguments: [String]) -> GoneWording? {
        guard arguments.contains(launchArgument), let index = arguments.firstIndex(of: gardenGoneArgument),
              arguments.indices.contains(index + 1) else { return nil }
        return GoneWording(rawValue: arguments[index + 1])
    }

    /// A guard that already holds the sample garden as gone, awaiting a choice.
    @MainActor
    static func goneGuard(_ wording: GoneWording) -> GardenGuardStore {
        let store = GardenGuardStore(directory: nil)
        let account = GardenGuardStore.accountKey(recordName: FixtureCloudIdentityProvider.userRecordName)
        let id = FixtureCloudIdentityProvider.householdID
        let participant = wording == .participant
            ? GardenGuardBinding.Participant(zoneName: SeedkeepRecordNames.zoneName(householdID: id), ownerName: "_fixtureOwner")
            : nil
        let binding = GardenGuardBinding(
            household: .init(id: id, name: "Sample garden", createdAt: 1_760_000_000_000, updatedAt: 1_760_000_000_000),
            participant: participant)
        try? store.setBinding(account, binding)
        try? store.markGone(account, id, reason: wording == .participant ? .accessLost : .zoneDeleted)
        return store
    }

    /// Scratch-directory names the fixture owns: `seedkeep-fixture` and `seedkeep-fixture-<UUID>`.
    static let rootNamePrefix = "seedkeep-fixture"

    /// The fixture's scratch root for one launch, `seedkeep-fixture-<UUID>` in `temporary`. Older fixture
    /// roots are removed first, so a launch never reads files a previous session left behind.
    static func prepareLaunchRoot(
        in temporary: URL = FileManager.default.temporaryDirectory,
        id: UUID = UUID()
    ) -> URL {
        removeStaleRoots(in: temporary)
        return temporary.appendingPathComponent("\(rootNamePrefix)-\(id.uuidString)", isDirectory: true)
    }

    /// A directory the fixture owns: the old fixed name, or `seedkeep-fixture-<UUID>`. Anything else,
    /// such as `seedkeep-fixture-backup`, is left alone.
    static func isFixtureRootName(_ name: String) -> Bool {
        if name == rootNamePrefix { return true }
        let prefix = rootNamePrefix + "-"
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    /// Removes every fixture directory in `temporary`. Other files and directories are left alone.
    static func removeStaleRoots(in temporary: URL) {
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for item in items where isFixtureRootName(item.lastPathComponent) {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            try? fileManager.removeItem(at: item)
        }
    }

    /// The fixture forecast: empty and immediate, so no WeatherKit request is made and every window keeps
    /// its baseline.
    static let forecastSource: RecommendationStore.ForecastSource = { _, _ in [] }

    /// The notification status a sample-garden launch reports, without asking the system.
    static let authorizationStatus: @Sendable () async -> UNAuthorizationStatus = { .authorized }
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
    func clear() {}
}
#endif
