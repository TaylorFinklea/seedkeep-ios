import Foundation
import SwiftUI
import Testing
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Seedkeep

/// WCAG 2.x contrast over sRGB hex values: relative luminance, then (L1 + 0.05) / (L2 + 0.05).
enum WBContrast {
    static func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func luminance(_ hex: UInt32) -> Double {
        let r = channel(Double((hex >> 16) & 0xFF) / 255)
        let g = channel(Double((hex >> 8) & 0xFF) / 255)
        let b = channel(Double(hex & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `foreground` at `alpha` over `background`, per 8-bit channel. This is how a segment at
    /// `verdictPlantNow.opacity(alpha)` over `panel` is drawn.
    static func blend(_ foreground: UInt32, alpha: Double, over background: UInt32) -> UInt32 {
        var result: UInt32 = 0
        for shift in [16, 8, 0] {
            let f = Double((foreground >> shift) & 0xFF)
            let b = Double((background >> shift) & 0xFF)
            result |= UInt32((f * alpha + b * (1 - alpha)).rounded()) << shift
        }
        return result
    }
}

/// Which half of a `WBPalette.Pair` a check reads.
enum WBContrastAppearance: CaseIterable, Sendable, CustomTestStringConvertible {
    case light
    case dark

    func hex(_ pair: WBPalette.Pair) -> UInt32 {
        switch self {
        case .light: return pair.light
        case .dark: return pair.dark
        }
    }

    var testDescription: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        }
    }
}

/// One contrast requirement from the R2c contract: text needs 4.5:1, a graphic needs 3:1.
struct WBContrastRequirement: Sendable, CustomTestStringConvertible {
    let name: String
    let foreground: WBPalette.Pair
    let background: WBPalette.Pair
    let minimum: Double

    var testDescription: String { name }

    /// Text (WCAG 1.4.3).
    static func text(_ name: String, _ foreground: WBPalette.Pair, on background: WBPalette.Pair) -> Self {
        Self(name: name, foreground: foreground, background: background, minimum: 4.5)
    }

    /// Non-text graphics (WCAG 1.4.11).
    static func graphic(_ name: String, _ foreground: WBPalette.Pair, on background: WBPalette.Pair) -> Self {
        Self(name: name, foreground: foreground, background: background, minimum: 3)
    }

    static let textPairs: [WBContrastRequirement] = [
        .text("ink on bg", WBPalette.ink, on: WBPalette.bg),
        .text("ink on panel", WBPalette.ink, on: WBPalette.panel),
        .text("ink on panel2", WBPalette.ink, on: WBPalette.panel2),
        .text("ink on accentSoft", WBPalette.ink, on: WBPalette.accentSoft),
        .text("ink on warnSoft", WBPalette.ink, on: WBPalette.warnSoft),
        .text("ink on selection", WBPalette.ink, on: WBPalette.selection),
        .text("ink on paletteSelection", WBPalette.ink, on: WBPalette.paletteSelection),
        .text("muted on bg", WBPalette.muted, on: WBPalette.bg),
        .text("muted on panel", WBPalette.muted, on: WBPalette.panel),
        .text("muted on panel2", WBPalette.muted, on: WBPalette.panel2),
        .text("muted on accentSoft", WBPalette.muted, on: WBPalette.accentSoft),
        .text("muted on warnSoft", WBPalette.muted, on: WBPalette.warnSoft),
        .text("muted on selection", WBPalette.muted, on: WBPalette.selection),
        .text("muted on paletteSelection", WBPalette.muted, on: WBPalette.paletteSelection),
        .text("accent on bg", WBPalette.accent, on: WBPalette.bg),
        .text("accent on panel", WBPalette.accent, on: WBPalette.panel),
        .text("accent on panel2", WBPalette.accent, on: WBPalette.panel2),
        .text("accent on accentSoft", WBPalette.accent, on: WBPalette.accentSoft),
        .text("accentInk on accent", WBPalette.accentInk, on: WBPalette.accent),
        .text("warnInk on warn", WBPalette.warnInk, on: WBPalette.warn),
    ]

