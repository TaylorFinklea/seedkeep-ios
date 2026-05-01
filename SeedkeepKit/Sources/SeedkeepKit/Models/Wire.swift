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
    public let variety: String?
    public let company: String?
    public let instructions: String?
    public let viability_years: Int?
    public let status: String
    public let confidence: Double?
    public let created_at: Int64
    public let updated_at: Int64
    public let published_at: Int64?
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
        public let variety: String?
        public let company: String?
        public let instructions: String?
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
}
