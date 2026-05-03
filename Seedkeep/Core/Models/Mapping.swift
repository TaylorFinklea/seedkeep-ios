import Foundation
import SeedkeepKit

/// DTO → SwiftData @Model conversions used by the SyncEngine to upsert.
/// Kept narrow on purpose — the views never touch DTOs directly.

extension LocationDTO {
    func makeLocal() -> LocalLocation {
        LocalLocation(
            id: id,
            householdID: household_id,
            name: name,
            sortOrder: sort_order,
            createdAt: created_at,
            updatedAt: updated_at,
            deletedAt: deleted_at
        )
    }

    func apply(to local: LocalLocation) {
        local.householdID = household_id
        local.name = name
        local.sortOrder = sort_order
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
    }
}

extension TagDTO {
    func makeLocal() -> LocalTag {
        LocalTag(
            id: id,
            householdID: household_id,
            name: name,
            color: color,
            createdAt: created_at,
            updatedAt: updated_at,
            deletedAt: deleted_at
        )
    }

    func apply(to local: LocalTag) {
        local.householdID = household_id
        local.name = name
        local.color = color
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
    }
}

extension SeedDTO {
    func makeLocal() -> LocalSeed {
        LocalSeed(
            id: id,
            householdID: household_id,
            catalogID: catalog_id,
            state: state,
            packetCount: packet_count,
            locationID: location_id,
            yearPacked: year_packed,
            source: source,
            customName: custom_name,
            customVariety: custom_variety,
            customCompany: custom_company,
            notes: notes,
            tagIDs: tag_ids,
            createdAt: created_at,
            updatedAt: updated_at,
            deletedAt: deleted_at
        )
    }

    func apply(to local: LocalSeed) {
        local.householdID = household_id
        local.catalogID = catalog_id
        local.state = state
        local.packetCount = packet_count
        local.locationID = location_id
        local.yearPacked = year_packed
        local.source = source
        local.customName = custom_name
        local.customVariety = custom_variety
        local.customCompany = custom_company
        local.notes = notes
        local.tagIDs = tag_ids
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
    }
}
