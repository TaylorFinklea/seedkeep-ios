import Foundation
import SwiftData
import SeedkeepKit

@Model
public final class LocalSeedPhoto {
    @Attribute(.unique) public var id: String
    public var seedID: String
    public var householdID: String
    public var r2Key: String
    public var roleRaw: String
    public var width: Int?
    public var height: Int?
    public var byteSize: Int?
    public var capturedAt: Int64

    public init(
        id: String,
        seedID: String,
        householdID: String,
        r2Key: String,
        role: PhotoRole,
        width: Int? = nil,
        height: Int? = nil,
        byteSize: Int? = nil,
        capturedAt: Int64
    ) {
        self.id = id
        self.seedID = seedID
        self.householdID = householdID
        self.r2Key = r2Key
        self.roleRaw = role.rawValue
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.capturedAt = capturedAt
    }

    public var role: PhotoRole {
        get { PhotoRole(rawValue: roleRaw) ?? .extra }
        set { roleRaw = newValue.rawValue }
    }
}
