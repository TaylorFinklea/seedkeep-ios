import Foundation

/// Value types the app shares across its local store, CloudKit records and extraction. Several
/// keep the snake_case shapes of the retired server's JSON, which stored data still uses.

/// The signed-in iCloud identity (`AuthController.State`).
public struct UserDTO: Codable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let email: String?
}

/// The active garden (`AuthController.State`).
public struct HouseholdDTO: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let created_at: Int64
    public let updated_at: Int64
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

/// Sprout-authored personality vignette for a plant pet, stored as JSON in
/// `LocalPlantingEvent.petPersonalityJSON` (the retired server's
/// `planting_events.pet_personality`).
///
/// The `name` field inside this struct is authoritative; the planting's
/// `petName` is a denormalized cache. `version` lets us evolve the shape later.
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

    // Stored shape is snake_case, as the retired server wrote it.
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

/// Sprout-authored departure note. Mirrors the server-side
/// `PetDepartureNoteSchema` validated payload plus the fallback-tracking
/// bookkeeping appended at storage time. UI surfaces `noteText` and
/// `signoff`; the `fallback*` keys are informational so the client can
/// know whether a future server retry will upgrade the note.
public struct PetGoodbyeNote: Codable, Sendable, Equatable, Hashable {
    public let noteText: String
    public let signoff: String
    public let fallback: Bool
    public let fallbackAttempts: Int
    public let lastAttemptAt: Int64

    public init(
        noteText: String,
        signoff: String,
        fallback: Bool = false,
        fallbackAttempts: Int = 0,
        lastAttemptAt: Int64 = 0
    ) {
        self.noteText = noteText
        self.signoff = signoff
        self.fallback = fallback
        self.fallbackAttempts = fallbackAttempts
        self.lastAttemptAt = lastAttemptAt
    }

    // Wire is snake_case to match the goodbye_note JSON the server writes
    // to `pet_departures.goodbye_note`. Defensive defaults so a payload
    // missing the fallback-bookkeeping keys (e.g. a future shape evolution)
    // still decodes.
    private enum CodingKeys: String, CodingKey {
        case noteText = "note_text"
        case signoff
        case fallback
        case fallbackAttempts = "fallback_attempts"
        case lastAttemptAt = "last_attempt_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.noteText = try c.decodeIfPresent(String.self, forKey: .noteText) ?? ""
        self.signoff = try c.decodeIfPresent(String.self, forKey: .signoff) ?? ""
        self.fallback = try c.decodeIfPresent(Bool.self, forKey: .fallback) ?? false
        self.fallbackAttempts = try c.decodeIfPresent(Int.self, forKey: .fallbackAttempts) ?? 0
        self.lastAttemptAt = try c.decodeIfPresent(Int64.self, forKey: .lastAttemptAt) ?? 0
    }
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

/// Namespace kept for `ExtractionFields`, the packet fields an on-device or BYOK extraction fills.
public enum WireResponses {
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

        /// Public so an on-device or BYOK extraction can fill these fields without a server
        /// response (N2). Parameters mirror the stored properties above.
        public init(
            common_name: String? = nil,
            scientific_name: String? = nil,
            variety: String? = nil,
            company: String? = nil,
            instructions: String? = nil,
            days_to_germinate_min: Int? = nil,
            days_to_germinate_max: Int? = nil,
            days_to_maturity_min: Int? = nil,
            days_to_maturity_max: Int? = nil,
            soil_temp_min_f: Int? = nil,
            soil_temp_max_f: Int? = nil,
            seed_depth_inches: Double? = nil,
            plant_spacing_inches: Int? = nil,
            row_spacing_inches: Int? = nil,
            sun_requirement: String? = nil,
            frost_tolerance: String? = nil,
            sow_method: String? = nil,
            life_cycle: String? = nil,
            hardiness_zone_min: Int? = nil,
            hardiness_zone_max: Int? = nil,
            self_confidence: Double? = nil
        ) {
            self.common_name = common_name
            self.scientific_name = scientific_name
            self.variety = variety
            self.company = company
            self.instructions = instructions
            self.days_to_germinate_min = days_to_germinate_min
            self.days_to_germinate_max = days_to_germinate_max
            self.days_to_maturity_min = days_to_maturity_min
            self.days_to_maturity_max = days_to_maturity_max
            self.soil_temp_min_f = soil_temp_min_f
            self.soil_temp_max_f = soil_temp_max_f
            self.seed_depth_inches = seed_depth_inches
            self.plant_spacing_inches = plant_spacing_inches
            self.row_spacing_inches = row_spacing_inches
            self.sun_requirement = sun_requirement
            self.frost_tolerance = frost_tolerance
            self.sow_method = sow_method
            self.life_cycle = life_cycle
            self.hardiness_zone_min = hardiness_zone_min
            self.hardiness_zone_max = hardiness_zone_max
            self.self_confidence = self_confidence
        }
    }
}
