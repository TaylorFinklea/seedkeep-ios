import SwiftUI

/// Rare-tier — "Mimic of every other companion". Sleek long-tailed
/// grey bird with bold white wing flash.
struct MockingbirdIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.dusk, CompanionInk.outlineSoft],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 90 * s, height: 80 * s)
                    .offset(y: 8 * s)
                // Pale chest
                Ellipse()
                    .fill(CompanionInk.pale)
                    .frame(width: 50 * s, height: 38 * s)
                    .offset(x: -6 * s, y: 26 * s)
                // Wing — bold white slash
                Path { p in
                    p.move(to: CGPoint(x: 110 * s, y: 70 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 160 * s, y: 110 * s),
                        control: CGPoint(x: 150 * s, y: 70 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 90 * s),
                        control: CGPoint(x: 130 * s, y: 130 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.outlineSoft)
                Path { p in
                    p.move(to: CGPoint(x: 124 * s, y: 86 * s))
                    p.addLine(to: CGPoint(x: 144 * s, y: 92 * s))
                }
                .stroke(CompanionInk.cream, lineWidth: 4 * s)
                // Head
                Circle()
                    .fill(CompanionInk.dusk)
                    .frame(width: 46 * s, height: 44 * s)
                    .offset(x: -34 * s, y: -22 * s)
                // Beak — singing open
                Path { p in
                    p.move(to: CGPoint(x: 48 * s, y: 76 * s))
                    p.addLine(to: CGPoint(x: 26 * s, y: 78 * s))
                    p.addLine(to: CGPoint(x: 48 * s, y: 86 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.outline)
                Path { p in
                    p.move(to: CGPoint(x: 26 * s, y: 80 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 14 * s, y: 74 * s),
                        control: CGPoint(x: 22 * s, y: 70 * s)
                    )
                }
                .stroke(CompanionInk.outline.opacity(0.5), lineWidth: 0.6 * s)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 5 * s, height: 5 * s)
                    .offset(x: -42 * s, y: -22 * s)
                // Long tail — wedge
                Path { p in
                    p.move(to: CGPoint(x: 140 * s, y: 96 * s))
                    p.addLine(to: CGPoint(x: 188 * s, y: 120 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 116 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.dusk)
                Path { p in
                    p.move(to: CGPoint(x: 160 * s, y: 108 * s))
                    p.addLine(to: CGPoint(x: 184 * s, y: 116 * s))
                }
                .stroke(CompanionInk.cream, lineWidth: 2 * s)
                // Legs
                Path { p in
                    p.move(to: CGPoint(x: 88 * s, y: 138 * s))
                    p.addLine(to: CGPoint(x: 90 * s, y: 158 * s))
                    p.move(to: CGPoint(x: 102 * s, y: 138 * s))
                    p.addLine(to: CGPoint(x: 104 * s, y: 158 * s))
                }
                .stroke(CompanionInk.outlineSoft, lineWidth: 1 * s)
            }
        }
    }
}
