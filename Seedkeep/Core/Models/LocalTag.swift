import Foundation
import SwiftData

@Model
public final class LocalTag {
    @Attribute(.unique) public var id: String
    public var householdID: String
    public var name: String
    public var color: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        id: String,
        householdID: String,
        name: String,
        color: String? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
