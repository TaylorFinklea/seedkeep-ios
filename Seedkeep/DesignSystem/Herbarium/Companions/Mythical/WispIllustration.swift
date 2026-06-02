import SwiftUI

/// Mythical-tier — "A travelled candleflame in search of a wick". Pale
/// teardrop flame inside a static gold radial halo.
struct WispIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Outer gold radial halo (mythical flourish)
                Circle()
                    .fill(RadialGradient(
                        colors: [
                            HerbColor.goldInk.opacity(0.5),
                            HerbColor.goldInk.opacity(0.18),
                            HerbColor.goldInk.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 110
                    ))
                    .frame(width: 200 * s, height: 200 * s)
                // Twelve gold rays
                ForEach(0..<12) { i in
                    Path { p in
                        let a = Double(i) / 12 * .pi * 2
                        let r1: Double = 70
                        let r2: Double = 92
                        p.move(to: CGPoint(
                            x: (100 + cos(a) * r1) * Double(s),
                            y: (100 + sin(a) * r1) * Double(s)
                        ))
                        p.addLine(to: CGPoint(
                            x: (100 + cos(a) * r2) * Double(s),
                            y: (100 + sin(a) * r2) * Double(s)
                        ))
                    }
                    .stroke(HerbColor.goldInk, style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round))
                }
                // Flame body — teardrop
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 36 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 70 * s, y: 130 * s),
                        control: CGPoint(x: 50 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 130 * s),
                        control: CGPoint(x: 100 * s, y: 156 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 36 * s),
                        control: CGPoint(x: 150 * s, y: 80 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [
                        CompanionInk.cream,
                        HerbColor.goldInk.opacity(0.85),
                        CompanionInk.amber.opacity(0.6)
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                // Inner highlight
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 56 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 86 * s, y: 110 * s),
                        control: CGPoint(x: 78 * s, y: 82 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 120 * s),
                        control: CGPoint(x: 100 * s, y: 130 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 56 * s),
                        control: CGPoint(x: 110 * s, y: 80 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.cream.opacity(0.85))
                // Tiny eyes inside the flame
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: -6 * s, y: -6 * s)
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: 6 * s, y: -6 * s)
            }
        }
    }
}
