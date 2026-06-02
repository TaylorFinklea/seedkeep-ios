import Testing
import Foundation
@testable import SeedkeepKit

/// Phase 5.1.0 — verifies the six new `pet_*` fields on
/// `PlantingEventDTO` round-trip cleanly through JSON in both directions
/// (populated and nil) and that the nested `PetPersonality` decodes from
/// its TEXT-JSON server representation.
@Suite("PlantingEventDTO plant-pet fields")
struct PlantingEventPetFieldsTests {

    @Test func legacyRowDecodesWithMissingPetFields() throws {
        // Legacy pre-0018 rows omit every pet_* field. Codable should
        // decode them as nil without throwing.
        let json = """
        {
          "id": "pe_legacy",
          "household_id": "h",
          "bed_id": null,
          "seed_id": null,
          "catalog_seed_id": null,
          "kind": "sowing",
          "planned_for": "2026-06-02",
          "completed_at": null,
          "notes": null,
          "x_feet": null,
          "y_feet": null,
          "created_at": 1717000000000,
          "updated_at": 1717000000000,
          "deleted_at": null
        }
        """
        let dto = try JSONDecoder().decode(PlantingEventDTO.self, from: Data(json.utf8))
        #expect(dto.pet_seed == nil)
        #expect(dto.pet_rarity == nil)
        #expect(dto.pet_creature_kind == nil)
        #expect(dto.pet_name == nil)
        #expect(dto.pet_personality == nil)
        #expect(dto.pet_spawned_at == nil)
        #expect(dto.decodedPetPersonality() == nil)
    }

    @Test func populatedRowRoundTripsThroughCodable() throws {
        // pet_personality is a raw JSON string on the wire; the server
        // stores it TEXT-encoded so this matches the actual payload.
        let personalityJSON = """
        {
          "name": "Vermilion",
          "vignette": "A small steward of leaf-shadow, fond of dusk.",
          "voice_hint": "Speaks in soft second-person, slightly archaic.",
          "traits": ["watchful", "patient"],
          "tone": "reverent",
          "version": 1,
          "fallback": false,
          "fallback_attempts": 0,
          "last_attempt_at": 0
        }
        """
        let json = """
        {
          "id": "pe_1",
          "household_id": "h",
          "bed_id": "b1",
          "seed_id": "s1",
          "catalog_seed_id": null,
          "kind": "sowing",
          "planned_for": "2026-06-02",
          "completed_at": null,
          "notes": null,
          "x_feet": 1.5,
          "y_feet": 2.0,
          "created_at": 1717000000000,
          "updated_at": 1717000000001,
          "deleted_at": null,
          "pet_seed": "abc123def4567890abc123def4567890abc123def4567890abc123def4567890",
          "pet_rarity": "mythical",
          "pet_creature_kind": "dryad",
          "pet_name": "Vermilion",
          "pet_personality": \(jsonStringLiteral(personalityJSON)),
          "pet_spawned_at": 1717000000000
        }
        """
        let decoded = try JSONDecoder().decode(PlantingEventDTO.self, from: Data(json.utf8))
        #expect(decoded.pet_seed?.count == 64)
        #expect(decoded.pet_rarity == "mythical")
        #expect(decoded.pet_creature_kind == "dryad")
        #expect(decoded.pet_name == "Vermilion")
        #expect(decoded.pet_spawned_at == 1717000000000)

        // The nested personality decodes via the helper.
        let personality = try #require(decoded.decodedPetPersonality())
        #expect(personality.name == "Vermilion")
        #expect(personality.voiceHint.hasPrefix("Speaks"))
        #expect(personality.traits == ["watchful", "patient"])
        #expect(personality.tone == "reverent")
        #expect(personality.version == 1)
        #expect(personality.fallback == false)
        #expect(personality.fallbackAttempts == 0)

        // Round-trip through encode/decode preserves every field.
        let encoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(PlantingEventDTO.self, from: encoded)
        #expect(again == decoded)
    }

    @Test func petRarityEnumCoversCheckConstraint() {
        // Spec-locked five-tier set — adding tiers requires a server
        // migration, so the enum doubles as a compile-time guard.
        #expect(Set(PetRarity.allCases.map(\.rawValue)) == [
            "common", "uncommon", "rare", "legendary", "mythical",
        ])
    }

    @Test func petPersonalityToleratesMissingFields() throws {
        // Fallback rows from the retry path may omit traits/tone — verify
        // defensive defaults kick in.
        let json = """
        {
          "name": "Pip",
          "vignette": "Stub bio.",
          "voice_hint": "Plain second-person.",
          "version": 1,
          "fallback": true,
          "fallback_attempts": 1,
          "last_attempt_at": 1717000000000
        }
        """
        let personality = try JSONDecoder().decode(PetPersonality.self, from: Data(json.utf8))
        #expect(personality.name == "Pip")
        #expect(personality.traits.isEmpty)
        #expect(personality.tone == "")
        #expect(personality.fallback == true)
        #expect(personality.fallbackAttempts == 1)
        #expect(personality.lastAttemptAt == 1717000000000)
    }

    @Test func moodLabelRawValuesSortAscendingByMood() {
        // The spec relies on case order to sort live pets worst-mood-first
        // in Today's roll-call and Menagerie's Alive section.
        let order = PetMoodLabel.allCases
        #expect(order.first == .departingImminent)
        #expect(order.last == .thriving)
    }

    @Test func lifecyclePhaseRawValuesMatchSpec() {
        // Spec-derived case names; double-check no typo drift between
        // SwiftData stored strings and the enum.
        let raws = PetLifecyclePhase.allCases.map(\.rawValue)
        #expect(raws == ["alive", "wilted", "departing", "departed", "graduated"])
    }

    // MARK: - Helpers

    /// Wrap a multi-line JSON blob into a JSON-safe string literal
    /// (escapes quotes + newlines). The pet_personality field on the
    /// wire is a TEXT column holding JSON, so the outer envelope must
    /// embed the inner JSON as an escaped string.
    private func jsonStringLiteral(_ raw: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
}
