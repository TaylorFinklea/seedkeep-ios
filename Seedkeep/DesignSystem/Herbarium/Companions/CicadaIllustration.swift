import SwiftUI

/// Common-tier (summer) — "Long-buried tenor of the high heat". Stocky
/// body with clear veined wings folded back over.
struct CicadaIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Wings — translucent, back-folded
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 80 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 36 * s, y: 130 * s),
                        control: CGPoint(x: 50 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 150 * s),
                        control: CGPoint(x: 70 * s, y: 156 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.pale.opacity(0.55))
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 80 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 164 * s, y: 130 * s),
                        control: CGPoint(x: 150 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 150 * s),
                        control: CGPoint(x: 130 * s, y: 156 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.pale.opacity(0.55))
                // Wing veins
                ForEach(0..<3) { i in
                    Path { p in
                        let x = CGFloat(60 + i * 8) * s
                        p.move(to: CGPoint(x: 100 * s, y: 90 * s))
                        p.addLine(to: CGPoint(x: x, y: 130 * s))
                    }
                    .stroke(CompanionInk.outlineSoft.opacity(0.5), lineWidth: 0.4 * s)
                    Path { p in
                        let x = CGFloat(140 - i * 8) * s
                        p.move(to: CGPoint(x: 100 * s, y: 90 * s))
                        p.addLine(to: CGPoint(x: x, y: 130 * s))
                    }
                    .stroke(CompanionInk.outlineSoft.opacity(0.5), lineWidth: 0.4 * s)
                }
                // Body — chunky teardrop
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 60 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 80 * s, y: 140 * s),
                        control: CGPoint(x: 70 * s, y: 100 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 120 * s, y: 140 * s),
                        control: CGPoint(x: 100 * s, y: 160 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 60 * s),
                        control: CGPoint(x: 130 * s, y: 100 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.leafDark, CompanionInk.outline],
                    startPoint: .top, endPoint: .bottom
                ))
                // Head
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 28 * s, height: 24 * s)
                    .offset(y: -48 * s)
                // Eyes
                Circle().fill(CompanionInk.cream)
                    .frame(width: 6 * s, height: 6 * s).offset(x: -7 * s, y: -50 * s)
                Circle().fill(CompanionInk.cream)
                    .frame(width: 6 * s, height: 6 * s).offset(x: 7 * s, y: -50 * s)
            }
        }
    }
}
