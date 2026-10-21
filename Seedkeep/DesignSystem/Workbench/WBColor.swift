// Workbench design tokens (redesign R1). PARENT-OWNED contract: workers use these and do not
// edit this file; ask the parent for additions.
//
// Values are the Workbench web prototype's (`seedkeep-web-design/src/app.css`), light / dark.
// They live in `WBPalette`, one table that the contrast tests read. Every token resolves per
// appearance, so new surfaces never hard-code a colour.
import SwiftUI

/// Every Workbench token's sRGB hex in light and dark. `WBColor` builds its colours from this table.
enum WBPalette {
    /// One token's values, `0xRRGGBB`, for each appearance.
    struct Pair: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32
    }

    // Surfaces
    static let bg = Pair(light: 0xF5F5F1, dark: 0x0F1311)
    static let panel = Pair(light: 0xFFFFFF, dark: 0x161B18)
    static let panel2 = Pair(light: 0xFAFAF7, dark: 0x1B211E)
    // Text
    static let ink = Pair(light: 0x17201B, dark: 0xE6EBE7)
    static let muted = Pair(light: 0x56605A, dark: 0xA2ACA5)
    static let faint = Pair(light: 0x7C857F, dark: 0x828C86)
    // Rules
    static let line = Pair(light: 0xE2E3DD, dark: 0x262D29)
    static let line2 = Pair(light: 0xCDD0C8, dark: 0x363E39)
    // Accent and selection
    static let accent = Pair(light: 0x07583B, dark: 0x4CC688)
    static let accentInk = Pair(light: 0xFFFFFF, dark: 0x07150E)
    static let accentSoft = Pair(light: 0xE3EFE8, dark: 0x16301F)
    static let selection = Pair(light: 0xEEF5F0, dark: 0x1A2A21)
    static let paletteSelection = Pair(light: 0xEEF5F0, dark: 0x1F3328)
    // Warnings
    static let warn = Pair(light: 0xA8461A, dark: 0xF0936A)
    static let warnSoft = Pair(light: 0xFBEEE6, dark: 0x2E1D15)
    /// Icons on `warn`.
    static let warnInk = Pair(light: 0xFFFFFF, dark: 0x1A0F0A)
    // Planting-window verdicts
    static let verdictPlantNow = Pair(light: 0x1D7A45, dark: 0x5BD08F)
    static let verdictPlantSoon = Pair(light: 0xA66A0E, dark: 0xE7B04D)
    static let verdictLate = Pair(light: 0xB5501A, dark: 0xF0936A)
    static let verdictTooEarly = Pair(light: 0x3F6688, dark: 0x86A9CC)
    static let verdictTooLate = Pair(light: 0x858C87, dark: 0x8E9892)
    // Planting-event kinds (Garden, R3)
    static let kindSowing = Pair(light: 0xE3EFE8, dark: 0x1C3527)
    static let kindTransplant = Pair(light: 0xE3EBF4, dark: 0x1C2A3A)
    static let kindHarvest = Pair(light: 0xF6ECD6, dark: 0x3A2F1A)
    static let kindNote = Pair(light: 0xECECE8, dark: 0x262B28)
}

enum WBColor {
    private static func token(_ pair: WBPalette.Pair) -> Color {
        let colour = PlatformColor.dynamic(light: platformColor(pair.light), dark: platformColor(pair.dark))
        #if os(iOS)
        return Color(uiColor: colour)
        #else
        return Color(nsColor: colour)
        #endif
    }

    private static func platformColor(_ hex: UInt32) -> PlatformColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        #if os(iOS)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
        #else
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        #endif
    }

    // Surfaces
    static let bg = token(WBPalette.bg)
    static let panel = token(WBPalette.panel)
    static let panel2 = token(WBPalette.panel2)
    // Text
    static let ink = token(WBPalette.ink)
    static let muted = token(WBPalette.muted)
    static let faint = token(WBPalette.faint)
    // Rules
    static let line = token(WBPalette.line)
    static let line2 = token(WBPalette.line2)
    // Accent and selection
    static let accent = token(WBPalette.accent)
    static let accentInk = token(WBPalette.accentInk)
    static let accentSoft = token(WBPalette.accentSoft)
    static let selection = token(WBPalette.selection)
    static let paletteSelection = token(WBPalette.paletteSelection)
    // Warnings
    static let warn = token(WBPalette.warn)
    static let warnSoft = token(WBPalette.warnSoft)
    static let warnInk = token(WBPalette.warnInk)

    /// Planting-window verdict colours. Keys are `LocalRecommendation.verdict` raw values.
    static func verdict(_ raw: String) -> Color {
        switch raw {
        case "plant_now": return verdictPlantNow
        case "plant_soon": return verdictPlantSoon
        case "late": return verdictLate
        case "too_early": return verdictTooEarly
        case "too_late": return verdictTooLate
        default: return faint
        }
    }

    static let verdictPlantNow = token(WBPalette.verdictPlantNow)
    static let verdictPlantSoon = token(WBPalette.verdictPlantSoon)
    static let verdictLate = token(WBPalette.verdictLate)
    static let verdictTooEarly = token(WBPalette.verdictTooEarly)
    static let verdictTooLate = token(WBPalette.verdictTooLate)

    // Planting-event kinds (Garden, R3)
    static let kindSowing = token(WBPalette.kindSowing)
    static let kindTransplant = token(WBPalette.kindTransplant)
    static let kindHarvest = token(WBPalette.kindHarvest)
    static let kindNote = token(WBPalette.kindNote)
}

/// Workbench geometry and type. System fonts (SF Pro, SF Mono) per the owner's decision;
/// sizes come from text styles, so Dynamic Type applies.
enum WBMetrics {
    static let radiusSmall: CGFloat = 6
    static let radiusControl: CGFloat = 7
    static let radiusPanel: CGFloat = 10
    static let radiusSheet: CGFloat = 12
    static let gap: CGFloat = 8
    static let gapLarge: CGFloat = 12
    /// Horizontal page inset for screen titles and full-width content.
    static let screenGutter: CGFloat = 20
    /// Minimum touch target on iPhone and iPad.
    static let touchTarget: CGFloat = 44
    /// Minimum frame for a control's hit area: `touchTarget` on iOS, no minimum on Mac, where the
    /// pointer doesn't need a padded target.
    #if os(iOS)
    static let minTouchTarget: CGFloat = 44
    #else
    static let minTouchTarget: CGFloat = 0
    #endif
}

extension Font {
    /// Workbench body text (SF Pro).
    static let wbBody = Font.system(.body)
    /// Secondary labels.
    static let wbCaption = Font.system(.caption)
    /// Numbers, dates, counts and keyboard hints (SF Mono), as the Workbench design uses mono.
    static let wbMono = Font.system(.body, design: .monospaced)
    static let wbMonoCaption = Font.system(.caption, design: .monospaced)
}
