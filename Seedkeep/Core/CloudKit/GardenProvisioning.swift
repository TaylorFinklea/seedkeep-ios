import CloudKit
import Foundation
import SeedkeepCloudKit

/// What a start check found: one zone listing of the garden's database, then a read of its root.
enum GardenInspection: @unchecked Sendable {
    /// The zone is not in the database's listing. It never existed here, or it was deleted.
    case zoneMissing
    /// The zone is there and the `Household` root is confirmed absent.
    case rootMissing
    /// The root, with its server `creationDate` (the generation).
    case present(GardenRootSnapshot)
}

extension GardenInspection {
    var isRootMissing: Bool {
        if case .rootMissing = self { return true }
        return false
    }
}

/// A participant's permission on a shared garden, from the share's `currentUserParticipant`.
enum SharePermission: Sendable, Equatable {
    case readOnly, readWrite
    /// The share or the participant could not be read: never treated as read-only.
    case unknown
}

/// The reads the guard needs from iCloud, for an owned garden (private database) and a shared one
/// (shared database). Tests pass a fake that records every read.
protocol GardenInspecting: Sendable {
    /// The start check: one zone listing, then the root. Throws for any error that does not
    /// confirm the garden missing, so nothing is sent and the pass retries as today.
    func inspect(scope: GardenDatabaseScope, zoneID: CKRecordZone.ID) async throws -> GardenInspection
    /// The batch check's read: the root straight from the database (not through the engine), bounded
    /// to 10 seconds. A shared garden whose read says missing is confirmed by the shared listing.
    func readRoot(scope: GardenDatabaseScope, zoneID: CKRecordZone.ID) async -> GardenRootRead
    /// The current user's permission on a shared garden.
    func participantPermission(zoneID: CKRecordZone.ID) async -> SharePermission
}

/// What the owner coordinator needs from iCloud to start a garden. `LiveGardenProvisioner` is the
/// shipping implementation; tests pass a fake that records every zone save and root save.
///
/// N2-E: no method here creates a zone except `createGarden`, which the coordinator calls only for a
/// household holding a creation grant. Inspection and `ensureShare` act inside an existing zone.
protocol GardenProvisioning: GardenInspecting {
    /// The bounded iCloud account check; nil on timeout.
    func accountStatus() async -> CKAccountStatus?
    /// Saves a brand-new garden's zone and `Household` root (the creation-grant path).
    func createGarden(householdID: String, name: String) async -> GardenCreationOutcome
    func ensureShare(for root: CKRecord, title: String) async throws -> CKShare
    /// One listing of the owned garden zones, for discovery. Bounded.
    func listOwnedGardens() async throws -> [GardenZoneSummary]
}

struct LiveGardenProvisioner: GardenProvisioning {
    private let provisioner = SeedkeepZoneProvisioner()

    var container: CKContainer { provisioner.container }

