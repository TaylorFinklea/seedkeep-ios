import SwiftUI
import SeedkeepKit

/// Pure presentation card for a plant pet. Three size variants per the
/// Phase 5 spec — `.rollCall` for the Today garden roll-call strip,
/// `.menagerie` for the full-width list row in the Menagerie tab, and
/// `.inline` for inside a planting detail surface.
///
/// Phase 5.1.0 ships the alive lifecycle path end-to-end. Wilted /
/// departing / departed / graduated layouts are stubbed to the alive
/// rendering — `PetStateEngine` (Phase 5.1.1) lights up the rest of the
/// state table by passing a real `phase`. Keeping the API + variant
/// surface locked here lets the Lifecycle commit slot in without
/// touching downstream callers.
///
/// The card is **pure presentation** — no `@Query`, no `@Environment`.
/// Caller resolves `mood`, `phase`, `ageStars`, and `goodbyeNote` and
/// wraps the card in a tap gesture / `NavigationLink` as appropriate.
struct PetCard: View {

    /// Size + composition mode. See spec "Pet Card" section.
    enum Variant {
        /// Today garden roll-call cell — creature only, 64pt × ~96pt.
        case rollCall
        /// Full-width menagerie list row — PressedPlant + creature +
        /// name + rarity badge.
        case menagerie
        /// Same composition as `.menagerie` but caller supplies the
        /// surrounding `Section` and `Rubric`; card omits top padding.
        case inline
    }

    /// Minimal goodbye-note payload for departed rendering. Phase 5.1.0
    /// only renders alive layouts, so this is wired but unused in v1.
    /// The corresponding DTO type ships from SeedkeepKit in 5.1.1.
    struct GoodbyeNoteV1: Equatable {
        let noteText: String
        let signoff: String
    }

    let pet: LocalPlantingEvent
    var variant: Variant = .menagerie
    var mood: PetMoodLabel = .content
    var phase: PetLifecyclePhase = .alive
    var ageStars: Int = 0
    var goodbyeNote: GoodbyeNoteV1? = nil
    var onTap: (() -> Void)? = nil

