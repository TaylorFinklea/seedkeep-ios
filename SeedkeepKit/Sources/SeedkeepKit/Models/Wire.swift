import Foundation

/// Wire-format DTOs — Codable mirrors of the Workers API JSON shapes. These
/// are deliberately separate from the SwiftData `@Model` types in the iOS
/// app so we can decode server payloads without touching the local store
/// (and vice versa: tests can construct a server fixture without
/// instantiating a ModelContainer).

public struct UserDTO: Codable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let email: String?
}

public struct HouseholdDTO: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let created_at: Int64
    public let updated_at: Int64
}

public struct MembershipDTO: Codable, Sendable, Equatable {
    public let user_id: String
    public let role: String
    public let joined_at: Int64
    public let name: String?
    public let email: String?
}

public struct InviteDTO: Codable, Sendable, Equatable {
    public let id: String
    public let code: String
    public let expires_at: Int64
}

public struct LocationDTO: Codable, Sendable, Equatable {
    public let id: String
    public let household_id: String
    public let name: String
    public let sort_order: Int
    public let created_at: Int64
    public let updated_at: Int64
    public let deleted_at: Int64?
}

public struct TagDTO: Codable, Sendable, Equatable {
    public let id: String
    public let household_id: String
    public let name: String
    public let color: String?
    public let created_at: Int64
    public let updated_at: Int64
    public let deleted_at: Int64?
}

public struct SeedDTO: Codable, Sendable, Equatable {
    public let id: String
    public let household_id: String
    public let catalog_id: String?
    public let state: SeedState
    public let packet_count: Int
    public let location_id: String?
    public let year_packed: Int?
    public let source: SeedSource
    public let custom_name: String?
    public let custom_variety: String?
    public let custom_company: String?
    public let notes: String?
    public let created_at: Int64
    public let updated_at: Int64
    public let deleted_at: Int64?
    public let tag_ids: [String]
}

public struct SeedPhotoDTO: Codable, Sendable, Equatable {
    public let id: String
    public let seed_id: String
    public let household_id: String
    public let r2_key: String
    public let role: PhotoRole
    public let width: Int?
    public let height: Int?
    public let byte_size: Int?
    public let captured_at: Int64
}

public struct CatalogSeedDTO: Codable, Sendable, Equatable {
    public let id: String
    public let barcode: String?
    public let perceptual_hash: String?
    public let common_name: String
    public let scientific_name: String?
    public let variety: String?
    public let company: String?
    public let instructions: String?
    public let viability_years: Int?
    // Horticultural data — populated by AI extraction when present on
    // the packet; null otherwise. Phase 2 surfaces these in garden-plan
    // validation and planting-calendar derivation.
    public let days_to_germinate_min: Int?
    public let days_to_germinate_max: Int?
    public let days_to_maturity_min: Int?
    public let days_to_maturity_max: Int?
    public let soil_temp_min_f: Int?
    public let soil_temp_max_f: Int?
    public let seed_depth_inches: Double?
    public let plant_spacing_inches: Int?
    public let row_spacing_inches: Int?
    public let sun_requirement: String?   // "full" | "partial" | "shade"
    public let frost_tolerance: String?   // "tender" | "half_hardy" | "hardy"
    public let sow_method: String?        // "direct" | "transplant" | "either"
    public let life_cycle: String?        // "annual" | "biennial" | "perennial"
    public let hardiness_zone_min: Int?
    public let hardiness_zone_max: Int?
    public let status: String
    public let confidence: Double?
    public let created_at: Int64
    public let updated_at: Int64
    public let published_at: Int64?
}

/// Phase 2: garden bed (a named, household-scoped growing space).
public struct BedDTO: Codable, Sendable, Equatable {
    public let id: String
    public let household_id: String
    public let name: String
    public let description: String?
    public let width_feet: Double?
    public let length_feet: Double?
    public let sort_order: Int
    public let created_at: Int64
    public let updated_at: Int64
    public let deleted_at: Int64?
}

/// Phase 2: planting event — a single dated action inside a bed.
/// `kind` is one of "sowing", "transplant", "harvest", "note".
/// `planned_for` is a YYYY-MM-DD string (date-only, no timezone).
/// `completed_at` is ms-epoch when the user marks the event done.
public struct PlantingEventDTO: Codable, Sendable, Equatable {
    public let id: String
    public let household_id: String
    public let bed_id: String?
    public let seed_id: String?
    public let catalog_seed_id: String?
    public let kind: String
    public let planned_for: String
    public let completed_at: Int64?
    public let notes: String?
    /// Position within the bed, measured in feet from the bottom-left
    /// corner (origin 0,0). Both nil until the user places the event.
    public let x_feet: Double?
    public let y_feet: Double?
    public let created_at: Int64
    public let updated_at: Int64
    public let deleted_at: Int64?
}

