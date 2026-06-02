import SwiftUI

/// Uncommon-tier — "Stained-glass hover, summer-stitched". Long teal
/// abdomen, four lacy wings.
struct DragonflyIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Four wings — upper + lower pairs
                ForEach(0..<4) { i in
                    let isLeft = i % 2 == 0
                    let isUpper = i < 2
                    let xOff: CGFloat = (isLeft ? -1 : 1) * 36
                    let yOff: CGFloat = isUpper ? -22 : 8
                    let rot: Double = (isLeft ? -1 : 1) * (isUpper ? 14 : -8)
                    Ellipse()
                        .fill(CompanionInk.teal.opacity(0.35))
                        .frame(width: 70 * s, height: 24 * s)
                        .rotationEffect(.degrees(rot))
                        .offset(x: xOff * s, y: yOff * s)
                    Ellipse()
                        .strokeBorder(CompanionInk.teal.opacity(0.7), lineWidth: 0.6 * s)
                        .frame(width: 70 * s, height: 24 * s)
                        .rotationEffect(.degrees(rot))
                        .offset(x: xOff * s, y: yOff * s)
                }
                // Body — long slender abdomen
                Path { p in
                    p.move(to: CGPoint(x: 96 * s, y: 70 * s))
                    p.addLine(to: CGPoint(x: 96 * s, y: 168 * s))
                    p.addLine(to: CGPoint(x: 104 * s, y: 168 * s))
                    p.addLine(to: CGPoint(x: 104 * s, y: 70 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.teal, CompanionInk.charcoal],
                    startPoint: .top, endPoint: .bottom
                ))
                // Abdomen segments
                ForEach(0..<6) { i in
                    Path { p in
                        let y = CGFloat(86 + i * 12) * s
                        p.move(to: CGPoint(x: 96 * s, y: y))
                        p.addLine(to: CGPoint(x: 104 * s, y: y))
                    }
                    .stroke(CompanionInk.outline.opacity(0.7), lineWidth: 0.6 * s)
                }
                // Thorax
                Ellipse()
                    .fill(CompanionInk.teal)
                    .frame(width: 26 * s, height: 22 * s)
                    .offset(y: -28 * s)
                // Head
                Circle()
                    .fill(CompanionInk.charcoal)
                    .frame(width: 28 * s, height: 26 * s)
                    .offset(y: -52 * s)
                // Big compound eyes
                Circle()
                    .fill(CompanionInk.teal)
                    .frame(width: 14 * s, height: 14 * s)
                    .offset(x: -8 * s, y: -56 * s)
                Circle()
                    .fill(CompanionInk.teal)
                    .frame(width: 14 * s, height: 14 * s)
                    .offset(x: 8 * s, y: -56 * s)
            }
        }
    }
}
