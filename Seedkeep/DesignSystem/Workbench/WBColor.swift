// Workbench design tokens (redesign R1). PARENT-OWNED contract: workers use these and do
// not edit this file; ask the parent for additions.
//
// Values are the Workbench web prototype's (`seedkeep-web-design/src/app.css`), light / dark.
// The app still forces light mode until R2 audits dark mode, but every token already
// resolves per appearance so new surfaces never hard-code a colour.
import SwiftUI

enum WBColor {
    private static func token(_ light: UInt32, _ dark: UInt32) -> Color {
        let colour = PlatformColor.dynamic(light: platformColor(light), dark: platformColor(dark))
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
    static let bg = token(0xF5F5F1, 0x0F1311)
    static let panel = token(0xFFFFFF, 0x161B18)
    static let panel2 = token(0xFAFAF7, 0x1B211E)
    // Text
    static let ink = token(0x17201B, 0xE6EBE7)
    static let muted = token(0x56605A, 0xA2ACA5)
    static let faint = token(0x7C857F, 0x828C86)
    // Rules
    static let line = token(0xE2E3DD, 0x262D29)
    static let line2 = token(0xCDD0C8, 0x363E39)
    // Accent and selection
    static let accent = token(0x07583B, 0x4CC688)
    static let accentInk = token(0xFFFFFF, 0x07150E)
    static let accentSoft = token(0xE3EFE8, 0x16301F)
    static let selection = token(0xEEF5F0, 0x1A2A21)
    static let paletteSelection = token(0xEEF5F0, 0x1F3328)
    // Warnings
    static let warn = token(0xA8461A, 0xF0936A)
    static let warnSoft = token(0xFBEEE6, 0x2E1D15)

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

    static let verdictPlantNow = token(0x1D7A45, 0x5BD08F)
    static let verdictPlantSoon = token(0xA66A0E, 0xE7B04D)
    static let verdictLate = token(0xB5501A, 0xF0936A)
    static let verdictTooEarly = token(0x3F6688, 0x86A9CC)
    static let verdictTooLate = token(0x858C87, 0x8E9892)

    // Planting-event kinds (Garden, R3)
    static let kindSowing = token(0xE3EFE8, 0x1C3527)
    static let kindTransplant = token(0xE3EBF4, 0x1C2A3A)
    static let kindHarvest = token(0xF6ECD6, 0x3A2F1A)
    static let kindNote = token(0xECECE8, 0x262B28)
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
    /// Minimum touch target on iPhone and iPad.
    static let touchTarget: CGFloat = 44
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
