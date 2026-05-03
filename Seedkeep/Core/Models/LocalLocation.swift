import Foundation
import SwiftData

/// SwiftData mirror of `LocationDTO`. Lives in the app target so SwiftData
/// doesn't bleed into `SeedkeepKit` (which we want testable on macOS via
/// `swift test`, no SwiftData dependency).
@Model
public final class LocalLocation {
    @Attribute(.unique) public var id: String
    public var householdID: String
    public var name: String
    public var sortOrder: Int
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        id: String,
        householdID: String,
        name: String,
        sortOrder: Int,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
