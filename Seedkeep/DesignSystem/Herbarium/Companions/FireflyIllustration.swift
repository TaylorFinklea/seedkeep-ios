import SwiftUI

/// Uncommon-tier (summer) — "Punctuation mark in a humid sentence".
/// Beetle with luminous yellow rear glow.
struct FireflyIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Glow halo around rear
                Circle()
                    .fill(RadialGradient(
                        colors: [CompanionInk.amber.opacity(0.7), CompanionInk.amber.opacity(0)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 50
                    ))
                    .frame(width: 100 * s, height: 100 * s)
                    .offset(y: 50 * s)
                // Wings — half-folded
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 70 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 56 * s, y: 130 * s),
                        control: CGPoint(x: 56 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 140 * s),
                        control: CGPoint(x: 80 * s, y: 150 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.outlineSoft, CompanionInk.charcoal],
                    startPoint: .top, endPoint: .bottom
                ))
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 70 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 144 * s, y: 130 * s),
                        control: CGPoint(x: 144 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 140 * s),
                        control: CGPoint(x: 120 * s, y: 150 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.outlineSoft, CompanionInk.charcoal],
                    startPoint: .top, endPoint: .bottom
                ))
                // Midline
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 70 * s))
                    p.addLine(to: CGPoint(x: 100 * s, y: 140 * s))
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
                // Glowing abdomen tip
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.cream, CompanionInk.amber],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 38 * s, height: 26 * s)
                    .offset(y: 56 * s)
                // Head
                Circle()
                    .fill(CompanionInk.charcoal)
                    .frame(width: 32 * s, height: 28 * s)
                    .offset(y: -42 * s)
                // Antennae
                Path { p in
                    p.move(to: CGPoint(x: 92 * s, y: 50 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 78 * s, y: 28 * s),
                        control: CGPoint(x: 82 * s, y: 36 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
                Path { p in
                    p.move(to: CGPoint(x: 108 * s, y: 50 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 122 * s, y: 28 * s),
                        control: CGPoint(x: 118 * s, y: 36 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
            }
        }
    }
}
