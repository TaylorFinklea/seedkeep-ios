import CloudKit
import Foundation
import SeedkeepCloudKit

/// What the owner coordinator needs from iCloud to start a garden. `LiveGardenProvisioner` is the
/// shipping implementation; tests pass a fake that records every zone save and root save.
///
/// N2-E: no method here creates a zone except `createGarden`, which the coordinator calls only for a
/// household holding a creation grant. `ensureHousehold` and `ensureShare` act inside an existing zone.
protocol GardenProvisioning: Sendable {
    /// The bounded iCloud account check; nil on timeout.
    func accountStatus() async -> CKAccountStatus?
    /// Saves a brand-new garden's zone and `Household` root (the creation-grant path).
    func createGarden(householdID: String, name: String) async -> GardenCreationOutcome
    /// Fetch-or-create the root inside an existing zone. Never creates the zone.
    func ensureHousehold(householdID: String, name: String) async throws -> EstablishedRoot
    func ensureShare(for root: CKRecord, title: String) async throws -> CKShare
    /// One listing of the owned garden zones, for discovery. Bounded.
    func listOwnedGardens() async throws -> [GardenZoneSummary]
}

/// The root of an existing garden and its server `creationDate` (the generation trust-on-first-use records).
struct EstablishedRoot: @unchecked Sendable {
    let record: CKRecord
    let creationDate: Date?
}

struct LiveGardenProvisioner: GardenProvisioning {
    private let provisioner = SeedkeepZoneProvisioner()

    var container: CKContainer { provisioner.container }

    func accountStatus() async -> CKAccountStatus? {
        let container = provisioner.container
        return try? await LiveCloudIdentityProvider.bounded { try await container.accountStatus() }
    }

    func createGarden(householdID: String, name: String) async -> GardenCreationOutcome {
        await provisioner.createGarden(householdID: householdID, name: name)
    }

    func ensureHousehold(householdID: String, name: String) async throws -> EstablishedRoot {
        let record = try await provisioner.ensureHousehold(householdID: householdID, name: name)
        return EstablishedRoot(record: record, creationDate: record.creationDate)
    }

    func ensureShare(for root: CKRecord, title: String) async throws -> CKShare {
        try await provisioner.ensureShare(for: root, title: title)
    }

    func listOwnedGardens() async throws -> [GardenZoneSummary] {
        try await LiveCloudIdentityProvider().listGardenZones(.owned)
    }
}

/// What the owner coordinator needs from the guard: the store, the account it is acting for, the
/// re-home seam, and the fresh-ID source. nil on a coordinator with no provisioner (tests, participants).
@MainActor
struct GardenGuardContext {
    let store: GardenGuardStore
    /// The current iCloud account's key, nil while none is resolved.
    let accountKey: @MainActor () -> String?
    let rehomer: any GardenRehoming
    var makeFreshID: () -> String = { GardenHouseholdID.make() }
}
