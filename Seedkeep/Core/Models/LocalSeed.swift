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
