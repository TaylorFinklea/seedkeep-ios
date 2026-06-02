import SwiftUI

/// Uncommon-tier (autumn) — "Hammer-and-tongs cartographer of oak".
/// Bold black/white bird with red crown.
struct AcornWoodpeckerIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body
                Ellipse()
                    .fill(CompanionInk.charcoal)
                    .frame(width: 90 * s, height: 96 * s)
                    .offset(y: 8 * s)
                // White belly
                Path { p in
                    p.move(to: CGPoint(x: 70 * s, y: 100 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 80 * s, y: 140 * s),
                        control: CGPoint(x: 56 * s, y: 130 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 116 * s, y: 138 * s),
                        control: CGPoint(x: 100 * s, y: 152 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 122 * s, y: 100 * s),
                        control: CGPoint(x: 140 * s, y: 132 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.cream)
                // Head
                Circle()
                    .fill(CompanionInk.charcoal)
                    .frame(width: 50 * s, height: 48 * s)
                    .offset(x: -34 * s, y: -22 * s)
                // White cheek patch
                Ellipse()
                    .fill(CompanionInk.cream)
                    .frame(width: 18 * s, height: 12 * s)
                    .offset(x: -36 * s, y: -16 * s)
                // Red crown
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 60 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 80 * s, y: 60 * s),
                        control: CGPoint(x: 65 * s, y: 42 * s)
                    )
                    p.addLine(to: CGPoint(x: 70 * s, y: 70 * s))
                    p.addLine(to: CGPoint(x: 56 * s, y: 70 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.red)
                // Beak — sharp chisel
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 78 * s))
                    p.addLine(to: CGPoint(x: 28 * s, y: 82 * s))
                    p.addLine(to: CGPoint(x: 50 * s, y: 86 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.outline)
                // Eye
                Circle()
                    .fill(CompanionInk.cream)
                    .frame(width: 6 * s, height: 6 * s)
                    .offset(x: -42 * s, y: -22 * s)
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 3 * s, height: 3 * s)
                    .offset(x: -42 * s, y: -22 * s)
                // Legs against bark
                Path { p in
                    p.move(to: CGPoint(x: 90 * s, y: 144 * s))
                    p.addLine(to: CGPoint(x: 88 * s, y: 162 * s))
                    p.move(to: CGPoint(x: 110 * s, y: 144 * s))
                    p.addLine(to: CGPoint(x: 112 * s, y: 162 * s))
                }
                .stroke(CompanionInk.outline, lineWidth: 1.2 * s)
            }
        }
    }
}
