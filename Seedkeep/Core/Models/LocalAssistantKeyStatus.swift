import Foundation
import SwiftData

/// Tracks whether the user's BYOK API key is configured on the server, per
/// provider. Stores ONLY the configured flag — never the key itself.
///
/// `id` is a stable "household_<id>_<provider>" composite so we have at most
/// one row per provider per household.
@Model
final class LocalAssistantKeyStatus {
    @Attribute(.unique) var id: String
    var provider: String          // 'anthropic'
    var configured: Bool
    var updatedAt: Int64

    init(id: String, provider: String, configured: Bool, updatedAt: Int64) {
        self.id = id
        self.provider = provider
        self.configured = configured
        self.updatedAt = updatedAt
    }

    static func key(householdID: String, provider: String) -> String {
        "household_\(householdID)_\(provider)"
    }
}
