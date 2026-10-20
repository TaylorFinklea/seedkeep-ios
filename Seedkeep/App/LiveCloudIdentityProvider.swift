// Apple-only identity (N1): the live iCloud side of `AuthController`'s resolution.
import CloudKit
import Foundation
import SeedkeepCloudKit
import Synchronization

/// Talks to `iCloud.app.seedkeep`. Every call is bounded to 10 s: a broken cloudd auth token can
/// hang a CloudKit call indefinitely and ignore cancellation, so each call races a detached sleep
/// into a resume-once continuation (the `HouseholdCloudCoordinator.accountStatus` pattern) and a
/// wedged call is abandoned rather than blocking resolution.
///
/// The container is built per call, not at init: `AppEnvironment.live()` constructs this provider
/// in the unit-test host too, and nothing there may touch CloudKit.
struct LiveCloudIdentityProvider: CloudIdentityProviding {
    private static let timeoutSeconds: UInt64 = 10

    private var container: CKContainer { SeedkeepZoneProvisioner().container }

    func accountStatus() async -> CloudAccountStatus {
        let container = self.container
        let status = try? await Self.bounded { try await container.accountStatus() }
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        // couldNotDetermine, temporarilyUnavailable, a failure or a timeout: transient.
        default: return .unverified
        }
    }

    func currentUserRecordName() async throws -> String {
        let container = self.container
        return try await Self.bounded { try await container.userRecordID().recordName }
    }

    /// A Seedkeep garden zone. The live CloudKit spike checks (`SeedkeepSpikeChecks`, debug builds)
    /// left `seedkeep-spike-*` zones in the Production container; they are test fixtures, never
    /// gardens (real household IDs are server IDs or UUIDs), so they are never offered or adopted.
    static func isGardenZoneName(_ zoneName: String) -> Bool {
        zoneName.hasPrefix("seedkeep-") && !zoneName.hasPrefix("seedkeep-spike-")
    }

    func listGardenZones(_ scope: GardenDatabaseScope) async throws -> [GardenZoneSummary] {
        let database = scope == .owned ? container.privateCloudDatabase : container.sharedCloudDatabase
        // A listing failure throws: it must never read as "no gardens".
        let zoneIDs = try await Self.bounded {
            try await database.allRecordZones()
                .map(\.zoneID)
                .filter { Self.isGardenZoneName($0.zoneName) }
        }
        guard !zoneIDs.isEmpty else { return [] }

        let rootIDs = zoneIDs.map { zoneID in
            CKRecord.ID(
                recordName: SeedkeepRecordNames.household(
                    SeedkeepRecordNames.householdID(fromZoneName: zoneID.zoneName)),
                zoneID: zoneID)
        }
        // The `Household` root only supplies display fields. A missing or unreadable root (or a
        // failed batch) leaves them nil; it is not an error.
        let roots: [CKRecord.ID: RootFields] = (try? await Self.bounded {
            let results = try await database.records(for: rootIDs)
            var fields: [CKRecord.ID: RootFields] = [:]
            for (id, result) in results {
                guard case .success(let record) = result else { continue }
                fields[id] = RootFields(
                    name: record["name"] as? String,
                    createdAt: (record["createdAt"] as? NSNumber)?.int64Value,
                    updatedAt: (record["updatedAt"] as? NSNumber)?.int64Value)
            }
            return fields
        }) ?? [:]

        return zip(zoneIDs, rootIDs).map { zoneID, rootID in
            let root = roots[rootID]
            return GardenZoneSummary(
                householdID: SeedkeepRecordNames.householdID(fromZoneName: zoneID.zoneName),
                zoneName: zoneID.zoneName,
                ownerName: zoneID.ownerName,
                scope: scope,
                name: root?.name,
                createdAt: root?.createdAt,
                updatedAt: root?.updatedAt)
        }
    }

    private struct RootFields: Sendable {
        let name: String?
        let createdAt: Int64?
        let updatedAt: Int64?
    }

    struct TimedOut: Error, LocalizedError {
        var errorDescription: String? { "iCloud didn't answer in time. Seedkeep will try again." }
    }

    /// Runs `operation` detached and gives up after `nanoseconds` (default `timeoutSeconds`),
    /// abandoning (leaking) a hung call instead of awaiting it. Also bounds the share accept in
    /// `AppEnvironment`.
    static func bounded<T: Sendable>(
        nanoseconds: UInt64 = timeoutSeconds * 1_000_000_000,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do { once.resume(continuation, with: .success(try await operation())) }
                catch { once.resume(continuation, with: .failure(error)) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: nanoseconds)
                once.resume(continuation, with: .failure(TimedOut()))
            }
        }
    }
}

/// Resumes a continuation exactly once across the racing operation and timeout tasks.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let done = Mutex(false)

    func resume(_ continuation: CheckedContinuation<T, any Error>, with result: Result<T, any Error>) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { continuation.resume(with: result) }
    }
}
