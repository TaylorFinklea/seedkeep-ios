import SwiftUI

/// Common-tier — "Armored, agreeable, mostly asleep". Side-on slate
/// crescent with segmented plates.
struct PillbugIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body — semi-circle dome curling over a flat belly
                Path { p in
                    p.move(to: CGPoint(x: 40 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 160 * s, y: 130 * s),
                        control: CGPoint(x: 100 * s, y: 40 * s)
                    )
                    p.addLine(to: CGPoint(x: 40 * s, y: 130 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.slateBlue, CompanionInk.dusk],
                    startPoint: .top, endPoint: .bottom
                ))
                // Plate segments — vertical ridges
                ForEach(0..<5) { i in
                    Path { p in
                        let t = Double(i + 1) / 6
                        let x = 40 + 120 * t
                        let topY = 130 - 88 * sin(t * .pi)
                        p.move(to: CGPoint(x: CGFloat(x) * s, y: 130 * s))
                        p.addLine(to: CGPoint(x: CGFloat(x) * s, y: CGFloat(topY) * s))
                    }
                    .stroke(CompanionInk.outline.opacity(0.6), lineWidth: 0.8 * s)
                }
                // Head dot + antennae
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 8 * s, height: 8 * s)
                    .offset(x: 56 * s, y: 30 * s)
                Path { p in
                    p.move(to: CGPoint(x: 156 * s, y: 122 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 178 * s, y: 110 * s),
                        control: CGPoint(x: 168 * s, y: 118 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 0.8 * s)
                // Tiny legs hint
                ForEach(0..<5) { i in
                    Path { p in
                        let x = CGFloat(60 + i * 16) * s
                        p.move(to: CGPoint(x: x, y: 130 * s))
                        p.addLine(to: CGPoint(x: x, y: 140 * s))
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1 * s)
                }
            }
        }
    }
}
