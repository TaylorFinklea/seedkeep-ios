import Foundation
import SwiftData
import SeedkeepKit

/// SwiftData mirror of `SeedDTO`. Stores `state` and `source` as the raw
/// strings of `SeedState` / `SeedSource` so the schema doesn't depend on
/// Swift enum metadata. Convenience accessors translate.
@Model
public final class LocalSeed {
    @Attribute(.unique) public var id: String
    public var householdID: String
    public var catalogID: String?
    public var stateRaw: String
    public var packetCount: Int
    public var locationID: String?
    public var yearPacked: Int?
    public var sourceRaw: String
    public var customName: String?
    public var customVariety: String?
    public var customCompany: String?
    public var notes: String?
    /// Tag IDs as a JSON-encoded array. SwiftData supports `[String]` natively
    /// but JSON keeps the schema flat for cross-version migrations.
    public var tagIDsJSON: String
    /// Snapshot of horticultural fields captured at save time (from a catalog
    /// match or AI extraction). Local-only — the catalog is still the shared
    /// source of truth, but this guarantees the user can always see depth /
    /// temp / spacing for *their* seed even offline, for manual entries, or
    /// when the catalog row hasn't been populated yet.
    public var growingInfoJSON: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        id: String,
        householdID: String,
        catalogID: String? = nil,
        state: SeedState,
        packetCount: Int,
        locationID: String? = nil,
        yearPacked: Int? = nil,
        source: SeedSource,
        customName: String? = nil,
        customVariety: String? = nil,
        customCompany: String? = nil,
        notes: String? = nil,
        tagIDs: [String] = [],
        growingInfo: GrowingInfoSnapshot? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.catalogID = catalogID
        self.stateRaw = state.rawValue
        self.packetCount = packetCount
        self.locationID = locationID
        self.yearPacked = yearPacked
        self.sourceRaw = source.rawValue
        self.customName = customName
        self.customVariety = customVariety
        self.customCompany = customCompany
        self.notes = notes
        self.tagIDsJSON = (try? String(data: JSONEncoder().encode(tagIDs), encoding: .utf8)) ?? "[]"
        self.growingInfoJSON = growingInfo.flatMap { snap in
            (try? JSONEncoder().encode(snap)).flatMap { String(data: $0, encoding: .utf8) }
        }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var state: SeedState {
        get { SeedState(rawValue: stateRaw) ?? .active }
        set { stateRaw = newValue.rawValue }
    }

    public var source: SeedSource {
        get { SeedSource(rawValue: sourceRaw) ?? .store }
        set { sourceRaw = newValue.rawValue }
    }

    public var tagIDs: [String] {
        get {
            guard let data = tagIDsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            tagIDsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    public var growingInfo: GrowingInfoSnapshot? {
        get {
            guard let json = growingInfoJSON,
                  let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(GrowingInfoSnapshot.self, from: data)
        }
        set {
            growingInfoJSON = newValue.flatMap { snap in
                (try? JSONEncoder().encode(snap)).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
    }

    /// Display name preferring the user-set custom name, falling back to
    /// the catalog (resolved by the view layer when needed).
    public var displayName: String {
        customName?.trimmedNonEmpty ?? "Untitled seed"
    }

    /// `true` when the packet is at least 3 calendar years old. UI uses
    /// this to render the "older — check germination" badge per the
    /// generic-3-year-threshold decision in `decisions.md`.
    public func isOlderThanThresholdYears(_ threshold: Int = 3, currentYear: Int) -> Bool {
        guard let year = yearPacked else { return false }
        return (currentYear - year) >= threshold
    }
}

// trimmedNonEmpty lives in AddSeedView.swift as an internal-access
// String extension; reuse it here.

/// Local snapshot of horticultural facts surfaced to the user in the seed
/// detail view. Captured at save time from a catalog match or AI extraction
/// so the user always sees the values they reviewed — even offline, for
/// manual entries, or when the catalog row hasn't yet been populated.
///
/// Field names mirror `CatalogSeedDTO` / `ExtractionFields` so existing
/// formatting helpers (`humanFrost`, `formatRange`, …) can be reused as-is.
public struct GrowingInfoSnapshot: Codable, Sendable, Equatable {
    public var scientific_name: String?
    public var life_cycle: String?
    public var sun_requirement: String?
    public var frost_tolerance: String?
    public var sow_method: String?
    public var seed_depth_inches: Double?
    public var days_to_germinate_min: Int?
    public var days_to_germinate_max: Int?
    public var days_to_maturity_min: Int?
    public var days_to_maturity_max: Int?
    public var soil_temp_min_f: Int?
    public var soil_temp_max_f: Int?
    public var plant_spacing_inches: Int?
    public var row_spacing_inches: Int?
    public var hardiness_zone_min: Int?
    public var hardiness_zone_max: Int?
    public var instructions: String?

    public init(
        scientific_name: String? = nil,
        life_cycle: String? = nil,
        sun_requirement: String? = nil,
        frost_tolerance: String? = nil,
        sow_method: String? = nil,
        seed_depth_inches: Double? = nil,
        days_to_germinate_min: Int? = nil,
        days_to_germinate_max: Int? = nil,
        days_to_maturity_min: Int? = nil,
        days_to_maturity_max: Int? = nil,
        soil_temp_min_f: Int? = nil,
        soil_temp_max_f: Int? = nil,
        plant_spacing_inches: Int? = nil,
        row_spacing_inches: Int? = nil,
        hardiness_zone_min: Int? = nil,
        hardiness_zone_max: Int? = nil,
        instructions: String? = nil
    ) {
        self.scientific_name = scientific_name
        self.life_cycle = life_cycle
        self.sun_requirement = sun_requirement
        self.frost_tolerance = frost_tolerance
        self.sow_method = sow_method
        self.seed_depth_inches = seed_depth_inches
        self.days_to_germinate_min = days_to_germinate_min
        self.days_to_germinate_max = days_to_germinate_max
        self.days_to_maturity_min = days_to_maturity_min
        self.days_to_maturity_max = days_to_maturity_max
        self.soil_temp_min_f = soil_temp_min_f
        self.soil_temp_max_f = soil_temp_max_f
        self.plant_spacing_inches = plant_spacing_inches
        self.row_spacing_inches = row_spacing_inches
        self.hardiness_zone_min = hardiness_zone_min
        self.hardiness_zone_max = hardiness_zone_max
        self.instructions = instructions
    }

    public var hasAny: Bool {
        scientific_name != nil
            || life_cycle != nil
            || sun_requirement != nil
            || frost_tolerance != nil
            || sow_method != nil
            || seed_depth_inches != nil
            || days_to_germinate_min != nil || days_to_germinate_max != nil
            || days_to_maturity_min != nil || days_to_maturity_max != nil
            || soil_temp_min_f != nil || soil_temp_max_f != nil
            || plant_spacing_inches != nil
            || row_spacing_inches != nil
            || hardiness_zone_min != nil || hardiness_zone_max != nil
            || (instructions?.isEmpty == false)
    }
}
