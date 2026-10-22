import Foundation

// Inputs to the app's local writes (`SyncEngine.enqueue*`). They were nested in the server client
// until N3 removed it; the fields, initializers and Codable shapes are unchanged, so stored JSON in
// the shape they encode still decodes.

/// A new seed. `id` is optional: the writer generates one when it is nil.
public struct CreateSeedInput: Codable, Sendable {
    public var id: String?
    public var catalog_id: String?
    public var state: SeedState
    public var packet_count: Int
    public var location_id: String?
    public var year_packed: Int?
    public var source: SeedSource
    public var custom_name: String?
    public var custom_variety: String?
    public var custom_company: String?
    public var notes: String?
    public var tag_ids: [String]?

    public init(
        id: String? = nil,
        catalog_id: String? = nil,
        state: SeedState,
        packet_count: Int = 1,
        location_id: String? = nil,
        year_packed: Int? = nil,
        source: SeedSource = .store,
        custom_name: String? = nil,
        custom_variety: String? = nil,
        custom_company: String? = nil,
        notes: String? = nil,
        tag_ids: [String]? = nil
    ) {
        self.id = id
        self.catalog_id = catalog_id
        self.state = state
        self.packet_count = packet_count
        self.location_id = location_id
        self.year_packed = year_packed
        self.source = source
        self.custom_name = custom_name
        self.custom_variety = custom_variety
        self.custom_company = custom_company
        self.notes = notes
        self.tag_ids = tag_ids
    }
}

/// All-optional seed patch. Omitted keys are not encoded, so only the fields the caller wants to
/// change are written.
///
/// The nullable fields (`location_id`, `year_packed`, `custom_name`, `custom_variety`,
/// `custom_company`, `notes`) are double optionals (stabilization contract decision 8): omit
/// (`nil`) = "leave alone", `.some(nil)` = JSON null = "clear", `.some(value)` = set. The
/// hand-rolled Codable below preserves that distinction in both directions.
public struct UpdateSeedInput: Codable, Sendable {
    public var catalog_id: String?
    public var state: SeedState?
    public var packet_count: Int?
    public var location_id: String??
    public var year_packed: Int??
    public var source: SeedSource?
    public var custom_name: String??
    public var custom_variety: String??
    public var custom_company: String??
    public var notes: String??
    public var tag_ids: [String]?

    public init(
        catalog_id: String? = nil,
        state: SeedState? = nil,
        packet_count: Int? = nil,
        location_id: String?? = nil,
        year_packed: Int?? = nil,
        source: SeedSource? = nil,
        custom_name: String?? = nil,
        custom_variety: String?? = nil,
        custom_company: String?? = nil,
        notes: String?? = nil,
        tag_ids: [String]? = nil
    ) {
        self.catalog_id = catalog_id
        self.state = state
        self.packet_count = packet_count
        self.location_id = location_id
        self.year_packed = year_packed
        self.source = source
        self.custom_name = custom_name
        self.custom_variety = custom_variety
        self.custom_company = custom_company
        self.notes = notes
        self.tag_ids = tag_ids
    }

    private enum CodingKeys: String, CodingKey {
        case catalog_id, state, packet_count, location_id, year_packed
        case source, custom_name, custom_variety, custom_company, notes
        case tag_ids
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalog_id = try c.decodeIfPresent(String.self, forKey: .catalog_id)
        state = try c.decodeIfPresent(SeedState.self, forKey: .state)
        packet_count = try c.decodeIfPresent(Int.self, forKey: .packet_count)
        location_id = try Self.decodeNullable(String.self, from: c, forKey: .location_id)
        year_packed = try Self.decodeNullable(Int.self, from: c, forKey: .year_packed)
        source = try c.decodeIfPresent(SeedSource.self, forKey: .source)
        custom_name = try Self.decodeNullable(String.self, from: c, forKey: .custom_name)
        custom_variety = try Self.decodeNullable(String.self, from: c, forKey: .custom_variety)
        custom_company = try Self.decodeNullable(String.self, from: c, forKey: .custom_company)
        notes = try Self.decodeNullable(String.self, from: c, forKey: .notes)
        tag_ids = try c.decodeIfPresent([String].self, forKey: .tag_ids)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v = catalog_id { try c.encode(v, forKey: .catalog_id) }
        if let v = state { try c.encode(v, forKey: .state) }
        if let v = packet_count { try c.encode(v, forKey: .packet_count) }
        // `.some(nil)` encodes JSON null; omitted keys aren't written.
        if let v = location_id { try c.encode(v, forKey: .location_id) }
        if let v = year_packed { try c.encode(v, forKey: .year_packed) }
        if let v = source { try c.encode(v, forKey: .source) }
        if let v = custom_name { try c.encode(v, forKey: .custom_name) }
        if let v = custom_variety { try c.encode(v, forKey: .custom_variety) }
        if let v = custom_company { try c.encode(v, forKey: .custom_company) }
        if let v = notes { try c.encode(v, forKey: .notes) }
        if let v = tag_ids { try c.encode(v, forKey: .tag_ids) }
    }

    /// Decodes a double-optional field: absent key → `nil` (leave
    /// alone), JSON null → `.some(nil)` (clear), value → `.some(value)`.
    private static func decodeNullable<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> T?? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) { return .some(nil) }
        return .some(try container.decode(T.self, forKey: key))
    }
}

