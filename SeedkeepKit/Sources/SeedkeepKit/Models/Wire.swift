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
///
/// Phase 5: every planting also carries a "plant pet" identity stamped
/// server-side at create time. The six `pet_*` fields are nullable so
/// legacy rows (pre-0018 migration) decode cleanly; the iOS UI gates
/// pet rendering on `pet_seed != nil`. `pet_personality` ships as a raw
/// JSON string — use `decodedPetPersonality()` for a structured view.
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

    // Phase 5 — plant pet identity (server-of-record). All optional so
    // legacy rows and not-yet-migrated environments round-trip cleanly.
    /// sha256 of the planting_event_id; 64-char lowercase hex. Used as
    /// the deterministic seed for rarity + creature_kind.
    public let pet_seed: String?
    /// Raw rarity tier — one of `common`, `uncommon`, `rare`,
    /// `legendary`, `mythical`. Mirrors the server CHECK constraint.
    public let pet_rarity: String?
    /// Bestiary identifier (e.g. `garden_worm`, `spirit_fox`). Open set
    /// from the iOS side; the server enforces the catalog.
    public let pet_creature_kind: String?
    /// Denormalized cache of `pet_personality.name` for query speed.
    public let pet_name: String?
    /// Raw JSON string (TEXT on the server) holding the Sprout-authored
    /// personality blob. Decode via `decodedPetPersonality()`. Nullable
    /// for legacy rows and during the brief INSERT→UPDATE window before
    /// the personality call returns.
    public let pet_personality: String?
    /// Epoch milliseconds. Acts as the pet's "birth time" — single clock
    /// for mood + age stars (per design decision #1).
    public let pet_spawned_at: Int64?

    /// Decodes `pet_personality` JSON, returning `nil` when the field is
    /// absent or the payload is malformed. The struct shape matches the
    /// Sprout/spec-locked schema; unknown fields are tolerated.
    public func decodedPetPersonality() -> PetPersonality? {
        guard let json = pet_personality, !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(PetPersonality.self, from: Data(json.utf8))
    }
}

/// Plant-pet rarity tier. Matches the `pet_rarity` CHECK constraint on
/// `planting_events`. Sort order reflects rarity from common (low) to
/// mythical (high); use `rawValue` for wire encoding only.
public enum PetRarity: String, Codable, Sendable, CaseIterable, Hashable {
    case common
    case uncommon
    case rare
    case legendary
    case mythical
}

/// Sprout-authored personality vignette for a plant pet. Stored on the
/// server as `planting_events.pet_personality` TEXT (JSON-encoded) and
/// surfaced by `PlantingEventDTO.decodedPetPersonality()`.
///
/// The `name` field inside this struct is authoritative; the parent
/// DTO's `pet_name` column is a denormalized cache (`pet_name == name`
/// by server invariant). `version` lets us evolve the shape later.
///
/// `fallback`, `fallbackAttempts`, and `lastAttemptAt` are surfaced
/// from the server-internal retry bookkeeping. They are not used by the
/// UI in v1 — clients should check `fallback` to know whether the
/// vignette will eventually be upgraded by a server retry job.
public struct PetPersonality: Codable, Sendable, Equatable, Hashable {
    public let name: String
    public let vignette: String
    public let voiceHint: String
    public let traits: [String]
    public let tone: String
    public let version: Int
    public let fallback: Bool
    public let fallbackAttempts: Int
    public let lastAttemptAt: Int64

    public init(
        name: String,
        vignette: String,
        voiceHint: String,
        traits: [String] = [],
        tone: String = "",
        version: Int = 1,
        fallback: Bool = false,
        fallbackAttempts: Int = 0,
        lastAttemptAt: Int64 = 0
    ) {
        self.name = name
        self.vignette = vignette
        self.voiceHint = voiceHint
        self.traits = traits
        self.tone = tone
        self.version = version
        self.fallback = fallback
        self.fallbackAttempts = fallbackAttempts
        self.lastAttemptAt = lastAttemptAt
    }

    // Wire shape is snake_case to match the rest of `PlantingEventDTO`.
    // Defensive defaults make missing-key payloads (e.g. early fallback
    // rows, future shape evolutions) decode cleanly.
    private enum CodingKeys: String, CodingKey {
        case name
        case vignette
        case voiceHint = "voice_hint"
        case traits
        case tone
        case version
        case fallback
        case fallbackAttempts = "fallback_attempts"
        case lastAttemptAt = "last_attempt_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.vignette = try c.decodeIfPresent(String.self, forKey: .vignette) ?? ""
        self.voiceHint = try c.decodeIfPresent(String.self, forKey: .voiceHint) ?? ""
        self.traits = try c.decodeIfPresent([String].self, forKey: .traits) ?? []
        self.tone = try c.decodeIfPresent(String.self, forKey: .tone) ?? ""
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.fallback = try c.decodeIfPresent(Bool.self, forKey: .fallback) ?? false
        self.fallbackAttempts = try c.decodeIfPresent(Int.self, forKey: .fallbackAttempts) ?? 0
        self.lastAttemptAt = try c.decodeIfPresent(Int64.self, forKey: .lastAttemptAt) ?? 0
    }
}

/// Mood label derived client-side by `MoodEngine` from a pet's composite
/// score. Five-bucket mapping locked in the Phase 5 spec — used by Today
/// roll-call sorting, Menagerie row tints, PetCard, and the assistant's
/// `query_pet` tool. Raw values match the JSON-friendly camelCase the UI
/// expects; the assistant tool serializes these directly. The case order
/// reflects ascending mood (worst → best) and is relied on for sorts.
public enum PetMoodLabel: String, Codable, Sendable, CaseIterable, Hashable {
    case departingImminent
    case wilted
    case quiet
    case content
    case thriving
}

/// Durable lifecycle phase derived by `PetStateEngine` from mood label,
/// streak counters, `completed_at`, and `pet_departures` row existence.
/// Distinct from `PetMoodLabel` per the spec's two-enum split — views and
/// notifications branch on phase; visual tint follows mood.
public enum PetLifecyclePhase: String, Codable, Sendable, CaseIterable, Hashable {
    case alive
    case wilted
    case departing
    case departed
    case graduated
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
