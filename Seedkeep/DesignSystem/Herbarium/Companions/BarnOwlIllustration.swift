import SwiftUI

/// Rare-tier — "Pale-faced overseer of nightshift". Iconic heart-shaped
/// pale face on a cream-and-rust body.
struct BarnOwlIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body — tall ovoid
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.amber, CompanionInk.sepia],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 96 * s, height: 130 * s)
                    .offset(y: 16 * s)
                // Belly — paler streaked
                Ellipse()
                    .fill(CompanionInk.cream.opacity(0.8))
                    .frame(width: 70 * s, height: 86 * s)
                    .offset(y: 30 * s)
                // Spots on belly
                ForEach(0..<7) { i in
                    Circle()
                        .fill(CompanionInk.sepia.opacity(0.7))
                        .frame(width: 3 * s, height: 3 * s)
                        .offset(
                            x: CGFloat(-16 + (i % 3) * 16) * s,
                            y: CGFloat(20 + (i / 3) * 18) * s
                        )
                }
                // Wings (folded)
                Path { p in
                    p.move(to: CGPoint(x: 56 * s, y: 80 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 38 * s, y: 130 * s),
                        control: CGPoint(x: 30 * s, y: 100 * s)
                    )
                }
                .stroke(CompanionInk.sepia, style: StrokeStyle(lineWidth: 14 * s, lineCap: .round))
                Path { p in
                    p.move(to: CGPoint(x: 144 * s, y: 80 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 162 * s, y: 130 * s),
                        control: CGPoint(x: 170 * s, y: 100 * s)
                    )
                }
                .stroke(CompanionInk.sepia, style: StrokeStyle(lineWidth: 14 * s, lineCap: .round))
                // Heart-shaped face
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 30 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 50 * s),
                        control: CGPoint(x: 64 * s, y: 28 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 88 * s),
                        control: CGPoint(x: 50 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 50 * s),
                        control: CGPoint(x: 150 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 30 * s),
                        control: CGPoint(x: 136 * s, y: 28 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.cream)
                // Face outline (heart edge)
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 30 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 50 * s),
                        control: CGPoint(x: 64 * s, y: 28 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 88 * s),
                        control: CGPoint(x: 50 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 50 * s),
                        control: CGPoint(x: 150 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 30 * s),
                        control: CGPoint(x: 136 * s, y: 28 * s)
                    )
                }
                .stroke(CompanionInk.sepia, lineWidth: 1 * s)
                // Eyes — big black dots
                Circle().fill(CompanionInk.outline).frame(width: 18 * s, height: 22 * s).offset(x: -14 * s, y: -36 * s)
                Circle().fill(CompanionInk.outline).frame(width: 18 * s, height: 22 * s).offset(x: 14 * s, y: -36 * s)
                // Beak
                Path { p in
                    p.move(to: CGPoint(x: 94 * s, y: 64 * s))
                    p.addLine(to: CGPoint(x: 100 * s, y: 78 * s))
                    p.addLine(to: CGPoint(x: 106 * s, y: 64 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.outlineSoft)
            }
        }
    }
}
