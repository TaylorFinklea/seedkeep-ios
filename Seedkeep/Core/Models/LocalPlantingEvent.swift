import Foundation
import SwiftData

/// SwiftData mirror of `PlantingEventDTO`. Phase 2 garden plan timeline.
@Model
public final class LocalPlantingEvent {
    @Attribute(.unique) public var id: String
    public var householdID: String
    public var bedID: String?
    public var seedID: String?
    public var catalogSeedID: String?
    /// Raw `PlantingEventKind.rawValue` — "sowing", "transplant",
    /// "harvest", "note". Stored as string so SwiftData doesn't need
    /// to know about the SeedkeepKit-defined enum at compile time.
    public var kindRaw: String
    /// YYYY-MM-DD string, as the server stores it. Sortable
    /// lexicographically; clients convert to Date for display.
    public var plannedFor: String
    public var completedAt: Int64?
    public var notes: String?
    /// Position within the bed, in feet from origin (0,0 = bottom-left).
    /// Both nil until the user places the event in the layout.
    public var xFeet: Double?
    public var yFeet: Double?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        id: String,
        householdID: String,
        bedID: String? = nil,
        seedID: String? = nil,
        catalogSeedID: String? = nil,
        kindRaw: String,
        plannedFor: String,
        completedAt: Int64? = nil,
        notes: String? = nil,
        xFeet: Double? = nil,
        yFeet: Double? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.bedID = bedID
        self.seedID = seedID
        self.catalogSeedID = catalogSeedID
        self.kindRaw = kindRaw
        self.plannedFor = plannedFor
        self.completedAt = completedAt
        self.notes = notes
        self.xFeet = xFeet
        self.yFeet = yFeet
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
