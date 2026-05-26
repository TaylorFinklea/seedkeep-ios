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

    // MARK: - Verdict palette

    static let verdictNow   = dyn(light: 0x6E8050, dark: 0x9CAB87)
    static let verdictSoon  = dyn(light: 0xB17F2A, dark: 0xDBA94C)
    static let verdictEarly = dyn(light: 0x7A8FA0, dark: 0x9CAFC1)
    static let verdictClose = dyn(light: 0xA6571D, dark: 0xD37C3A)
    static let verdictMiss  = dyn(light: 0x8E2A1F, dark: 0xD67868)

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