public enum PlantingEventKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case sowing
    case transplant
    case harvest
    case note
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .sowing: return "Sow"
        case .transplant: return "Transplant"
        case .harvest: return "Harvest"
        case .note: return "Note"
        }
    }
    public var systemImage: String {
        switch self {
        case .sowing: return "leaf.fill"
        case .transplant: return "arrow.up.bin.fill"
        case .harvest: return "basket.fill"
        case .note: return "note.text"
        }
    }
}

/// Generic delta-sync response: `{ items: [T], cursor: <ms>, has_more: bool }`.
public struct DeltaPage<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let items: [Item]
    public let cursor: Int64
    public let has_more: Bool
}

/// Response payloads used by typed `SeedkeepClient` calls.
public enum WireResponses {
    public struct Me: Codable, Sendable, Equatable {
        public let user: UserDTO
    }

    public struct CreateOrFetchHousehold: Codable, Sendable, Equatable {
        public let household: HouseholdDTO
        public let role: String
    }

    public struct Members: Codable, Sendable, Equatable {
        public let household: HouseholdDTO
        public let members: [MembershipDTO]
    }

    public struct Invite: Codable, Sendable, Equatable {
        public let invite: InviteDTO
    }

    public struct LocationOne: Codable, Sendable, Equatable {
        public let location: LocationDTO
    }

    public struct BedOne: Codable, Sendable, Equatable {
        public let bed: BedDTO
    }

    public struct PlantingEventOne: Codable, Sendable, Equatable {
        public let planting_event: PlantingEventDTO
    }

    public struct TagOne: Codable, Sendable, Equatable {
        public let tag: TagDTO
    }

    public struct SeedOne: Codable, Sendable, Equatable {
        public let seed: SeedDTO
    }

    public struct SeedDetail: Codable, Sendable, Equatable {
        public let seed: SeedDTO
        public let photos: [SeedPhotoDTO]
    }

    public struct ExtractionResult: Codable, Sendable, Equatable {
        public let extraction_id: String
        public let catalog_seed_id: String?
        public let decision: ExtractionDecision
        public let extraction: ExtractionFields
        public let review: ExtractionReview
        public let photo_keys: ExtractionPhotoKeys
    }

    public struct ExtractionDecision: Codable, Sendable, Equatable {
        public let status: String   // "published" | "pending" | "rejected"
        public let reason: String?
    }

    public struct ExtractionFields: Codable, Sendable, Equatable {
        public let common_name: String?
        public let scientific_name: String?
        public let variety: String?
        public let company: String?
        public let instructions: String?
        public let days_to_germinate_min: Int?
        public let days_to_germinate_max: Int?
        public let days_to_maturity_min: Int?
        public let days_to_maturity_max: Int?
        public let soil_temp_min_f: Int?
        public let soil_temp_max_f: Int?
        public let seed_depth_inches: Double?
        public let plant_spacing_inches: Int?
        public let row_spacing_inches: Int?
        public let sun_requirement: String?
        public let frost_tolerance: String?
        public let sow_method: String?
        public let life_cycle: String?
        public let hardiness_zone_min: Int?
        public let hardiness_zone_max: Int?
        public let self_confidence: Double?
    }

    public struct ExtractionReview: Codable, Sendable, Equatable {
        public let score: Double
        public let notes: String
    }

    public struct ExtractionPhotoKeys: Codable, Sendable, Equatable {
        public let front: String
        public let back: String
    }

    /// Response from `POST /api/extractions/pre-extracted`. Mirrors
    /// `ExtractionResult` except `photo_keys` is a flat array (the
    /// pre-extracted route stores 0–2 photos depending on what the client
    /// uploaded) and `review.score` is the client-supplied
    /// `self_confidence` rather than a server-side reviewer score.
    public struct PreExtractedResult: Codable, Sendable, Equatable {
        public let extraction_id: String
        public let catalog_seed_id: String?
        public let decision: ExtractionDecision
        public let extraction: ExtractionFields
        public let review: ExtractionReview
        public let photo_keys: [String]
    }
}
