import SwiftUI
import SeedkeepKit

/// Pure presentation card for a plant pet. Three size variants per the
/// Phase 5 spec — `.rollCall` for the Today garden roll-call strip,
/// `.menagerie` for the full-width list row in the Menagerie tab, and
/// `.inline` for inside a planting detail surface.
///
/// Phase 5.1.0 shipped the alive layout end-to-end. Phase 5.1.1 (this
/// commit, 4/4) lights up the remaining four lifecycle states — wilted,
/// departing, departed, graduated — per the state-to-rendering table at
/// spec line 814. Visual variations ride on parent-layer opacity and
/// rotation modifiers; per-illustration "wilted: Bool" parameters are
/// explicitly out (spec line 1601 / LOW #75).
///
/// **No animations in v1.** All transitions render statically — the
/// codebase has zero animation precedent and the spec locks the
/// "static state machine" convention for this surface.
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

    /// Minimal goodbye-note payload for departed rendering. Mirrors the
    /// surface area UI needs from `PetGoodbyeNote` without dragging
    /// SwiftData / SeedkeepKit decode plumbing into this presentation
    /// type — callers convert from `PetGoodbyeNote` at the boundary.
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
            creatureGlyph(size: 48)
                .frame(height: 56)
            Text(displayName)
                .font(HerbFont.smallCaps(size: 9))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(HerbColor.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if showsMoodDrop {
                moodDrop
            }
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
                    ZStack(alignment: .topLeading) {
                        PressedPlant(
                            kind: .generic,
                            size: 72,
                            faded: plantFaded
                        )
                        if phase == .graduated {
                            // Small laurel ornament marks graduation —
                            // gold-ink wreath on the top-leading edge of
                            // the pressed-plant column per spec line 993.
                            LaurelOrnament(size: 22)
                                .foregroundStyle(HerbColor.goldInk)
                                .offset(x: -4, y: -2)
                        }
                    }
                    // Creature column — for `.departed` we substitute the
                    // creature glyph entirely with the handwritten
                    // goodbye-note block (spec table line 819).
                    if phase == .departed {
                        departedGoodbyeBlock
                            .frame(width: 56)
                            .padding(.top, 6)
                    } else {
                        creatureGlyph(size: 44)
                            .frame(width: 44, height: 44)
                            .padding(.top, 14)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(nameFont)
                            .foregroundStyle(nameColor)
                            .lineLimit(1)
                        if showsAgeStars {
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { i in
                                    Image(systemName: i < ageStars ? "star.fill" : "star")
                                        .font(.system(size: 8))
                                        .foregroundStyle(i < ageStars ? HerbColor.sepia : HerbColor.inkFaint)
                                }
                            }
                        } else if let caption = terminalCaption {
                            Text(caption)
                                .font(HerbFont.smallCaps(size: 9))
                                .tracking(1.8)
                                .textCase(.uppercase)
                                .foregroundStyle(HerbColor.sageDk)
                        }
                        if showsMoodDrop {
                            moodDrop
                        }
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

    // MARK: - Creature glyph + departed substitute

    /// The companion illustration with the lifecycle-phase opacity and
    /// rotation applied at the parent layer (spec LOW #75). Departed
    /// callers don't reach this — they show `departedGoodbyeBlock`
    /// instead.
    @ViewBuilder
    private func creatureGlyph(size: CGFloat) -> some View {
        CompanionIllustration(kind: creatureKind, size: size, faded: creatureFaded)
            .opacity(creatureOpacity)
            .rotationEffect(.degrees(creatureRotation))
    }

    /// Handwritten goodbye-note block shown in place of the creature for
    /// `.departed`. Renders the first line of `note_text` (split on
    /// newline) plus the signoff. Falls back to a sepia em-dash when no
    /// note is available yet (e.g. the depart RPC just landed and the
    /// `LocalPetDeparture` row hasn't reached the view yet — handled
    /// gracefully so we never show an empty box).
    @ViewBuilder
    private var departedGoodbyeBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let note = goodbyeNote {
                Text(firstLine(of: note.noteText))
                    .font(HerbFont.handwritten(size: 16))
                    .foregroundStyle(HerbColor.sepia)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(note.signoff)
                    .font(HerbFont.handwritten(size: 14))
                    .foregroundStyle(HerbColor.sepia.opacity(0.85))
                    .italic()
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(HerbFont.handwritten(size: 16))
                    .foregroundStyle(HerbColor.sepia)
            }
        }
    }

    /// Drop everything after the first newline. Mirrors the spec's
    /// notification-body rule for the departed banner (spec line 1192),
    /// which is the closest analogue for the inline preview surface.
    private func firstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = trimmed.firstIndex(where: { $0.isNewline }) {
            return String(trimmed[..<newline])
        }
        return trimmed
    }

    // MARK: - Mood drop + state-derived modifiers

    @ViewBuilder
    private var moodDrop: some View {
        Circle()
            .fill(moodColor)
            .frame(width: 6, height: 6)
    }

    /// Per-phase mood-drop color (spec state table). Departed and
    /// graduated pets never show a mood drop — those branches are
    /// gated upstream by `showsMoodDrop`. For `.wilted` and
    /// `.departing` the tint locks to `moodWilted` /
    /// `moodDepartingImminent` regardless of the upstream `mood`
    /// argument so a stale snapshot can't render an off-tone drop.
    private var moodColor: Color {
        Self.moodColor(phase: phase, mood: mood)
    }

    /// Whether the mood drop is rendered. Terminal states (departed,
    /// graduated) drop the indicator entirely per the state table.
    private var showsMoodDrop: Bool { Self.showsMoodDrop(phase: phase) }

    /// Whether the 5-star age row is rendered. Hidden for terminal
    /// states — graduated swaps in a `GRADUATED` caption instead; the
    /// departed surface shows the goodbye note in the creature column
    /// and omits the row entirely (spec state table).
    private var showsAgeStars: Bool { Self.showsAgeStars(phase: phase) }

    /// Caption substituted for the age-stars row in `.graduated`. Nil
    /// for any other state (departed shows no caption either).
    private var terminalCaption: String? { Self.terminalCaption(phase: phase) }

    /// `CompanionIllustration.faded` flag — driven separately from
    /// parent-layer `opacity` because the primitive's `faded` toggle
    /// pre-fades the *strokes* (a softer treatment than just an opacity
    /// pass over the whole glyph). Today this only fires for `.departed`
    /// (the creature glyph is replaced anyway; the fade flag remains
    /// here for the roll-call variant which still calls the glyph in
    /// that state).
    private var creatureFaded: Bool { Self.creatureFaded(phase: phase) }

    /// Parent-layer opacity by phase.
    private var creatureOpacity: Double { Self.creatureOpacity(phase: phase) }

    /// Parent-layer rotation (degrees, CCW negative).
    private var creatureRotation: Double { Self.creatureRotation(phase: phase) }

    /// `PressedPlant.faded` flag per spec state table.
    private var plantFaded: Bool { Self.plantFaded(phase: phase) }

    /// Name font — italic display for live pets, upright (non-italic)
    /// for departed per spec line 824. Graduated keeps the italic
    /// display.
    private var nameFont: Font { Self.nameFont(phase: phase) }

    /// Name color — softens for departed (the lifecycle is over;
    /// emphasis moves to the goodbye note).
    private var nameColor: Color { Self.nameColor(phase: phase) }

    // MARK: - Static visual-state helpers (test surface)
    //
    // Hoisting the per-phase visual rules to static `internal` methods
    // lets `SeedkeepTests` assert the spec state-table without poking
    // at the SwiftUI view body — pure functions of `phase` (+ `mood`
    // for the alive branch of the drop color) keep the visual contract
    // out of snapshot drift territory.

    /// Per spec state table:
    /// alive 1.0, wilted 0.7, departing 0.45, departed 0.25 (fallback
    /// for the roll-call variant which keeps the glyph), graduated 1.0.
    static func creatureOpacity(phase: PetLifecyclePhase) -> Double {
        switch phase {
        case .alive:      return 1.0
        case .wilted:     return 0.7
        case .departing:  return 0.45
        case .departed:   return 0.25
        case .graduated:  return 1.0
        }
    }

    /// Wilted + departing droop with a -8° CCW rotation; alive /
    /// departed / graduated render upright (spec state table).
    static func creatureRotation(phase: PetLifecyclePhase) -> Double {
        switch phase {
        case .wilted, .departing: return -8
        default:                  return 0
        }
    }

    /// `PressedPlant.faded` flag per spec state table. Alive / wilted /
    /// graduated render full ink; departing + departed soften.
    static func plantFaded(phase: PetLifecyclePhase) -> Bool {
        switch phase {
        case .departing, .departed: return true
        default:                    return false
        }
    }

    /// `CompanionIllustration.faded` mirror — `.departed` softens the
    /// strokes for the fallback roll-call rendering.
    static func creatureFaded(phase: PetLifecyclePhase) -> Bool {
        phase == .departed
    }

    static func showsMoodDrop(phase: PetLifecyclePhase) -> Bool {
        switch phase {
        case .alive, .wilted, .departing: return true
        case .departed, .graduated:       return false
        }
    }

    static func showsAgeStars(phase: PetLifecyclePhase) -> Bool {
        switch phase {
        case .alive, .wilted, .departing: return true
        case .departed, .graduated:       return false
        }
    }

    static func terminalCaption(phase: PetLifecyclePhase) -> String? {
        phase == .graduated ? "GRADUATED" : nil
    }

    static func moodColor(phase: PetLifecyclePhase, mood: PetMoodLabel) -> Color {
        switch phase {
        case .wilted:
            return HerbColor.moodWilted
        case .departing:
            return HerbColor.moodDepartingImminent
        case .alive:
            switch mood {
            case .thriving:          return HerbColor.moodThriving
            case .content:           return HerbColor.moodContent
            case .quiet:             return HerbColor.moodQuiet
            case .wilted:            return HerbColor.moodWilted
            case .departingImminent: return HerbColor.moodDepartingImminent
            }
        case .departed, .graduated:
            return HerbColor.inkFaint
        }
    }

    static func nameFont(phase: PetLifecyclePhase) -> Font {
        switch phase {
        case .departed: return HerbFont.displayUpright(size: 22)
        default:        return HerbFont.display(size: 22)
        }
    }

    static func nameColor(phase: PetLifecyclePhase) -> Color {
        switch phase {
        case .departed: return HerbColor.inkSoft
        default:        return HerbColor.ink
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabelText: String {
        var parts: [String] = [
            displayName,
            "\(rarity.rawValue) \(creatureDisplay)",
            phase.rawValue
        ]
        switch phase {
        case .alive, .wilted, .departing:
            parts.append(mood.rawValue)
            parts.append("\(ageStars) stars")
        case .graduated:
            parts.append("graduated")
        case .departed:
            if let g = goodbyeNote {
                parts.append("goodbye note: \(g.noteText)")
                parts.append("signoff: \(g.signoff)")
            } else {
                parts.append("goodbye note arriving")
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Laurel ornament

/// Small gold-ink laurel wreath used to mark `.graduated` pets. Two
/// arcing leaf rows that meet at the top — drawn in `HerbColor.goldInk`
/// via `.foregroundStyle` at the call site. Pure SwiftUI shapes, no
/// asset dependency. Scales with `size`.
private struct LaurelOrnament: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            drawHalf(ctx: ctx, center: center, radius: s * 0.45, mirrored: false)
            drawHalf(ctx: ctx, center: center, radius: s * 0.45, mirrored: true)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func drawHalf(ctx: GraphicsContext, center: CGPoint, radius: CGFloat, mirrored: Bool) {
        let direction: CGFloat = mirrored ? -1 : 1
        // Each side: an arcing stem + 4 leaf ellipses.
        var stem = Path()
        stem.move(to: CGPoint(x: center.x, y: center.y + radius))
        stem.addQuadCurve(
            to: CGPoint(x: center.x + direction * radius * 0.9, y: center.y - radius * 0.7),
            control: CGPoint(x: center.x + direction * radius * 1.2, y: center.y)
        )
        ctx.stroke(stem, with: .style(.foreground), lineWidth: max(1.0, radius * 0.08))

        // Leaves along the arc.
        let leafCount = 4
        for i in 0..<leafCount {
            let t = CGFloat(i + 1) / CGFloat(leafCount + 1)
            let leafCenter = quad(
                start: CGPoint(x: center.x, y: center.y + radius),
                control: CGPoint(x: center.x + direction * radius * 1.2, y: center.y),
                end: CGPoint(x: center.x + direction * radius * 0.9, y: center.y - radius * 0.7),
                t: t
            )
            let leafSize = radius * 0.28
            let rect = CGRect(
                x: leafCenter.x - leafSize / 2,
                y: leafCenter.y - leafSize / 4,
                width: leafSize,
                height: leafSize / 2
            )
            var leaf = Path(ellipseIn: rect)
            // Rotate the leaf so it tilts away from the stem.
            let angle = Angle.degrees(direction * (-25 + Double(i) * 8))
            leaf = leaf.applying(CGAffineTransform(translationX: -leafCenter.x, y: -leafCenter.y))
            leaf = leaf.applying(CGAffineTransform(rotationAngle: CGFloat(angle.radians)))
            leaf = leaf.applying(CGAffineTransform(translationX: leafCenter.x, y: leafCenter.y))
            ctx.fill(leaf, with: .style(.foreground))
        }
    }

    private func quad(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let oneMinusT = 1 - t
        let x = oneMinusT * oneMinusT * start.x + 2 * oneMinusT * t * control.x + t * t * end.x
        let y = oneMinusT * oneMinusT * start.y + 2 * oneMinusT * t * control.y + t * t * end.y
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Previews — 5 lifecycle phases × representative rarity tiers

#Preview("Alive — Common Ladybug") {
    PetCard.previewWrapper(
        rarity: .common,
        creatureKind: "ladybug",
        name: "Speck",
        phase: .alive,
        mood: .content,
        ageStars: 2
    )
}

#Preview("Wilted — Uncommon Hummingbird") {
    PetCard.previewWrapper(
        rarity: .uncommon,
        creatureKind: "hummingbird",
        name: "Vesper",
        phase: .wilted,
        mood: .wilted,
        ageStars: 3
    )
}

#Preview("Departing — Rare Barn Owl") {
    PetCard.previewWrapper(
        rarity: .rare,
        creatureKind: "barn_owl",
        name: "Mottle",
        phase: .departing,
        mood: .departingImminent,
        ageStars: 4
    )
}

#Preview("Departed — Legendary Peacock") {
    PetCard.previewWrapper(
        rarity: .legendary,
        creatureKind: "peacock",
        name: "Argive",
        phase: .departed,
        mood: .departingImminent,
        ageStars: 5,
        goodbyeNote: PetCard.GoodbyeNoteV1(
            noteText: "The garden was a long song. I sang what I could.",
            signoff: "— Argive"
        )
    )
}

#Preview("Graduated — Mythical Garden Imp") {
    PetCard.previewWrapper(
        rarity: .mythical,
        creatureKind: "garden_imp",
        name: "Vermilion",
        phase: .graduated,
        mood: .thriving,
        ageStars: 5
    )
}

#Preview("All phases — common tier strip") {
    ScrollView {
        VStack(spacing: 18) {
            PetCard.previewWrapper(rarity: .common, creatureKind: "ant",   name: "Mote",     phase: .alive,     mood: .content)
            PetCard.previewWrapper(rarity: .common, creatureKind: "snail", name: "Patience", phase: .wilted,    mood: .wilted)
            PetCard.previewWrapper(rarity: .common, creatureKind: "slug",  name: "Drift",    phase: .departing, mood: .departingImminent)
            PetCard.previewWrapper(
                rarity: .common,
                creatureKind: "ladybug",
                name: "Speck",
                phase: .departed,
                mood: .departingImminent,
                goodbyeNote: PetCard.GoodbyeNoteV1(noteText: "I'll miss you.", signoff: "— Speck")
            )
            PetCard.previewWrapper(rarity: .common, creatureKind: "robin", name: "Cinder",   phase: .graduated, mood: .thriving)
        }
        .padding(20)
        .background(VellumBackground())
    }
}