    private func database(_ scope: GardenDatabaseScope) -> CKDatabase {
        scope == .owned ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    func accountStatus() async -> CKAccountStatus? {
        let container = provisioner.container
        return try? await LiveCloudIdentityProvider.bounded { try await container.accountStatus() }
    }

    func createGarden(householdID: String, name: String) async -> GardenCreationOutcome {
        await provisioner.createGarden(householdID: householdID, name: name)
    }

    func inspect(scope: GardenDatabaseScope, zoneID: CKRecordZone.ID) async throws -> GardenInspection {
        let database = database(scope)
        // A listing error (offline, account, timeout) is thrown as it is: it never confirms a garden
        // missing, so nothing is sent and the pass retries as today.
        let zones = try await LiveCloudIdentityProvider.bounded {
            try await database.allRecordZones().map(\.zoneID)
        }
        let listed = zones.contains { $0.zoneName == zoneID.zoneName && $0.ownerName == zoneID.ownerName }
        let read = listed ? await boundedRead(database, zoneID) : .zoneMissing
        return try Self.inspection(listed: listed, read: read)
    }

    /// The verdict of a start check from the listing and the root read. The zone is missing only when
    /// the listing does not show it. A listed zone whose read said `zoneMissing` contradicts the
    /// listing, so it is unconfirmed: an error, never gone. (A listing is the authority for a zone.)
    static func inspection(listed: Bool, read: GardenRootRead) throws -> GardenInspection {
        guard listed else { return .zoneMissing }
        switch confirmed(read, listed: true) {
        case .present(let snapshot): return .present(snapshot)
        case .rootMissing: return .rootMissing
        case .zoneMissing: return .zoneMissing   // unreachable: a listed zone never reads as missing
        case .failed(let failure): throw SyncEngineError.batchCheckFailed(failure)
        }
    }

    func readRoot(scope: GardenDatabaseScope, zoneID: CKRecordZone.ID) async -> GardenRootRead {
        let database = database(scope)
        let read = await boundedRead(database, zoneID)
        guard scope == .shared else { return read }
        switch read {
        case .zoneMissing, .rootMissing:
            // A shared zone's removal is read from the shared listing, not from one root read.
            do {
                let zones = try await LiveCloudIdentityProvider.bounded {
                    try await database.allRecordZones().map(\.zoneID)
                }
                let listed = zones.contains { $0.zoneName == zoneID.zoneName && $0.ownerName == zoneID.ownerName }
                return Self.confirmed(read, listed: listed)
            } catch is LiveCloudIdentityProvider.TimedOut {
                return .failed(.timedOut)
            } catch {
                return .failed((error as? CKError).map { .cloudKit($0.code.rawValue) } ?? .unavailable)
            }
        case .present, .failed:
            return read
        }
    }

    /// A shared root read that said the zone or root is missing, checked against the shared listing.
    /// The zone is gone only when the listing does not show it. A listed zone contradicts a
    /// `zoneMissing` read, so the read is unconfirmed (a failure, never gone); a listed zone with a
    /// missing root stays `rootMissing`.
    static func confirmed(_ read: GardenRootRead, listed: Bool) -> GardenRootRead {
        switch read {
        case .zoneMissing:
            return listed ? .failed(.cloudKit(CKError.Code.zoneNotFound.rawValue)) : .zoneMissing
        case .rootMissing:
            return listed ? .rootMissing : .zoneMissing
        case .present, .failed:
            return read
        }
    }

    private func boundedRead(_ database: CKDatabase, _ zoneID: CKRecordZone.ID) async -> GardenRootRead {
        let rootID = CKRecord.ID(
            recordName: SeedkeepRecordNames.household(SeedkeepRecordNames.householdID(fromZoneName: zoneID.zoneName)),
            zoneID: zoneID)
        do {
            return try await LiveCloudIdentityProvider.bounded {
                await SeedkeepZoneProvisioner.readRoot(rootID) { try await database.record(for: $0) }
            }
        } catch {
            return .failed(.timedOut)
        }
    }

    func participantPermission(zoneID: CKRecordZone.ID) async -> SharePermission {
        let database = container.sharedCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let permission: SharePermission? = try? await LiveCloudIdentityProvider.bounded {
            guard let share = try await database.record(for: shareID) as? CKShare,
                  let participant = share.currentUserParticipant else { return SharePermission.unknown }
            switch participant.permission {
            case .readOnly: return .readOnly
            case .readWrite: return .readWrite
            default: return .unknown
            }
        }
        return permission ?? .unknown
    }

    func ensureShare(for root: CKRecord, title: String) async throws -> CKShare {
        try await provisioner.ensureShare(for: root, title: title)
    }

    func listOwnedGardens() async throws -> [GardenZoneSummary] {
        try await LiveCloudIdentityProvider().listGardenZones(.owned)
    }
}

/// Creates or fetches the owner's zone-wide share. `beforeSave` runs right before a new share is
/// saved and throws to refuse it. Tests pass a fake that records every save.
protocol OwnerShareMaking: Sendable {
    func makeOrFetch(householdID: String, title: String, beforeSave: @Sendable () async throws -> Void) async throws -> CKShare
}

struct LiveOwnerShareMaker: OwnerShareMaking {
    func makeOrFetch(householdID: String, title: String, beforeSave: @Sendable () async throws -> Void) async throws -> CKShare {
        try await SeedkeepShareFlow().makeOrFetchZoneWideShare(
            householdID: householdID, title: title, beforeSave: beforeSave)
    }
}

/// What a coordinator needs from the guard: the store, the account it is acting for, the re-home
/// seam, the fresh-ID source and the runner that owns the transitions (grant creation and
/// abandonment, the gone handling). nil on a coordinator with no guard (tests of the plain sync path).
@MainActor
struct GardenGuardContext {
    let store: GardenGuardStore
    /// The current iCloud account's key, nil while none is resolved.
    let accountKey: @MainActor () -> String?
    let rehomer: any GardenRehoming
    var makeFreshID: () -> String
    let runner: GardenGuardRunner

    init(
        store: GardenGuardStore, accountKey: @escaping @MainActor () -> String?,
        rehomer: any GardenRehoming, makeFreshID: @escaping () -> String = { GardenHouseholdID.make() },
        runner: GardenGuardRunner? = nil
    ) {
        self.store = store
        self.accountKey = accountKey
        self.rehomer = rehomer
        self.makeFreshID = makeFreshID
        self.runner = runner ?? GardenGuardRunner(store: store, rehomer: rehomer)
    }
}
