import Foundation
import SeedkeepCloudKit

enum ActiveGardenContext {
    static let participantZoneNameDefaultsKey = "seedkeep.sharing.participant.zoneName"
    static let participantOwnerNameDefaultsKey = "seedkeep.sharing.participant.ownerName"

    static func householdID(
        signedInHouseholdID: String,
        participantZoneName: String?,
        cloudKitSyncEnabled: Bool
    ) -> String {
        guard cloudKitSyncEnabled, let participantZoneName, !participantZoneName.isEmpty else {
            return signedInHouseholdID
        }
        return SeedkeepRecordNames.householdID(fromZoneName: participantZoneName)
    }

    static func participantZoneName(in defaults: UserDefaults = .standard) -> String? {
        guard let zoneName = defaults.string(forKey: participantZoneNameDefaultsKey),
              !zoneName.isEmpty,
              let ownerName = defaults.string(forKey: participantOwnerNameDefaultsKey),
              !ownerName.isEmpty else { return nil }
        return zoneName
    }

    /// The recorded shared garden (zone name and owner), or nil when this device is not a
    /// participant. Both keys must be present, as for `participantZoneName(in:)`.
    static func participant(in defaults: UserDefaults = .standard) -> (zoneName: String, ownerName: String)? {
        guard let zoneName = participantZoneName(in: defaults),
              let ownerName = defaults.string(forKey: participantOwnerNameDefaultsKey) else { return nil }
        return (zoneName, ownerName)
    }

    /// Records a shared garden as this device's active garden (the participant marker).
    static func recordParticipant(zoneName: String, ownerName: String, in defaults: UserDefaults = .standard) {
        defaults.set(zoneName, forKey: participantZoneNameDefaultsKey)
        defaults.set(ownerName, forKey: participantOwnerNameDefaultsKey)
    }

    /// Removes the participant marker, so the device's own garden is active again.
    static func clearParticipant(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: participantZoneNameDefaultsKey)
        defaults.removeObject(forKey: participantOwnerNameDefaultsKey)
    }
}
