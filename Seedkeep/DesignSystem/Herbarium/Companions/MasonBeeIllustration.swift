import SwiftUI

/// Uncommon-tier (spring) — "Early-thaw envoy, first wings of warmth".
/// Smaller darker bee with metallic blue-grey thorax.
struct MasonBeeIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Wings
                Ellipse()
                    .fill(CompanionInk.pale.opacity(0.55))
                    .frame(width: 56 * s, height: 32 * s)
                    .rotationEffect(.degrees(-22))
                    .offset(x: -12 * s, y: -8 * s)
                Ellipse()
                    .fill(CompanionInk.pale.opacity(0.55))
                    .frame(width: 56 * s, height: 32 * s)
                    .rotationEffect(.degrees(22))
                    .offset(x: 12 * s, y: -8 * s)
                // Abdomen — metallic dark
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.slateBlue, CompanionInk.charcoal],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 80 * s, height: 64 * s)
                    .offset(y: 30 * s)
                // Subtle abdomen stripes
                ForEach(0..<3) { i in
                    Path { p in
                        let cy = CGFloat(110 + i * 12) * s
                        p.move(to: CGPoint(x: 68 * s, y: cy))
                        p.addQuadCurve(
                            to: CGPoint(x: 132 * s, y: cy),
                            control: CGPoint(x: 100 * s, y: cy + 2 * s)
                        )
                    }
                    .stroke(CompanionInk.outline.opacity(0.6), lineWidth: 2 * s)
                }
                // Thorax fuzz
                Ellipse()
                    .fill(CompanionInk.sepia)
                    .frame(width: 50 * s, height: 38 * s)
                    .offset(y: -14 * s)
                // Head
                Circle()
                    .fill(CompanionInk.charcoal)
                    .frame(width: 32 * s, height: 30 * s)
                    .offset(y: -48 * s)
                // Eyes
                Ellipse()
                    .fill(CompanionInk.outline)
                    .frame(width: 9 * s, height: 12 * s)
                    .offset(x: -8 * s, y: -50 * s)
                Ellipse()
                    .fill(CompanionInk.outline)
                    .frame(width: 9 * s, height: 12 * s)
                    .offset(x: 8 * s, y: -50 * s)
                // Antennae
                Path { p in
                    p.move(to: CGPoint(x: 92 * s, y: 38 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 78 * s, y: 16 * s),
                        control: CGPoint(x: 82 * s, y: 24 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
                Path { p in
                    p.move(to: CGPoint(x: 108 * s, y: 38 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 122 * s, y: 16 * s),
                        control: CGPoint(x: 118 * s, y: 24 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
            }
        }
    }
}
