import SwiftUI
import SeedkeepKit

/// Compact rarity-tier label rendered as small-caps text inside an ink
/// frame. Mirrors `Rubric` typography (IM Fell English SC + `.tracking`)
/// and shifts color + frame ornament per tier:
///
/// - common      — thin single sepia hairline.
/// - uncommon    — doubled sepia hairline.
/// - rare        — single rose hairline.
/// - legendary   — double sage-on-sepia line with `◆◇◆` end-caps.
/// - mythical    — single gold-ink hairline (only place `goldInk` reads).
///
/// No Roman numeral, no icon — the tier name is the badge per spec.
struct RarityBadge: View {
    let rarity: PetRarity
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 6) {
            if showsOrnamentCaps {
                Text("◆◇◆")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(strokeColor)
            }
            Text(rarity.rawValue)
                .font(HerbFont.smallCaps(size: size))
                .tracking(1.5)
                .foregroundStyle(textColor)
                .textCase(.uppercase)
            if showsOrnamentCaps {
                Text("◆◇◆")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(strokeColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            ZStack {
                // Outer hairline frame — sepia/rose/sage/gold per tier.
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(strokeColor, lineWidth: 0.75)
                // Doubled inner line for uncommon + legendary.
                if showsInnerFrame {
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(strokeColor.opacity(0.6), lineWidth: 0.4)
                        .padding(2)
                }
            }
        )
    }

    private var textColor: Color {
        switch rarity {
        case .common:     return HerbColor.rarityCommon
        case .uncommon:   return HerbColor.rarityUncommon
        case .rare:       return HerbColor.rarityRare
        case .legendary:  return HerbColor.rarityLegendary
        case .mythical:   return HerbColor.rarityMythical
        }
    }

    private var strokeColor: Color {
        switch rarity {
        case .common:     return HerbColor.rarityCommon
        case .uncommon:   return HerbColor.rarityUncommon
        case .rare:       return HerbColor.rarityRare
        case .legendary:  return HerbColor.sepia
        case .mythical:   return HerbColor.goldInk
        }
    }

    private var showsInnerFrame: Bool {
        rarity == .uncommon || rarity == .legendary
    }

    private var showsOrnamentCaps: Bool {
        rarity == .legendary
    }
}

#Preview {
    VStack(spacing: 14) {
        RarityBadge(rarity: .common)
        RarityBadge(rarity: .uncommon)
        RarityBadge(rarity: .rare)
        RarityBadge(rarity: .legendary)
        RarityBadge(rarity: .mythical)
    }
    .padding(32)
    .background(VellumBackground())
}
