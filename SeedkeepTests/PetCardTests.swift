import Testing
import SwiftUI
@testable import Seedkeep
import SeedkeepKit

/// Tests for `PetCard` visual-state mapping — the spec state table
/// (Phase 5 spec line 814) locks per-phase opacity, rotation, plant
/// fading, mood-drop visibility, age-star visibility, and the
/// `GRADUATED` caption. These tests assert the static helpers that
/// power the view body so the spec contract can't drift silently.
///
/// Snapshot infrastructure isn't set up in this codebase; the
/// previews at the bottom of `PetCard.swift` cover the rendered
/// surface for visual review. These tests cover the deterministic
/// per-phase modifiers + the accessibility-label state that screen
/// readers see.
@MainActor
@Suite("PetCard — Phase 5.1.1 lifecycle rendering")
struct PetCardTests {

    // MARK: - Creature opacity per phase (spec state table)

    @Test("alive: creature drawn at full opacity, no rotation, plant un-faded")
    func aliveRenders() {
        #expect(PetCard.creatureOpacity(phase: .alive) == 1.0)
        #expect(PetCard.creatureRotation(phase: .alive) == 0)
        #expect(PetCard.plantFaded(phase: .alive) == false)
        #expect(PetCard.creatureFaded(phase: .alive) == false)
    }

    @Test("wilted: creature dims to 0.7, droops -8°, plant stays un-faded, mood-drop locks to moodWilted")
    func wiltedRenders() {
        #expect(PetCard.creatureOpacity(phase: .wilted) == 0.7)
        #expect(PetCard.creatureRotation(phase: .wilted) == -8)
        #expect(PetCard.plantFaded(phase: .wilted) == false)
        // Mood-drop tint locks regardless of the upstream mood label.
        let drop = PetCard.moodColor(phase: .wilted, mood: .content)
        #expect(drop == HerbColor.moodWilted)
    }

    @Test("departing: creature dims to 0.45 + droops -8°, plant fades, mood-drop locks to moodDepartingImminent")
    func departingRenders() {
        #expect(PetCard.creatureOpacity(phase: .departing) == 0.45)
        #expect(PetCard.creatureRotation(phase: .departing) == -8)
        #expect(PetCard.plantFaded(phase: .departing) == true)
        let drop = PetCard.moodColor(phase: .departing, mood: .content)
        #expect(drop == HerbColor.moodDepartingImminent)
    }

    @Test("departed: creature fades to 0.25 + faded strokes, plant fades, no rotation")
    func departedRenders() {
        #expect(PetCard.creatureOpacity(phase: .departed) == 0.25)
        #expect(PetCard.creatureRotation(phase: .departed) == 0)
        #expect(PetCard.plantFaded(phase: .departed) == true)
        #expect(PetCard.creatureFaded(phase: .departed) == true)
    }

    @Test("graduated: creature renders at full opacity, plant un-faded, no rotation")
    func graduatedRenders() {
        #expect(PetCard.creatureOpacity(phase: .graduated) == 1.0)
        #expect(PetCard.creatureRotation(phase: .graduated) == 0)
        #expect(PetCard.plantFaded(phase: .graduated) == false)
        #expect(PetCard.creatureFaded(phase: .graduated) == false)
    }

    // MARK: - Mood-drop and age-star visibility

    @Test("mood-drop visible for alive / wilted / departing; hidden for departed / graduated")
    func moodDropVisibility() {
        #expect(PetCard.showsMoodDrop(phase: .alive))
        #expect(PetCard.showsMoodDrop(phase: .wilted))
        #expect(PetCard.showsMoodDrop(phase: .departing))
        #expect(!PetCard.showsMoodDrop(phase: .departed))
        #expect(!PetCard.showsMoodDrop(phase: .graduated))
    }

    @Test("age-stars visible for alive / wilted / departing; hidden for departed / graduated")
    func ageStarsVisibility() {
        #expect(PetCard.showsAgeStars(phase: .alive))
        #expect(PetCard.showsAgeStars(phase: .wilted))
        #expect(PetCard.showsAgeStars(phase: .departing))
        #expect(!PetCard.showsAgeStars(phase: .departed))
        #expect(!PetCard.showsAgeStars(phase: .graduated))
    }

    @Test("GRADUATED caption shown only for the graduated phase")
    func graduatedCaption() {
        #expect(PetCard.terminalCaption(phase: .graduated) == "GRADUATED")
        #expect(PetCard.terminalCaption(phase: .alive) == nil)
        #expect(PetCard.terminalCaption(phase: .wilted) == nil)
        #expect(PetCard.terminalCaption(phase: .departing) == nil)
        #expect(PetCard.terminalCaption(phase: .departed) == nil)
    }

    // MARK: - Name treatment

    @Test("name font: departed uses displayUpright; everyone else uses italic display")
    func nameFontPerPhase() {
        // Font equality compares struct identity; the explicit
        // non-italic distinction matters per spec line 824.
        let italicCases: [PetLifecyclePhase] = [.alive, .wilted, .departing, .graduated]
        let italicReference = HerbFont.display(size: 22)
        for phase in italicCases {
            #expect(PetCard.nameFont(phase: phase) == italicReference)
        }
        #expect(PetCard.nameFont(phase: .departed) == HerbFont.displayUpright(size: 22))
    }

    @Test("name color: departed softens to inkSoft; everyone else uses ink")
    func nameColorPerPhase() {
        #expect(PetCard.nameColor(phase: .alive) == HerbColor.ink)
        #expect(PetCard.nameColor(phase: .wilted) == HerbColor.ink)
        #expect(PetCard.nameColor(phase: .departing) == HerbColor.ink)
        #expect(PetCard.nameColor(phase: .departed) == HerbColor.inkSoft)
        #expect(PetCard.nameColor(phase: .graduated) == HerbColor.ink)
    }

    // MARK: - Construction + rendering smoke test for each phase

    @Test("PetCard constructs and renders for every lifecycle phase")
    func rendersAllPhases() {
        let pet = LocalPlantingEvent(
            id: "pet-test",
            householdID: "h1",
            kindRaw: "sowing",
            plannedFor: "2026-06-01",
            createdAt: 0,
            updatedAt: 0,
            petSeed: String(repeating: "a", count: 64),
            petRarity: PetRarity.uncommon.rawValue,
            petCreatureKind: "ladybug",
            petName: "Speck",
            petPersonalityJSON: nil,
            petSpawnedAt: 0
        )
        let goodbye = PetCard.GoodbyeNoteV1(
            noteText: "Thank you for the long summer.",
            signoff: "— Speck"
        )
        for phase in PetLifecyclePhase.allCases {
            let card = PetCard(
                pet: pet,
                variant: .menagerie,
                mood: .content,
                phase: phase,
                ageStars: 3,
                goodbyeNote: phase == .departed ? goodbye : nil
            )
            // Forcing the body to evaluate catches any SwiftUI builder
            // breakage from the new phase branches (e.g. ambiguous
            // overload, missing modifier). The result is intentionally
            // discarded — we only care that the call type-checks and
            // the helpers don't trap at runtime.
            _ = card.body
        }
    }
}
