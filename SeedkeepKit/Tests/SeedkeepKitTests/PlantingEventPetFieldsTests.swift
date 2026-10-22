import Testing
import Foundation
@testable import SeedkeepKit

/// Phase 5.1.0 — the plant-pet value types: rarity tiers, `PetPersonality`'s
/// tolerant decoding, and the mood and lifecycle enums' raw values.
@Suite("Plant-pet value types")
struct PlantingEventPetFieldsTests {

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
}