#Preview("Roll-call strip") {
    HStack(spacing: 10) {
        PetCard.previewWrapper(
            rarity: .common,
            creatureKind: "snail",
            name: "Patience",
            phase: .alive,
            mood: .content,
            variant: .rollCall
        )
        PetCard.previewWrapper(
            rarity: .uncommon,
            creatureKind: "bee",
            name: "Mote",
            phase: .wilted,
            mood: .wilted,
            variant: .rollCall
        )
        PetCard.previewWrapper(
            rarity: .mythical,
            creatureKind: "wisp",
            name: "Ember",
            phase: .alive,
            mood: .thriving,
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
        phase: PetLifecyclePhase = .alive,
        mood: PetMoodLabel = .content,
        ageStars: Int = 2,
        goodbyeNote: GoodbyeNoteV1? = nil,
        variant: Variant = .menagerie
    ) -> some View {
        let pet = LocalPlantingEvent(
            id: "preview-\(creatureKind)-\(phase.rawValue)",
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
            mood: mood,
            phase: phase,
            ageStars: ageStars,
            goodbyeNote: goodbyeNote
        )
        .padding(variant == .rollCall ? 0 : 18)
        .background(variant == .rollCall ? AnyView(Color.clear) : AnyView(VellumBackground()))
    }
}
