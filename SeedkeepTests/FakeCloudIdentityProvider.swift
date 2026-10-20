import Foundation
@testable import Seedkeep

/// `CloudIdentityProviding` test double: no CloudKit. Every answer is settable between calls,
/// every call is counted, and the next record-name fetch or zone listing can be held open so a
/// test can run another transition while a resolution is suspended.
final class FakeCloudIdentityProvider: CloudIdentityProviding, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _status: CloudAccountStatus
    private var _recordName: String?
    private var _owned: [GardenZoneSummary]?
    private var _shared: [GardenZoneSummary]?
    private var _listCalls: [GardenDatabaseScope] = []
    private var _recordNameCalls = 0
    private var _accountStatusCalls = 0
    private var holdRecordName = false
    private var holdListing = false
    private var heldRecordName: CheckedContinuation<Void, Never>?
    private var heldListing: CheckedContinuation<Void, Never>?

    /// `recordName`, `owned` or `shared` set to nil makes that call throw.
    init(status: CloudAccountStatus = .available, recordName: String? = "_userA",
         owned: [GardenZoneSummary]? = [], shared: [GardenZoneSummary]? = []) {
        _status = status
        _recordName = recordName
        _owned = owned
        _shared = shared
    }

    var status: CloudAccountStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var recordName: String? {
        get { lock.withLock { _recordName } }
        set { lock.withLock { _recordName = newValue } }
    }
    var owned: [GardenZoneSummary]? {
        get { lock.withLock { _owned } }
        set { lock.withLock { _owned = newValue } }
    }
    var shared: [GardenZoneSummary]? {
        get { lock.withLock { _shared } }
        set { lock.withLock { _shared = newValue } }
    }
    var listCalls: [GardenDatabaseScope] { lock.withLock { _listCalls } }
    var recordNameCalls: Int { lock.withLock { _recordNameCalls } }
    var accountStatusCalls: Int { lock.withLock { _accountStatusCalls } }

    // MARK: Holding a call open

    func holdNextRecordNameFetch() { lock.withLock { holdRecordName = true } }
    func holdNextListing() { lock.withLock { holdListing = true } }

    func releaseRecordNameFetch() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { heldRecordName = nil }
            return heldRecordName
        }
        continuation?.resume()
    }

    func releaseListing() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { heldListing = nil }
            return heldListing
        }
        continuation?.resume()
    }

    func waitUntilRecordNameFetchIsHeld() async {
        while lock.withLock({ heldRecordName == nil }) { await Task.yield() }
    }

    func waitUntilListingIsHeld() async {
        while lock.withLock({ heldListing == nil }) { await Task.yield() }
    }

    // MARK: CloudIdentityProviding

    func accountStatus() async -> CloudAccountStatus {
        lock.withLock {
            _accountStatusCalls += 1
            return _status
        }
    }

    func currentUserRecordName() async throws -> String {
        let hold = lock.withLock { () -> Bool in
            _recordNameCalls += 1
            defer { holdRecordName = false }
            return holdRecordName
        }
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { heldRecordName = continuation }
            }
        }
        guard let recordName else { throw Failure() }
        return recordName
    }

    func listGardenZones(_ scope: GardenDatabaseScope) async throws -> [GardenZoneSummary] {
        let hold = lock.withLock { () -> Bool in
            _listCalls.append(scope)
            defer { holdListing = false }
            return holdListing
        }
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { heldListing = continuation }
            }
        }
        // Read after any hold, so a test can change the account while a listing is suspended.
        guard let zones = scope == .owned ? owned : shared else { throw Failure() }
        return zones
    }

    // MARK: Fixtures

    static func zone(
        _ householdID: String, scope: GardenDatabaseScope = .owned,
        owner: String? = nil, name: String? = nil, updatedAt: Int64? = nil
    ) -> GardenZoneSummary {
        GardenZoneSummary(
            householdID: householdID,
            zoneName: "seedkeep-\(householdID)",
            ownerName: owner ?? (scope == .owned ? "__defaultOwner__" : "_owner_\(householdID)"),
            scope: scope,
            name: name,
            createdAt: updatedAt,
            updatedAt: updatedAt)
    }
}