/// A new garden bed. `id` is optional: the writer generates one when it is nil.
public struct CreateBedInput: Codable, Sendable {
    public var id: String?
    public var name: String
    public var description: String?
    public var width_feet: Double?
    public var length_feet: Double?
    public var sort_order: Int?
    public init(id: String? = nil, name: String, description: String? = nil, width_feet: Double? = nil, length_feet: Double? = nil, sort_order: Int? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.width_feet = width_feet
        self.length_feet = length_feet
        self.sort_order = sort_order
    }
}

/// All-optional bed patch; a nil field is left alone.
public struct UpdateBedInput: Codable, Sendable {
    public var name: String?
    public var description: String?
    public var width_feet: Double?
    public var length_feet: Double?
    public var sort_order: Int?
    public init(name: String? = nil, description: String? = nil, width_feet: Double? = nil, length_feet: Double? = nil, sort_order: Int? = nil) {
        self.name = name
        self.description = description
        self.width_feet = width_feet
        self.length_feet = length_feet
        self.sort_order = sort_order
    }
}

/// A new planting event. `id` is optional: the writer generates one when it is nil, and the
/// "planned for today" reminder is keyed by that id.
public struct CreatePlantingEventInput: Codable, Sendable {
    public var id: String?
    public var bed_id: String?
    public var seed_id: String?
    public var catalog_seed_id: String?
    public var kind: String
    public var planned_for: String   // YYYY-MM-DD
    public var completed_at: Int64?
    public var notes: String?
    public var x_feet: Double?
    public var y_feet: Double?
    public init(
        id: String? = nil,
        bed_id: String? = nil,
        seed_id: String? = nil,
        catalog_seed_id: String? = nil,
        kind: PlantingEventKind,
        planned_for: String,
        completed_at: Int64? = nil,
        notes: String? = nil,
        x_feet: Double? = nil,
        y_feet: Double? = nil
    ) {
        self.id = id
        self.bed_id = bed_id
        self.seed_id = seed_id
        self.catalog_seed_id = catalog_seed_id
        self.kind = kind.rawValue
        self.planned_for = planned_for
        self.completed_at = completed_at
        self.notes = notes
        self.x_feet = x_feet
        self.y_feet = y_feet
    }
}

/// Planting-event patch. `completed_at` is double-optional (stabilization contract decision 8):
/// omit (`nil`) = leave alone, `.some(nil)` = JSON null = un-complete ("mark incomplete"),
/// `.some(ms)` = completed at that instant.
public struct UpdatePlantingEventInput: Codable, Sendable {
    public var bed_id: String?
    public var seed_id: String?
    public var catalog_seed_id: String?
    public var kind: String?
    public var planned_for: String?
    public var completed_at: Int64??
    public var notes: String?
    public var x_feet: Double?
    public var y_feet: Double?
    public init(
        bed_id: String? = nil,
        seed_id: String? = nil,
        catalog_seed_id: String? = nil,
        kind: PlantingEventKind? = nil,
        planned_for: String? = nil,
        completed_at: Int64?? = nil,
        notes: String? = nil,
        x_feet: Double? = nil,
        y_feet: Double? = nil
    ) {
        self.bed_id = bed_id
        self.seed_id = seed_id
        self.catalog_seed_id = catalog_seed_id
        self.kind = kind?.rawValue
        self.planned_for = planned_for
        self.completed_at = completed_at
        self.notes = notes
        self.x_feet = x_feet
        self.y_feet = y_feet
    }

    private enum CodingKeys: String, CodingKey {
        case bed_id, seed_id, catalog_seed_id, kind, planned_for
        case completed_at, notes, x_feet, y_feet
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bed_id = try c.decodeIfPresent(String.self, forKey: .bed_id)
        seed_id = try c.decodeIfPresent(String.self, forKey: .seed_id)
        catalog_seed_id = try c.decodeIfPresent(String.self, forKey: .catalog_seed_id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        planned_for = try c.decodeIfPresent(String.self, forKey: .planned_for)
        if c.contains(.completed_at) {
            if try c.decodeNil(forKey: .completed_at) {
                completed_at = .some(nil)
            } else {
                completed_at = .some(try c.decode(Int64.self, forKey: .completed_at))
            }
        } else {
            completed_at = nil
        }
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        x_feet = try c.decodeIfPresent(Double.self, forKey: .x_feet)
        y_feet = try c.decodeIfPresent(Double.self, forKey: .y_feet)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v = bed_id { try c.encode(v, forKey: .bed_id) }
        if let v = seed_id { try c.encode(v, forKey: .seed_id) }
        if let v = catalog_seed_id { try c.encode(v, forKey: .catalog_seed_id) }
        if let v = kind { try c.encode(v, forKey: .kind) }
        if let v = planned_for { try c.encode(v, forKey: .planned_for) }
        // `.some(nil)` encodes JSON null (un-complete).
        if let v = completed_at { try c.encode(v, forKey: .completed_at) }
        if let v = notes { try c.encode(v, forKey: .notes) }
        if let v = x_feet { try c.encode(v, forKey: .x_feet) }
        if let v = y_feet { try c.encode(v, forKey: .y_feet) }
    }
}
