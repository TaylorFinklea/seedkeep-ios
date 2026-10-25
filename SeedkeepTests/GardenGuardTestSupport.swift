import CloudKit
import Foundation
@testable import Seedkeep
import SeedkeepCloudKit

/// N2-E fake provisioner: records every zone save, root save and root read, and answers
/// `createGarden`, `inspect` and `readRoot` from a script. No CloudKit.
final class FakeGardenProvisioner: GardenProvisioning, @unchecked Sendable {
    struct Failure: Error {}

    /// What a garden's zone looks like to the fake.
    enum Root {
        case present(creationDate: Date?)
        /// The zone is listed and the `Household` root is confirmed absent.
        case rootMissing
        /// The zone is not in the listing (a garden never created, or deleted).
        case zoneMissing
        /// The listing shows the zone, but the root read said the zone is missing (contradictory):
        /// answered through the live provisioner's own verdict function.
        case listedButZoneReadMissing
    }

    private let lock = NSLock()
    private var _zoneSaves: [String] = []
    private var _rootSaves: [String] = []
    private var _inspectCalls: [String] = []
    private var _readRootCalls: [String] = []
    private var _shareSaves: [String] = []
    private var _outcomes: [GardenCreationOutcome] = []
    private var _status: CKAccountStatus? = .available
    private var _roots: [String: Root] = [:]
    private var _inspectErrors: [Error] = []
    private var _readScript: [GardenRootRead] = []
    private var _readGate: (@Sendable () async -> Void)?
    private var _inspectGate: (@Sendable () async -> Void)?
    private var _permission: SharePermission = .readWrite

    /// Queue of outcomes `createGarden` returns, in order. An empty queue creates successfully.
    func script(_ outcomes: GardenCreationOutcome...) { lock.withLock { _outcomes = outcomes } }
    var status: CKAccountStatus? {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var permission: SharePermission {
        get { lock.withLock { _permission } }
        set { lock.withLock { _permission = newValue } }
    }
    /// Makes the garden's zone and root exist (an established garden).
    func setExistingRoot(householdID: String, creationDate: Date? = Date(timeIntervalSince1970: 1_000)) {
        lock.withLock { _roots[householdID] = .present(creationDate: creationDate) }
    }
    func setRoot(householdID: String, _ root: Root) { lock.withLock { _roots[householdID] = root } }
    /// The next `inspect` calls throw these, in order.
    func failInspections(_ errors: Error...) { lock.withLock { _inspectErrors = errors } }
    /// The next `readRoot` calls answer these, in order, before falling back to the garden's state.
    func scriptReads(_ reads: GardenRootRead...) { lock.withLock { _readScript = reads } }
    /// Runs inside every `inspect`, so a test can change the account or epoch during the await.
    func onInspect(_ gate: (@Sendable () async -> Void)?) { lock.withLock { _inspectGate = gate } }
    /// Runs inside every `readRoot`, so a test can change the account or epoch during the await.
    func onReadRoot(_ gate: (@Sendable () async -> Void)?) { lock.withLock { _readGate = gate } }

    var zoneSaves: [String] { lock.withLock { _zoneSaves } }
    var rootSaves: [String] { lock.withLock { _rootSaves } }
    var inspectCalls: [String] { lock.withLock { _inspectCalls } }
    /// Direct root reads: the batch check's cost (one per batch, one before the share save).
    var readRootCalls: [String] { lock.withLock { _readRootCalls } }
    var shareSaves: [String] { lock.withLock { _shareSaves } }
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
            let outcome: GardenCreationOutcome
            if !_outcomes.isEmpty { outcome = _outcomes.removeFirst() }
            else { outcome = Self.createdOutcome(householdID: householdID, creationDate: Date(timeIntervalSince1970: 1_000)) }
            // A created garden exists afterwards, with the date the server returned.
            if case .created(_, let creationDate) = outcome { _roots[householdID] = .present(creationDate: creationDate) }
            return outcome
        }
    }

    private static func householdID(of zoneID: CKRecordZone.ID) -> String {
        SeedkeepRecordNames.householdID(fromZoneName: zoneID.zoneName)
    }

    private func snapshot(_ householdID: String, _ creationDate: Date?) -> GardenRootSnapshot {
        let id = CKRecord.ID(recordName: SeedkeepRecordNames.household(householdID),
                             zoneID: SeedkeepZoneProvisioner.zoneID(householdID: householdID))
        let record = CKRecord(recordType: "Household", recordID: id)
        return GardenRootSnapshot(record: record, creationDate: creationDate)
    }

    func inspect(scope: GardenDatabaseScope, zoneID: CKRecordZone.ID) async throws -> GardenInspection {
        let id = Self.householdID(of: zoneID)
        let inspectGate = lock.withLock { _inspectGate }
        await inspectGate?()
        let (error, root) = lock.withLock { () -> (Error?, Root?) in
            _inspectCalls.append(id)
            return (_inspectErrors.isEmpty ? nil : _inspectErrors.removeFirst(), _roots[id])
        }
        if let error { throw error }
        switch root {
        case .present(let creationDate)?: return .present(snapshot(id, creationDate))
        case .rootMissing?: return .rootMissing
        case .zoneMissing?, nil: return .zoneMissing
        case .listedButZoneReadMissing?: return try LiveGardenProvisioner.inspection(listed: true, read: .zoneMissing)
        }
    }

    func readRoot(scope: GardenDatabaseScope, zoneID: CKRecordZone.ID) async -> GardenRootRead {
        let id = Self.householdID(of: zoneID)
        let gate = lock.withLock { _readGate }
        await gate?()
        return lock.withLock { () -> GardenRootRead in
            _readRootCalls.append(id)
            if !_readScript.isEmpty { return _readScript.removeFirst() }
            switch _roots[id] {
            case .present(let creationDate)?: return .present(snapshot(id, creationDate))
            case .rootMissing?: return .rootMissing
            case .zoneMissing?, nil: return .zoneMissing
            case .listedButZoneReadMissing?: return LiveGardenProvisioner.confirmed(.zoneMissing, listed: true)
            }
        }
    }

    func participantPermission(zoneID: CKRecordZone.ID) async -> SharePermission { permission }

    func ensureShare(for root: CKRecord, title: String) async throws -> CKShare {
        lock.withLock { _shareSaves.append(root.recordID.recordName) }
        return CKShare(rootRecord: root)
    }

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
