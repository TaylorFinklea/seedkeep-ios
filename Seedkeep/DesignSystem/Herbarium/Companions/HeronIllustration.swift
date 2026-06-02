import SwiftUI

/// Legendary-tier — "Grey philosopher on a single stilt". Long-necked
/// stilt-legged heron in profile.
struct HeronIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Single tall standing leg
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 130 * s))
                    p.addLine(to: CGPoint(x: 98 * s, y: 192 * s))
                }
                .stroke(CompanionInk.amber, style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
                // Second leg, lifted
                Path { p in
                    p.move(to: CGPoint(x: 108 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 168 * s),
                        control: CGPoint(x: 122 * s, y: 150 * s)
                    )
                }
                .stroke(CompanionInk.amber, style: StrokeStyle(lineWidth: 2.5 * s, lineCap: .round))
                // Body — slim teardrop
                Path { p in
                    p.move(to: CGPoint(x: 60 * s, y: 100 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 80 * s, y: 138 * s),
                        control: CGPoint(x: 50 * s, y: 130 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 150 * s, y: 116 * s),
                        control: CGPoint(x: 120 * s, y: 142 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 100 * s),
                        control: CGPoint(x: 130 * s, y: 80 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.slateBlue, CompanionInk.dusk],
                    startPoint: .top, endPoint: .bottom
                ))
                // Wing dark
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 96 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 156 * s, y: 110 * s),
                        control: CGPoint(x: 134 * s, y: 86 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 120 * s, y: 122 * s),
                        control: CGPoint(x: 150 * s, y: 130 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.dusk)
                // Long S-curved neck
                Path { p in
                    p.move(to: CGPoint(x: 76 * s, y: 100 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 50 * s, y: 60 * s),
                        control: CGPoint(x: 56 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 80 * s, y: 30 * s),
                        control: CGPoint(x: 56 * s, y: 38 * s)
                    )
                }
                .stroke(CompanionInk.slateBlue, style: StrokeStyle(lineWidth: 9 * s, lineCap: .round))
                // Head
                Ellipse()
                    .fill(CompanionInk.slateBlue)
                    .frame(width: 28 * s, height: 18 * s)
                    .offset(x: -10 * s, y: -68 * s)
                // Crest plume
                Path { p in
                    p.move(to: CGPoint(x: 86 * s, y: 24 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 110 * s, y: 14 * s),
                        control: CGPoint(x: 98 * s, y: 6 * s)
                    )
                }
                .stroke(CompanionInk.charcoal, lineWidth: 1.2 * s)
                // Long pointed beak
                Path { p in
                    p.move(to: CGPoint(x: 96 * s, y: 30 * s))
                    p.addLine(to: CGPoint(x: 154 * s, y: 22 * s))
                    p.addLine(to: CGPoint(x: 96 * s, y: 38 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.amber)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 3 * s, height: 3 * s)
                    .offset(x: -16 * s, y: -68 * s)
            }
        }
    }
}