    private var rarity: PetRarity { pet.petRarityValue ?? .common }
    private var creatureKind: CompanionKind { CompanionKind.from(pet.petCreatureKind) }
    private var displayName: String { pet.petName ?? pet.petPersonality?.name ?? "Companion" }
    private var creatureDisplay: String {
        // The bestiary display names are server-controlled; iOS shows
        // a humanized fallback derived from the raw identifier so we
        // never leak `garden_imp` to the user.
        (pet.petCreatureKind ?? "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var body: some View {
        Group {
            switch variant {
            case .rollCall:  rollCallVariant
            case .menagerie: menagerieVariant
            case .inline:    inlineVariant
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint("Double tap to view pet details.")
    }

    // MARK: - Variants

    @ViewBuilder
    private var rollCallVariant: some View {
        VStack(spacing: 6) {
            CompanionIllustration(kind: creatureKind, size: 48, faded: creatureFaded)
                .opacity(creatureOpacity)
                .rotationEffect(.degrees(creatureRotation))
                .frame(height: 56)
            Text(displayName)
                .font(HerbFont.smallCaps(size: 9))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(HerbColor.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            moodDrop
        }
        .frame(maxWidth: 64)
    }

    @ViewBuilder
    private var menagerieVariant: some View {
        cardSurface(showsTopPadding: true)
    }

    @ViewBuilder
    private var inlineVariant: some View {
        cardSurface(showsTopPadding: false)
    }

    // MARK: - Shared menagerie / inline body

    @ViewBuilder
    private func cardSurface(showsTopPadding: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 12) {
                    PressedPlant(
                        kind: .generic,
                        size: 72,
                        faded: plantFaded
                    )
                    CompanionIllustration(kind: creatureKind, size: 44, faded: creatureFaded)
                        .opacity(creatureOpacity)
                        .rotationEffect(.degrees(creatureRotation))
                        .frame(width: 44, height: 44)
                        .padding(.top, 14)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(HerbFont.display(size: 22))
                            .foregroundStyle(HerbColor.ink)
                            .lineLimit(1)
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { i in
                                Image(systemName: i < ageStars ? "star.fill" : "star")
                                    .font(.system(size: 8))
                                    .foregroundStyle(i < ageStars ? HerbColor.sepia : HerbColor.inkFaint)
                            }
                        }
                        moodDrop
                    }
                    Spacer(minLength: 0)
                }
                // Decorative tape strips
                HStack {
                    TapeStrip(width: 30, height: 8, rotation: -8)
                        .offset(x: 4, y: -4)
                    Spacer()
                    TapeStrip(width: 30, height: 8, rotation: 6)
                        .offset(x: -4, y: -4)
                }
            }
            ScholarRule(verticalMargin: 6)
            HStack {
                RarityBadge(rarity: rarity)
                Spacer(minLength: 8)
                Text(creatureDisplay)
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
                    .lineLimit(1)
            }
        }
        .padding(.top, showsTopPadding ? 12 : 0)
        .padding(.horizontal, 4)
    }

    // MARK: - Mood drop + state-derived modifiers

    @ViewBuilder
    private var moodDrop: some View {
        Circle()
            .fill(moodColor)
            .frame(width: 6, height: 6)
    }

    private var moodColor: Color {
        switch mood {
        case .thriving:          return HerbColor.moodThriving
        case .content:           return HerbColor.moodContent
        case .quiet:             return HerbColor.moodQuiet
        case .wilted:            return HerbColor.moodWilted
        case .departingImminent: return HerbColor.moodDepartingImminent
        }
    }

    // The Lifecycle commit (5.1.1) wires the full state table; in 5.1.0
    // only the alive branch is exercised in practice. Other branches are
    // implemented to the spec so downstream callers can begin passing
    // a real phase without changing the card.
    private var creatureFaded: Bool { phase == .departed }
    private var creatureOpacity: Double {
        switch phase {
        case .alive:      return 1.0
        case .wilted:     return 0.7
        case .departing:  return 0.45
        case .departed:   return 0.25
        case .graduated:  return 1.0
        }
    }
    private var creatureRotation: Double {
        switch phase {
        case .wilted, .departing: return -8
        default:                  return 0
        }
    }
    private var plantFaded: Bool {
        switch phase {
        case .departing, .departed: return true
        default:                    return false
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabelText: String {
        var parts: [String] = [
            displayName,
            "\(rarity.rawValue) \(creatureDisplay)",
            mood.rawValue,
            "\(ageStars) stars",
            phase.rawValue
        ]
        if phase == .departed, let g = goodbyeNote {
            parts.append("departed")
            parts.append("goodbye note: \(g.noteText)")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews — one per rarity tier (Phase 5.1.0 commit 6/7 verify)

#Preview("Common — Ladybug") {
    PetCard.previewWrapper(
        rarity: .common,
        creatureKind: "ladybug",
        name: "Speck"
    )
}

#Preview("Uncommon — Hummingbird") {
    PetCard.previewWrapper(
        rarity: .uncommon,
        creatureKind: "hummingbird",
        name: "Vesper"
    )
}

#Preview("Rare — Barn Owl") {
    PetCard.previewWrapper(
        rarity: .rare,
        creatureKind: "barn_owl",
        name: "Mottle"
    )
}

#Preview("Legendary — Peacock") {
    PetCard.previewWrapper(
        rarity: .legendary,
        creatureKind: "peacock",
        name: "Argive"
    )
}

#Preview("Mythical — Garden Imp") {
    PetCard.previewWrapper(
        rarity: .mythical,
        creatureKind: "garden_imp",
        name: "Vermilion"
    )
}

#Preview("Roll-call strip") {
    HStack(spacing: 10) {
        PetCard.previewWrapper(
            rarity: .common,
            creatureKind: "snail",
            name: "Patience",
            variant: .rollCall
        )
        PetCard.previewWrapper(
            rarity: .uncommon,
            creatureKind: "bee",
            name: "Mote",
            variant: .rollCall
        )
        PetCard.previewWrapper(
            rarity: .mythical,
            creatureKind: "wisp",
            name: "Ember",
            variant: .rollCall
        )
    }
    .padding(20)
    .background(VellumBackground())
}

private extension PetCard {
    static func previewWrapper(
        rarity: PetRarity,
        creatureKind: String,
        name: String,
        variant: Variant = .menagerie
    ) -> some View {
        let pet = LocalPlantingEvent(
            id: "preview-\(creatureKind)",
            householdID: "h1",
            kindRaw: "sowing",
            plannedFor: "2026-06-01",
            createdAt: 0,
            updatedAt: 0,
            petSeed: String(repeating: "a", count: 64),
            petRarity: rarity.rawValue,
            petCreatureKind: creatureKind,
            petName: name,
            petPersonalityJSON: nil,
            petSpawnedAt: 0
        )
        return PetCard(
            pet: pet,
            variant: variant,
            mood: .content,
            phase: .alive,
            ageStars: 2
        )
        .padding(variant == .rollCall ? 0 : 18)
        .background(variant == .rollCall ? AnyView(Color.clear) : AnyView(VellumBackground()))
    }
}