    /// Graphics. `faint` on `panel` also covers the swatch ring.
    static let graphicPairs: [WBContrastRequirement] = [
        .graphic("warn on panel", WBPalette.warn, on: WBPalette.panel),
        .graphic("verdictPlantNow on panel", WBPalette.verdictPlantNow, on: WBPalette.panel),
        .graphic("verdictPlantSoon on panel", WBPalette.verdictPlantSoon, on: WBPalette.panel),
        .graphic("verdictLate on panel", WBPalette.verdictLate, on: WBPalette.panel),
        .graphic("verdictTooEarly on panel", WBPalette.verdictTooEarly, on: WBPalette.panel),
        .graphic("verdictTooLate on panel", WBPalette.verdictTooLate, on: WBPalette.panel),
        .graphic("faint on panel", WBPalette.faint, on: WBPalette.panel),
    ]
}

struct WorkbenchContrastTests {
    @Test(arguments: WBContrastRequirement.textPairs, WBContrastAppearance.allCases)
    func textPairsReachAA(_ requirement: WBContrastRequirement, appearance: WBContrastAppearance) {
        let ratio = WBContrast.ratio(
            appearance.hex(requirement.foreground),
            appearance.hex(requirement.background)
        )
        #expect(ratio >= requirement.minimum, "\(requirement.name) in \(appearance): \(ratio)")
    }

    @Test(arguments: WBContrastRequirement.graphicPairs, WBContrastAppearance.allCases)
    func graphicPairsReachThreeToOne(_ requirement: WBContrastRequirement, appearance: WBContrastAppearance) {
        let ratio = WBContrast.ratio(
            appearance.hex(requirement.foreground),
            appearance.hex(requirement.background)
        )
        #expect(ratio >= requirement.minimum, "\(requirement.name) in \(appearance): \(ratio)")
    }
}

/// Known values for the helper itself, so the threshold tests below can't pass on a broken formula.
struct WorkbenchContrastMathTests {
    @Test func blackOnWhiteIsTwentyOneToOne() {
        #expect(abs(WBContrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.0001)
    }

    @Test func middleGreyOnWhiteIsAboutFourPointFiveFour() {
        // #767676 on white is the usual reference point for 4.5:1 text.
        #expect(abs(WBContrast.ratio(0x767676, 0xFFFFFF) - 4.54) < 0.01)
    }

    @Test func identicalColoursAreOneToOne() {
        #expect(WBContrast.ratio(0x17201B, 0x17201B) == 1)
    }

    @Test func blendEndpointsAreTheForegroundAndTheBackground() {
        #expect(WBContrast.blend(0x1D7A45, alpha: 1, over: 0xFFFFFF) == 0x1D7A45)
        #expect(WBContrast.blend(0x1D7A45, alpha: 0, over: 0xFFFFFF) == 0xFFFFFF)
    }
}

/// The chart's "Your date" marker is an `ink` bar with a 1pt `panel` halo. It must stand out
/// from every segment the ramp can draw: `line`, and `verdictPlantNow` at opacity 0.25 to 1.
struct WorkbenchChartMarkerContrastTests {
    @Test(arguments: WBContrastAppearance.allCases)
    func markerReachesThreeToOneOnEverySegment(_ appearance: WBContrastAppearance) {
        let panel = appearance.hex(WBPalette.panel)
        let ink = appearance.hex(WBPalette.ink)
        let planted = appearance.hex(WBPalette.verdictPlantNow)

        var segments: [(name: String, colour: UInt32)] = [("line", appearance.hex(WBPalette.line))]
        for percent in 25...100 {
            let opacity = Double(percent) / 100
            let colour = WBContrast.blend(planted, alpha: opacity, over: panel)
            segments.append(("verdictPlantNow at \(opacity)", colour))
        }

        for segment in segments {
            let best = max(
                WBContrast.ratio(ink, segment.colour),
                WBContrast.ratio(panel, segment.colour)
            )
            #expect(best >= 3, "\(segment.name) in \(appearance): \(best)")
        }
    }
}

/// A `WBColor` token and the palette entry it must build from.
struct WBColorToken: Sendable, CustomTestStringConvertible {
    let name: String
    let color: Color
    let pair: WBPalette.Pair

