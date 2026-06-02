import SwiftUI

/// Common-tier — "Quiet engineer of the underdark". Segmented coil.
struct GardenWormIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Coil-curve body
                Path { p in
                    p.move(to: CGPoint(x: 36 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 80 * s, y: 70 * s),
                        control: CGPoint(x: 40 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 100 * s),
                        control: CGPoint(x: 120 * s, y: 50 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 168 * s, y: 130 * s),
                        control: CGPoint(x: 158 * s, y: 140 * s)
                    )
                }
                .stroke(LinearGradient(
                    colors: [CompanionInk.rust, CompanionInk.earthDark],
                    startPoint: .top, endPoint: .bottom
                ), style: StrokeStyle(lineWidth: 24 * s, lineCap: .round))
                // Segments
                ForEach(0..<7) { i in
                    Path { p in
                        let t = CGFloat(i) / 6
                        let cx = 36 + (168 - 36) * t
                        let cy = 130 - 40 * sin(Double(t) * .pi)
                        let perp = cos(Double(t) * .pi)
                        p.move(to: CGPoint(
                            x: CGFloat(cx) * s - CGFloat(perp) * 8 * s,
                            y: (CGFloat(cy) - 8) * s
                        ))
                        p.addLine(to: CGPoint(
                            x: CGFloat(cx) * s + CGFloat(perp) * 8 * s,
                            y: (CGFloat(cy) + 8) * s
                        ))
                    }
                    .stroke(CompanionInk.outline.opacity(0.6), lineWidth: 0.8 * s)
                }
                // Head bulge
                Circle()
                    .fill(CompanionInk.rust)
                    .frame(width: 22 * s, height: 22 * s)
                    .offset(x: 68 * s, y: 30 * s)
                // Tiny eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 3 * s, height: 3 * s)
                    .offset(x: 70 * s, y: 26 * s)
            }
        }
    }
}
