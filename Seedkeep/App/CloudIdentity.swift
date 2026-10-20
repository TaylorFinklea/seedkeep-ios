// Apple-only identity (N1). PARENT-OWNED contract: workers use these types and do not change
// their shape; ask the parent for additions.
//
// The iCloud account is the identity; there is no Seedkeep server and no sign-in screen.
// `AuthController` resolves an iCloud user and the user's OWN household (the zone
// `seedkeep-<householdID>` in their private database) and still publishes
// `.signedIn(user:household:)`, so the app's existing call sites keep working. A garden shared
// with the user stays the participant marker (`ActiveGardenContext`), exactly as before.
import CryptoKit
import Foundation

/// iCloud account availability, as the app acts on it.
enum CloudAccountStatus: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    /// `couldNotDetermine`, `temporarilyUnavailable`, or the bounded check timed out. Transient:
    /// enter from the cached identity if there is one; never wipe.
    case unverified
}

enum GardenDatabaseScope: String, Codable, Sendable {
    /// The user's private database: gardens they own.
    case owned
    /// The user's shared database: gardens other people shared with them.
    case shared
}

/// One Seedkeep garden zone found in the user's iCloud account.
struct GardenZoneSummary: Equatable, Sendable, Identifiable {
    let householdID: String
    let zoneName: String
    /// `CKCurrentUserDefaultName` for owned zones; the owner's record name for shared zones.
    let ownerName: String
    let scope: GardenDatabaseScope
    /// From the zone's `Household` root record; nil when it could not be read.
    let name: String?
    let createdAt: Int64?
    let updatedAt: Int64?

    var id: String { "\(scope.rawValue):\(ownerName):\(zoneName)" }
}

/// The iCloud side of identity. `LiveCloudIdentityProvider` talks to `iCloud.app.seedkeep`;
/// tests inject fakes. Every live call is bounded (10 s). Methods THROW on failure: a failed
/// listing must never read as "no gardens".
protocol CloudIdentityProviding: Sendable {
    func accountStatus() async -> CloudAccountStatus
    func currentUserRecordName() async throws -> String
    /// Zones named `seedkeep-*` in the given database, with their `Household` root fields when
    /// readable.
    func listGardenZones(_ scope: GardenDatabaseScope) async throws -> [GardenZoneSummary]
}

/// Household ID for an account that has no garden yet. Derived from the iCloud user record name
/// so two of the user's devices bootstrapping at the same time compute the same ID, and the
/// existing idempotent zone provisioning converges on one zone.
enum DeterministicHouseholdID {
    static func make(userRecordName: String) -> String {
        let digest = SHA256.hash(data: Data("seedkeep.household.v1:\(userRecordName)".utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // name-based (version 5 style)
        b[8] = (b[8] & 0x3F) | 0x80   // RFC 4122 variant
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return uuid.uuidString.lowercased()
    }
}

/// Why the app cannot enter a garden right now.
enum CloudEntryBlock: Equatable, Sendable {
    /// No iCloud account on the device: ask the user to sign in to iCloud.
    case noAccount
    /// iCloud is restricted (parental controls, device management).
    case restricted
    /// Transient failure and no cached identity to enter from: offer Retry.
    case couldNotVerify
}

/// A choice the user must make before entering. Ambiguity is never resolved by guessing.
struct GardenChoice: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// New device: the account owns several gardens. `candidates` are the owned zones.
        case multipleOwnGardens
        /// Several gardens are shared with the user. `candidates` are the shared zones;
        /// `ownGarden` is offered as "Use my own garden".
        case multipleSharedGardens
        /// Existing install whose own garden was not found in this iCloud account, while other
        /// gardens were. `candidates` are those gardens; "Keep this device's garden" is offered.
        case deviceGardenNotFound(householdID: String)
        /// Existing install whose shared garden is no longer shared with the user. `candidates`
        /// are any other shared gardens; `ownGarden` is offered. Leaving it discards this
        /// device's copy of the shared garden, after confirmation.
        case sharedGardenUnavailable(zoneName: String)
    }

    let reason: Reason
    let candidates: [GardenZoneSummary]
    /// The user's own garden as already resolved for this account (an existing zone, the
    /// device's cached household, or a synthetic summary for the deterministic ID). Choosing a
    /// shared candidate keeps it as the own household; choosing it makes the user the owner.
    let ownGarden: GardenZoneSummary?

    /// True for `.deviceGardenNotFound`: offer "Keep this device's garden" (no wipe).
    var canKeepDeviceGarden: Bool {
        if case .deviceGardenNotFound = reason { return true }
        return false
    }
}
