import SwiftUI

/// Common-tier (autumn) — "Granary auditor of the late rows". Like
/// field mouse but with a tiny grain stalk in its paws.
struct HarvestMouseIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Tail
                Path { p in
                    p.move(to: CGPoint(x: 60 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 24 * s, y: 90 * s),
                        control: CGPoint(x: 30 * s, y: 130 * s)
                    )
                }
                .stroke(CompanionInk.amber, lineWidth: 1.4 * s)
                // Body
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.amber, CompanionInk.rust],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 88 * s, height: 78 * s)
                    .offset(x: 6 * s, y: 18 * s)
                // Head
                Circle()
                    .fill(CompanionInk.amber)
                    .frame(width: 54 * s, height: 54 * s)
                    .offset(x: 46 * s, y: -8 * s)
                // Belly highlight
                Ellipse()
                    .fill(CompanionInk.cream.opacity(0.5))
                    .frame(width: 36 * s, height: 28 * s)
                    .offset(x: 6 * s, y: 26 * s)
                // Ears
                Circle()
                    .fill(CompanionInk.rust)
                    .frame(width: 22 * s, height: 22 * s)
                    .offset(x: 62 * s, y: -34 * s)
                Circle()
                    .fill(CompanionInk.rust)
                    .frame(width: 22 * s, height: 22 * s)
                    .offset(x: 36 * s, y: -38 * s)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 5 * s, height: 5 * s)
                    .offset(x: 56 * s, y: -8 * s)
                // Grain stalk in paws
                Path { p in
                    p.move(to: CGPoint(x: 90 * s, y: 130 * s))
                    p.addLine(to: CGPoint(x: 130 * s, y: 80 * s))
                }
                .stroke(CompanionInk.outlineSoft, lineWidth: 1 * s)
                ForEach(0..<4) { i in
                    Ellipse()
                        .fill(CompanionInk.amber)
                        .frame(width: 5 * s, height: 8 * s)
                        .offset(x: CGFloat(28 + i * 2) * s, y: CGFloat(-30 + i * 8) * s)
                }
            }
        }
    }
}