    var testDescription: String { name }

    init(_ name: String, _ color: Color, _ pair: WBPalette.Pair) {
        self.name = name
        self.color = color
        self.pair = pair
    }

    static let all: [WBColorToken] = [
        WBColorToken("bg", WBColor.bg, WBPalette.bg),
        WBColorToken("panel", WBColor.panel, WBPalette.panel),
        WBColorToken("panel2", WBColor.panel2, WBPalette.panel2),
        WBColorToken("ink", WBColor.ink, WBPalette.ink),
        WBColorToken("muted", WBColor.muted, WBPalette.muted),
        WBColorToken("faint", WBColor.faint, WBPalette.faint),
        WBColorToken("line", WBColor.line, WBPalette.line),
        WBColorToken("line2", WBColor.line2, WBPalette.line2),
        WBColorToken("accent", WBColor.accent, WBPalette.accent),
        WBColorToken("accentInk", WBColor.accentInk, WBPalette.accentInk),
        WBColorToken("accentSoft", WBColor.accentSoft, WBPalette.accentSoft),
        WBColorToken("selection", WBColor.selection, WBPalette.selection),
        WBColorToken("paletteSelection", WBColor.paletteSelection, WBPalette.paletteSelection),
        WBColorToken("warn", WBColor.warn, WBPalette.warn),
        WBColorToken("warnSoft", WBColor.warnSoft, WBPalette.warnSoft),
        WBColorToken("warnInk", WBColor.warnInk, WBPalette.warnInk),
        WBColorToken("verdictPlantNow", WBColor.verdictPlantNow, WBPalette.verdictPlantNow),
        WBColorToken("verdictPlantSoon", WBColor.verdictPlantSoon, WBPalette.verdictPlantSoon),
        WBColorToken("verdictLate", WBColor.verdictLate, WBPalette.verdictLate),
        WBColorToken("verdictTooEarly", WBColor.verdictTooEarly, WBPalette.verdictTooEarly),
        WBColorToken("verdictTooLate", WBColor.verdictTooLate, WBPalette.verdictTooLate),
        WBColorToken("kindSowing", WBColor.kindSowing, WBPalette.kindSowing),
        WBColorToken("kindTransplant", WBColor.kindTransplant, WBPalette.kindTransplant),
        WBColorToken("kindHarvest", WBColor.kindHarvest, WBPalette.kindHarvest),
        WBColorToken("kindNote", WBColor.kindNote, WBPalette.kindNote),
    ]
}

/// Resolves a `Color` the way the system does under one appearance, and returns its 8-bit sRGB hex.
@MainActor
enum WBResolvedColor {
    static func hex(_ color: Color, appearance: WBContrastAppearance) -> UInt32 {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #if os(iOS)
        let traits = UITraitCollection(userInterfaceStyle: appearance == .dark ? .dark : .light)
        UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        let drawingAppearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        drawingAppearance?.performAsCurrentDrawingAppearance {
            NSColor(color).usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        #endif
        return pack(red) << 16 | pack(green) << 8 | pack(blue)
    }

    private static func pack(_ component: CGFloat) -> UInt32 {
        UInt32(min(max((component * 255).rounded(), 0), 255))
    }
}

@MainActor
struct WorkbenchColorResolutionTests {
    @Test(arguments: WBColorToken.all, WBContrastAppearance.allCases)
    func tokenResolvesToItsPaletteValue(_ token: WBColorToken, appearance: WBContrastAppearance) {
        let resolved = WBResolvedColor.hex(token.color, appearance: appearance)
        #expect(resolved == appearance.hex(token.pair), "\(token.name) in \(appearance)")
    }
}
