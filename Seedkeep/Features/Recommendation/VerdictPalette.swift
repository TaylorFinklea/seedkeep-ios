import SwiftUI

/// Single source of truth for recommendation-verdict colours.
///
/// Used by both `SeedRow` (verdict dot) and `RecommendationPanel`
/// (`VerdictInfo`) so the two surfaces always agree on hue values.
enum VerdictPalette {

    // MARK: - Foreground (text / dot) colours

    static func foregroundColor(for verdict: String) -> Color? {
        switch verdict {
        case "plant_now":  return Color(red: 0.10, green: 0.55, blue: 0.20)  // dark green
        case "plant_soon": return Color(red: 0.70, green: 0.50, blue: 0.00)  // amber
        case "too_early":  return Color(red: 0.40, green: 0.45, blue: 0.50)  // slate
        case "late":       return Color(red: 0.75, green: 0.35, blue: 0.00)  // orange
        case "too_late":   return Color(red: 0.75, green: 0.10, blue: 0.10)  // red
        default:           return nil
        }
    }

    /// Same as `foregroundColor(for:)` but falls back to `.secondary` for
    /// unknown verdicts — used in badge-label contexts that always need a colour.
    static func foregroundColorFallback(for verdict: String) -> Color {
        foregroundColor(for: verdict) ?? .secondary
    }

    // MARK: - Background (badge fill) colours

    static func backgroundColor(for verdict: String) -> Color {
        switch verdict {
        case "plant_now":  return Color(red: 0.85, green: 0.96, blue: 0.87)
        case "plant_soon": return Color(red: 1.00, green: 0.95, blue: 0.75)
        case "too_early":  return Color(red: 0.88, green: 0.90, blue: 0.92)
        case "late":       return Color(red: 1.00, green: 0.92, blue: 0.82)
        case "too_late":   return Color(red: 0.98, green: 0.88, blue: 0.88)
        default:           return Color(.systemGray5)
        }
    }
}
