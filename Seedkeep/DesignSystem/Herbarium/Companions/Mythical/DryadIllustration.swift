import SwiftUI

/// Mythical-tier — "A small steward of leaf-shadow, votes for slow
/// growth". Bark-bodied figure with gold leaf-veins (mythical flourish).
struct DryadIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body — slender bark figure
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 56 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 70 * s, y: 168 * s),
                        control: CGPoint(x: 76 * s, y: 110 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 168 * s),
                        control: CGPoint(x: 100 * s, y: 180 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 56 * s),
                        control: CGPoint(x: 124 * s, y: 110 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.sepia, CompanionInk.earthDark],
                    startPoint: .top, endPoint: .bottom
                ))
                // Bark lines
                ForEach(0..<4) { i in
                    Path { p in
                        let y = CGFloat(80 + i * 22) * s
                        p.move(to: CGPoint(x: 84 * s, y: y))
                        p.addQuadCurve(
                            to: CGPoint(x: 116 * s, y: y + 4 * s),
                            control: CGPoint(x: 100 * s, y: y - 4 * s)
                        )
                    }
                    .stroke(CompanionInk.outline.opacity(0.7), lineWidth: 0.6 * s)
                }
                // Gold leaf-vein flourishes (mythical)
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 60 * s))
                    p.addLine(to: CGPoint(x: 100 * s, y: 160 * s))
                }
                .stroke(HerbColor.goldInk, lineWidth: 1.2 * s)
                ForEach(0..<5) { i in
                    Path { p in
                        let y = CGFloat(76 + i * 18) * s
                        p.move(to: CGPoint(x: 100 * s, y: y))
                        p.addQuadCurve(
                            to: CGPoint(x: (i % 2 == 0 ? 78 : 122) * s, y: y - 4 * s),
                            control: CGPoint(x: (i % 2 == 0 ? 88 : 112) * s, y: y - 8 * s)
                        )
                    }
                    .stroke(HerbColor.goldInk, lineWidth: 0.8 * s)
                }
                // Head — leaf-crowned
                Circle()
                    .fill(CompanionInk.sepia)
                    .frame(width: 64 * s, height: 60 * s)
                    .offset(y: -52 * s)
                // Leaf crown
                Path { p in
                    p.move(to: CGPoint(x: 70 * s, y: 40 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 8 * s),
                        control: CGPoint(x: 82 * s, y: 14 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 40 * s),
                        control: CGPoint(x: 118 * s, y: 14 * s)
                    )
                }
                .stroke(CompanionInk.leafDark, style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
                // Leaf-crown leaves
                ForEach(0..<5) { i in
                    Path { p in
                        let cx = CGFloat(74 + i * 14) * s
                        let cy = CGFloat(28 - abs(i - 2) * 8) * s
                        p.move(to: CGPoint(x: cx, y: cy))
                        p.addQuadCurve(
                            to: CGPoint(x: cx + 8 * s, y: cy + 8 * s),
                            control: CGPoint(x: cx + 10 * s, y: cy)
                        )
                        p.addQuadCurve(
                            to: CGPoint(x: cx, y: cy),
                            control: CGPoint(x: cx + 2 * s, y: cy + 10 * s)
                        )
                        p.closeSubpath()
                    }
                    .fill(CompanionInk.leafLight)
                }
                // Eyes — gold (mythical glow)
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 5 * s, height: 6 * s)
                    .offset(x: -10 * s, y: -54 * s)
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 5 * s, height: 6 * s)
                    .offset(x: 10 * s, y: -54 * s)
            }
        }
    }
}
