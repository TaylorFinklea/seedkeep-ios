import SwiftUI
import UIKit

/// Color tokens for the Herbarium design system (V2). Vellum cream paper,
/// sepia ink, sage washes, rose/ochre accents.
///
/// Light is the canonical Herbarium palette from the design source. Dark
/// is "leather library at night" — deep cocoa background, parchment-cream
/// ink, warmer sepia + sage that still read on a dark surface.
enum HerbColor {

    // MARK: - Paper / vellum

    static let vellum     = dyn(light: 0xEFE5CC, dark: 0x2E2218)
    static let vellumHi   = dyn(light: 0xF5EDD8, dark: 0x3A2C20)
    static let vellumLo   = dyn(light: 0xE2D3AE, dark: 0x221912)
    static let vellumDk   = dyn(light: 0xC8B58A, dark: 0x14100A)

    // MARK: - Ink

    static let ink        = dyn(light: 0x2A1A0C, dark: 0xE8D9B7)
    static let inkSoft    = dyn(light: 0x2A1A0C, lightAlpha: 0.70,
                                 dark:  0xE8D9B7, darkAlpha:  0.72)
    static let inkFaint   = dyn(light: 0x2A1A0C, lightAlpha: 0.32,
                                 dark:  0xE8D9B7, darkAlpha:  0.36)

    // MARK: - Sepia

    static let sepia      = dyn(light: 0x6E4A22, dark: 0xC9985E)
    static let sepiaHi    = dyn(light: 0xA47A45, dark: 0xDDB680)

    // MARK: - Botanical accents

    static let sage       = dyn(light: 0x7A8A66, dark: 0x9CAB87)
    static let sageDk     = dyn(light: 0x56624A, dark: 0x7A8A66)
    static let sageHi     = dyn(light: 0x9CAB87, dark: 0xB4C19F)

    static let rose       = dyn(light: 0xB05246, dark: 0xD67868)
    static let ochre      = dyn(light: 0xC7912F, dark: 0xDBA94C)

    static let tape       = dyn(light: 0xD8C58E, dark: 0x5A4830)

    // MARK: - Plant-pet rarity ink (Phase 5)
    // Each rarity tier carries a distinct ink treatment for `RarityBadge`
    // and the per-creature frame. Light values lean sepia/sage; dark
    // variants brighten so they read on the cocoa-leather background.

    /// Thin sepia ink line — `common` tier frame & badge text.
    static let rarityCommon    = dyn(light: 0x8A6A3F, dark: 0xC9985E)
    /// Doubled sepia line + small ◆ ornaments — `uncommon` tier.
    static let rarityUncommon  = dyn(light: 0x6E8050, dark: 0xA8BD8C)
    /// Sepia + rose hairline outer frame — `rare` tier.
    static let rarityRare      = dyn(light: 0xB05246, dark: 0xD67868)
    /// Sage-on-sepia double frame + ◆◇◆ cap — `legendary` tier.
    static let rarityLegendary = dyn(light: 0x56624A, dark: 0xB4C19F)
    /// Reserved for the mythical badge text (frame uses `goldInk`).
    static let rarityMythical  = dyn(light: 0x8A6F22, dark: 0xE6C766)

    /// Antique-gilt accent for mythical-tier frames + flourishes. The only
    /// new "non-sepia" accent in the Herbarium palette. Light=warm gold,
    /// dark=warmer pale-gold so it still reads as gilt on cocoa leather.
    static let goldInk         = dyn(light: 0xB8870A, dark: 0xE6C766)

    // MARK: - Plant-pet mood tint (Phase 5)
    // Tokens map 1:1 with `PetMoodLabel` cases. Used by PetCard's mood
    // ink-drop, the Menagerie row tint, and the PetDetailView mood strip.

    /// `thriving` — bright sage. Matches the existing `sage` family.
    static let moodThriving         = dyn(light: 0x6E8050, dark: 0xA8BD8C)
    /// `content` — default ink. Maps to the standard sepia.
    static let moodContent          = dyn(light: 0x6E4A22, dark: 0xC9985E)
    /// `quiet` — soft ink. Pulls from `inkSoft` lineage.
    static let moodQuiet            = dyn(light: 0x6F6051, dark: 0xA89A86)
    /// `wilted` — rose. Matches existing `rose` token.
    static let moodWilted           = dyn(light: 0xB05246, dark: 0xD67868)
    /// `departingImminent` — deep rose. Darker than `moodWilted`.
    static let moodDepartingImminent = dyn(light: 0x8E2A1F, dark: 0xC54E3D)

    // MARK: - Verdict palette

    static let verdictNow   = dyn(light: 0x6E8050, dark: 0x9CAB87)
    static let verdictSoon  = dyn(light: 0xB17F2A, dark: 0xDBA94C)
    static let verdictEarly = dyn(light: 0x7A8FA0, dark: 0x9CAFC1)
    static let verdictClose = dyn(light: 0xA6571D, dark: 0xD37C3A)
    static let verdictMiss  = dyn(light: 0x8E2A1F, dark: 0xD67868)

    // MARK: - Verdict helpers

    /// Foreground (text / dot) colour for a recommendation verdict string.
    /// Returns `nil` for unknown verdicts so callers can choose to hide the
    /// affordance entirely (matches `SeedRow`'s verdict-dot semantics).
    static func verdictForeground(for verdict: String) -> Color? {
        switch verdict {
        case "plant_now":  return verdictNow
        case "plant_soon": return verdictSoon
        case "too_early":  return verdictEarly
        case "late":       return verdictClose
        case "too_late":   return verdictMiss
        default:           return nil
        }
    }

    /// Same as `verdictForeground(for:)` but falls back to `.secondary` for
    /// unknown verdicts — used in badge-label contexts that always need a colour.
    static func verdictForegroundFallback(for verdict: String) -> Color {
        verdictForeground(for: verdict) ?? .secondary
    }

    /// Background (badge fill) colour for a recommendation verdict string.
    /// Derived from the foreground token at 15% opacity; unknown verdicts
    /// fall back to the system gray fill used by neutral badges.
    static func verdictBackground(for verdict: String) -> Color {
        verdictForeground(for: verdict)?.opacity(0.15) ?? Color(.systemGray5)
    }

    // MARK: - Helpers

    /// Build a dynamic SwiftUI Color from light + dark RGB hex literals.
    /// Optional alpha overrides apply to each variant independently.
    private static func dyn(
        light: UInt32, lightAlpha: Double = 1,
        dark:  UInt32, darkAlpha:  Double = 1
    ) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? uiColor(hex: dark,  alpha: darkAlpha)
                : uiColor(hex: light, alpha: lightAlpha)
        })
    }

    private static func uiColor(hex: UInt32, alpha: Double) -> UIColor {
        UIColor(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            alpha: alpha
        )
    }
}
