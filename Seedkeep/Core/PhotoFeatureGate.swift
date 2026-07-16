import SeedkeepKit

enum PhotoFeatureGate {
    static var isRestricted: Bool {
        FeatureFlags.serverPhotoFeaturesRestricted
    }

    static func requireAvailable() throws {
        guard !isRestricted else {
            throw SeedkeepError(
                code: "cloudkit_feature_unavailable",
                message: FeatureFlags.cloudKitPhotoCapabilityMessage
            )
        }
    }
}
