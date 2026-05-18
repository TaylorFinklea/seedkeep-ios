import Foundation
import SwiftData

/// SwiftData mirror of `BedDTO`. Phase 2 garden plan foundation.
@Model
public final class LocalBed {
    @Attribute(.unique) public var id: String
    public var householdID: String
    public var name: String
    public var bedDescription: String?
    public var widthFeet: Double?
    public var lengthFeet: Double?
    public var sortOrder: Int
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        id: String,
        householdID: String,
        name: String,
        bedDescription: String? = nil,
        widthFeet: Double? = nil,
        lengthFeet: Double? = nil,
        sortOrder: Int = 0,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.bedDescription = bedDescription
        self.widthFeet = widthFeet
        self.lengthFeet = lengthFeet
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
