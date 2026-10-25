import CloudKit
import Foundation
@testable import Seedkeep
import SeedkeepCloudKit

/// N2-E fake provisioner: records every zone save and root save request, and answers
/// `createGarden` from a script. No CloudKit.
final class FakeGardenProvisioner: GardenProvisioning, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _zoneSaves: [String] = []
    private var _rootSaves: [String] = []
    private var _ensureHouseholdCalls: [String] = []
    private var _outcomes: [GardenCreationOutcome] = []
    private var _status: CKAccountStatus? = .available
    /// What `ensureHousehold` answers: a root, or a throw (the zone is missing).
    private var _existingRoot: EstablishedRoot?

    /// Queue of outcomes `createGarden` returns, in order. An empty queue creates successfully.
    func script(_ outcomes: GardenCreationOutcome...) { lock.withLock { _outcomes = outcomes } }
    var status: CKAccountStatus? {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    /// Makes `ensureHousehold` return a root (an existing garden). Nil: it throws, as a missing zone does.
    func setExistingRoot(householdID: String, creationDate: Date? = nil) {
        let id = CKRecord.ID(recordName: SeedkeepRecordNames.household(householdID),
                             zoneID: SeedkeepZoneProvisioner.zoneID(householdID: householdID))
        lock.withLock {
            _existingRoot = EstablishedRoot(record: CKRecord(recordType: "Household", recordID: id),
                                            creationDate: creationDate)
        }
    }

    var zoneSaves: [String] { lock.withLock { _zoneSaves } }
    var rootSaves: [String] { lock.withLock { _rootSaves } }
    var ensureHouseholdCalls: [String] { lock.withLock { _ensureHouseholdCalls } }
    /// Every provisioner request that would create a zone or its root. (`.saveZone` staging is
    /// covered by `GardenGuardEngineTests`, which exercises the engine's staging seam.)
    var totalCreations: Int { zoneSaves.count + rootSaves.count }

    static func createdOutcome(householdID: String, creationDate: Date) -> GardenCreationOutcome {
        let id = CKRecord.ID(recordName: SeedkeepRecordNames.household(householdID),
                             zoneID: SeedkeepZoneProvisioner.zoneID(householdID: householdID))
        return .created(root: CKRecord(recordType: "Household", recordID: id), creationDate: creationDate)
    }

    func accountStatus() async -> CKAccountStatus? { status }

    func createGarden(householdID: String, name: String) async -> GardenCreationOutcome {
        lock.withLock {
            _zoneSaves.append(householdID)
            _rootSaves.append(householdID)
            if !_outcomes.isEmpty { return _outcomes.removeFirst() }
            return Self.createdOutcome(householdID: householdID, creationDate: Date(timeIntervalSince1970: 1_000))
        }
    }

    func ensureHousehold(householdID: String, name: String) async throws -> EstablishedRoot {
        let root = lock.withLock { () -> EstablishedRoot? in
            _ensureHouseholdCalls.append(householdID)
            return _existingRoot
        }
        guard let root else { throw CKError(.zoneNotFound) }
        return root
    }

    func ensureShare(for root: CKRecord, title: String) async throws -> CKShare { CKShare(rootRecord: root) }

    private var _owned: [GardenZoneSummary]?
    /// What the discovery listing answers; nil makes it throw (offline).
    func setOwnedListing(_ zones: [GardenZoneSummary]?) { lock.withLock { _owned = zones } }

    func listOwnedGardens() async throws -> [GardenZoneSummary] {
        guard let zones = lock.withLock({ _owned }) else { throw Failure() }
        return zones
    }
}

/// Records the re-home requests the guard hands to the G3 seam.
@MainActor
final class RecordingRehomer: GardenRehoming {
    private(set) var requests: [GardenRehomeRequest] = []
    func rehomeRequested(_ request: GardenRehomeRequest) { requests.append(request) }
}

enum GuardTestDirectory {
    static func make() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-test-\(UUID().uuidString)", isDirectory: true)
    }
}
