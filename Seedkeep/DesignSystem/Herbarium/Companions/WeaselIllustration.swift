import SwiftUI

/// Rare-tier — "Ribbon of brown through the rows". Long-bodied
/// elongated mustelid, low to the ground.
struct WeaselIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Long body
                Capsule()
                    .fill(LinearGradient(
                        colors: [CompanionInk.rust, CompanionInk.earthDark],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 150 * s, height: 50 * s)
                    .offset(y: 28 * s)
                // Cream belly stripe
                Capsule()
                    .fill(CompanionInk.cream)
                    .frame(width: 130 * s, height: 18 * s)
                    .offset(y: 40 * s)
                // Tail
                Path { p in
                    p.move(to: CGPoint(x: 168 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 196 * s, y: 96 * s),
                        control: CGPoint(x: 196 * s, y: 130 * s)
                    )
                }
                .stroke(LinearGradient(
                    colors: [CompanionInk.rust, CompanionInk.outline],
                    startPoint: .leading, endPoint: .trailing
                ), style: StrokeStyle(lineWidth: 14 * s, lineCap: .round))
                // Head
                Ellipse()
                    .fill(CompanionInk.rust)
                    .frame(width: 50 * s, height: 40 * s)
                    .offset(x: -64 * s, y: 12 * s)
                // Ears
                Circle()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 14 * s, height: 14 * s)
                    .offset(x: -76 * s, y: -6 * s)
                Circle()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 14 * s, height: 14 * s)
                    .offset(x: -56 * s, y: -8 * s)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: -64 * s, y: 8 * s)
                // Nose
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: -82 * s, y: 16 * s)
                // Legs — four short ones
                ForEach(0..<4) { i in
                    Capsule()
                        .fill(CompanionInk.outline)
                        .frame(width: 6 * s, height: 24 * s)
                        .offset(x: CGFloat(-40 + i * 28) * s, y: 60 * s)
                }
            }
        }
    }
}
