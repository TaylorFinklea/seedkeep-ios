import SwiftUI

/// Mythical-tier — "Ninetails of pale flame, a graduation-portent".
/// Pale silhouette with nine gold tail-strokes radiating.
struct SpiritFoxIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Nine gold tails (mythical flourish) — radiating
                ForEach(0..<9) { i in
                    SpiritFoxTail(index: i, scale: s)
                }
                // Body — pale ghostly
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.cream.opacity(0.85), CompanionInk.pale.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 110 * s, height: 70 * s)
                    .offset(y: 28 * s)
                // Head
                Path { p in
                    p.move(to: CGPoint(x: 30 * s, y: 60 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 90 * s, y: 60 * s),
                        control: CGPoint(x: 60 * s, y: 30 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 70 * s, y: 100 * s),
                        control: CGPoint(x: 100 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 14 * s, y: 88 * s),
                        control: CGPoint(x: 20 * s, y: 110 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 30 * s, y: 60 * s),
                        control: CGPoint(x: 4 * s, y: 70 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.cream.opacity(0.9), CompanionInk.pale.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                ))
                // Ear triangles — pointed
                Path { p in
                    p.move(to: CGPoint(x: 30 * s, y: 50 * s))
                    p.addLine(to: CGPoint(x: 24 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 50 * s, y: 44 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.pale)
                Path { p in
                    p.move(to: CGPoint(x: 84 * s, y: 50 * s))
                    p.addLine(to: CGPoint(x: 96 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 74 * s, y: 44 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.pale)
                // Gold ear-tip flourish
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 5 * s, height: 5 * s)
                    .offset(x: -76 * s, y: -86 * s)
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 5 * s, height: 5 * s)
                    .offset(x: -4 * s, y: -86 * s)
                // Glowing gold eyes
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 8 * s, height: 8 * s)
                    .offset(x: -42 * s, y: -22 * s)
                Circle()
                    .fill(HerbColor.goldInk)
                    .frame(width: 8 * s, height: 8 * s)
                    .offset(x: -22 * s, y: -22 * s)
                // Nose
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: -82 * s, y: -2 * s)
            }
        }
    }
}

/// Single radiating tail stroke. Extracted into its own view so the
/// type-checker doesn't time out on the parent body (compiler hits
/// `unable to type-check this expression in reasonable time` when the
/// ForEach payload is inlined with the rest of the ZStack).
private struct SpiritFoxTail: View {
    let index: Int
    let scale: CGFloat

    var body: some View {
        let s = scale
        let a = Double(index) / 8 * (.pi * 0.95) - .pi / 2 - .pi / 4
        let rOut: Double = 88
        let endX = (150 + cos(a) * rOut) * Double(s)
        let endY = (110 + sin(a) * rOut) * Double(s)
        let ctlX = (160 + cos(a) * (rOut * 0.4)) * Double(s)
        let ctlY = (110 + sin(a) * (rOut * 0.4)) * Double(s)
        return Path { p in
            p.move(to: CGPoint(x: 150 * s, y: 110 * s))
            p.addQuadCurve(
                to: CGPoint(x: endX, y: endY),
                control: CGPoint(x: ctlX, y: ctlY)
            )
        }
        .stroke(HerbColor.goldInk, style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
    }
}
