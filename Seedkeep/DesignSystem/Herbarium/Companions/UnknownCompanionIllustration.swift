import SwiftUI

/// Forward-compat fallback for `CompanionKind.unknown`. Generic sepia
/// silhouette with a "?" ornament — keeps rendering safe when the
/// server ships a creature kind the client doesn't yet know about.
struct UnknownCompanionIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Generic creature silhouette — a quadruped
                Path { p in
                    p.move(to: CGPoint(x: 30 * s, y: 120 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 60 * s),
                        control: CGPoint(x: 30 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 60 * s),
                        control: CGPoint(x: 100 * s, y: 36 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 170 * s, y: 120 * s),
                        control: CGPoint(x: 170 * s, y: 80 * s)
                    )
                    p.addLine(to: CGPoint(x: 162 * s, y: 160 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 160 * s))
                    p.addLine(to: CGPoint(x: 130 * s, y: 124 * s))
                    p.addLine(to: CGPoint(x: 70 * s, y: 124 * s))
                    p.addLine(to: CGPoint(x: 58 * s, y: 160 * s))
                    p.addLine(to: CGPoint(x: 38 * s, y: 160 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.sepiaLight, CompanionInk.sepia],
                    startPoint: .top, endPoint: .bottom
                ))
                // "?" ornament centered
                Text("?")
                    .font(HerbFont.display(size: 56 * s))
                    .foregroundStyle(CompanionInk.cream)
                    .offset(y: -10 * s)
            }
        }
    }
}
