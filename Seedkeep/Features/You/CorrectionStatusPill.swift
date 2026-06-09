import SwiftUI

/// Phase 4D · status pill for a catalog correction row.
///
/// Dedicated palette — deliberately distinct from
/// `HerbColor.verdictNow/Later` (planting-recommendation lanes) so a user
/// scanning YouView doesn't confuse a correction's lifecycle stage with
/// a seed's planting verdict. Lives in the You feature folder because
/// only contribution surfaces consume it.
///
/// Spec: `.docs/ai/specs/2026-06-09-phase-4d-catalog-corrections-design.md`
/// §7 ("YouView contributions section" → "Status pills").
struct CorrectionStatusPill: View {
    /// Raw server status string. One of `open`, `reviewed`, `applied`,
    /// `dismissed`. Unknown values render as a neutral `inkSoft` pill so
    /// a future server-added status never crashes the row.
    let status: String

    var body: some View {
        let palette = CorrectionStatusColor.palette(for: status)
        HStack(spacing: 4) {
            Image(systemName: palette.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(palette.label)
                .font(HerbFont.body(size: 11))
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(palette.foreground.opacity(0.14))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(palette.label)")
    }
}

/// Dedicated palette for correction-lifecycle pills. Kept separate from
/// the recommendation `verdict*` tokens so the two systems never read as
/// "the same colour means the same thing."
enum CorrectionStatusColor {
    struct Palette {
        let foreground: Color
        let icon: String
        let label: String
    }

    /// Resolve the palette for a server status string. Unknown statuses
    /// fall back to the `open`/clock treatment so callers don't crash on
    /// a forward-compatible server addition.
    static func palette(for status: String) -> Palette {
        switch status {
        case "open":
            return Palette(foreground: HerbColor.inkSoft, icon: "clock", label: "open")
        case "reviewed":
            return Palette(foreground: HerbColor.sepia, icon: "magnifyingglass", label: "reviewed")
        case "applied":
            return Palette(foreground: HerbColor.sage, icon: "checkmark.seal", label: "applied")
        case "dismissed":
            return Palette(foreground: HerbColor.rose, icon: "xmark.seal", label: "dismissed")
        default:
            return Palette(foreground: HerbColor.inkSoft, icon: "clock", label: status)
        }
    }
}
