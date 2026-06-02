import SwiftUI

/// Uncommon-tier (winter) — "Bright fleck against the blank field".
/// Bright white bird with charcoal back / wing barring.
struct SnowBuntingIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body
                Ellipse()
                    .fill(CompanionInk.cream)
                    .frame(width: 100 * s, height: 90 * s)
                    .offset(y: 4 * s)
                // Black back/wing patch
                Path { p in
                    p.move(to: CGPoint(x: 96 * s, y: 64 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 154 * s, y: 96 * s),
                        control: CGPoint(x: 148 * s, y: 64 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 138 * s, y: 124 * s),
                        control: CGPoint(x: 158 * s, y: 124 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 96 * s, y: 96 * s),
                        control: CGPoint(x: 110 * s, y: 134 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.charcoal)
                // Wing bar — white slash
                Path { p in
                    p.move(to: CGPoint(x: 110 * s, y: 90 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 96 * s))
                }
                .stroke(CompanionInk.cream, lineWidth: 4 * s)
                // Head
                Circle()
                    .fill(CompanionInk.cream)
                    .frame(width: 50 * s, height: 48 * s)
                    .offset(x: -34 * s, y: -22 * s)
                // Crown shadow
                Path { p in
                    p.move(to: CGPoint(x: 44 * s, y: 56 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 84 * s, y: 56 * s),
                        control: CGPoint(x: 64 * s, y: 42 * s)
                    )
                    p.addLine(to: CGPoint(x: 80 * s, y: 70 * s))
                    p.addLine(to: CGPoint(x: 50 * s, y: 70 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.outlineSoft.opacity(0.6))
                // Beak
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 76 * s))
                    p.addLine(to: CGPoint(x: 34 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 50 * s, y: 84 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.amber)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 5 * s, height: 5 * s)
                    .offset(x: -40 * s, y: -22 * s)
                // Tail
                Path { p in
                    p.move(to: CGPoint(x: 150 * s, y: 100 * s))
                    p.addLine(to: CGPoint(x: 180 * s, y: 116 * s))
                    p.addLine(to: CGPoint(x: 152 * s, y: 120 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.charcoal)
                // Legs
                Path { p in
                    p.move(to: CGPoint(x: 88 * s, y: 140 * s))
                    p.addLine(to: CGPoint(x: 90 * s, y: 158 * s))
                    p.move(to: CGPoint(x: 102 * s, y: 140 * s))
                    p.addLine(to: CGPoint(x: 104 * s, y: 158 * s))
                }
                .stroke(CompanionInk.outlineSoft, lineWidth: 1 * s)
            }
        }
    }
}
