import SwiftUI

/// Mythical-tier — "Mischief in green ink, fond of stolen radishes".
/// Small horned sprite, leaf-cloaked, with gold-pupil eye.
struct GardenImpIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 50 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 150 * s),
                        control: CGPoint(x: 50 * s, y: 100 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 150 * s),
                        control: CGPoint(x: 100 * s, y: 170 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 50 * s),
                        control: CGPoint(x: 150 * s, y: 100 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.leafLight, CompanionInk.leafDark],
                    startPoint: .top, endPoint: .bottom
                ))
                // Leaf cloak overlay (zig-zag fringe)
                Path { p in
                    p.move(to: CGPoint(x: 56 * s, y: 130 * s))
                    p.addLine(to: CGPoint(x: 64 * s, y: 142 * s))
                    p.addLine(to: CGPoint(x: 72 * s, y: 130 * s))
                    p.addLine(to: CGPoint(x: 84 * s, y: 144 * s))
                    p.addLine(to: CGPoint(x: 100 * s, y: 130 * s))
                    p.addLine(to: CGPoint(x: 116 * s, y: 144 * s))
                    p.addLine(to: CGPoint(x: 128 * s, y: 130 * s))
                    p.addLine(to: CGPoint(x: 136 * s, y: 142 * s))
                    p.addLine(to: CGPoint(x: 144 * s, y: 130 * s))
                }
                .stroke(CompanionInk.leafDark, lineWidth: 1.4 * s)
                // Head
                Circle()
                    .fill(CompanionInk.leafLight)
                    .frame(width: 70 * s, height: 70 * s)
                    .offset(y: -36 * s)
                // Gold-tipped horns
                Path { p in
                    p.move(to: CGPoint(x: 76 * s, y: 36 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 8 * s),
                        control: CGPoint(x: 68 * s, y: 20 * s)
                    )
                }
                .stroke(CompanionInk.leafDark, style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
                Path { p in
                    p.move(to: CGPoint(x: 124 * s, y: 36 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 8 * s),
                        control: CGPoint(x: 132 * s, y: 20 * s)
                    )
                }
                .stroke(CompanionInk.leafDark, style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
                // Gold horn tips (mythical flourish)
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 6 * s, height: 6 * s)
                    .offset(x: -40 * s, y: -92 * s)
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 6 * s, height: 6 * s)
                    .offset(x: 40 * s, y: -92 * s)
                // Eyes — left normal, right gold pupil (mythical flourish)
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 8 * s, height: 10 * s)
                    .offset(x: -12 * s, y: -44 * s)
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 8 * s, height: 10 * s)
                    .offset(x: 12 * s, y: -44 * s)
                // Mischief grin
                Path { p in
                    p.move(to: CGPoint(x: 86 * s, y: 84 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 114 * s, y: 84 * s),
                        control: CGPoint(x: 100 * s, y: 96 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1.4 * s)
            }
        }
    }
}
