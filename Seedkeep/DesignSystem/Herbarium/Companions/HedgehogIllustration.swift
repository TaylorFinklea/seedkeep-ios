import SwiftUI

/// Uncommon-tier — "Prickled night-rambler, slug's nemesis". Spiny
/// dome with little face poking out.
struct HedgehogIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Spine dome
                Path { p in
                    p.move(to: CGPoint(x: 40 * s, y: 140 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 50 * s),
                        control: CGPoint(x: 50 * s, y: 70 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 170 * s, y: 140 * s),
                        control: CGPoint(x: 160 * s, y: 60 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.outlineSoft, CompanionInk.outline],
                    startPoint: .top, endPoint: .bottom
                ))
                // Spines (short lines)
                ForEach(0..<28) { i in
                    Path { p in
                        let a = (Double(i) / 28) * .pi
                        let cx: Double = 100
                        let cy: Double = 140
                        let r1: Double = 84
                        let r2: Double = 96
                        p.move(to: CGPoint(
                            x: (cx + cos(.pi + a) * r1) * s,
                            y: (cy + sin(.pi + a) * r1) * s
                        ))
                        p.addLine(to: CGPoint(
                            x: (cx + cos(.pi + a) * r2) * s,
                            y: (cy + sin(.pi + a) * r2) * s
                        ))
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1 * s)
                }
                // Face — peeking from front
                Ellipse()
                    .fill(CompanionInk.cream.opacity(0.9))
                    .frame(width: 56 * s, height: 40 * s)
                    .offset(x: -30 * s, y: 30 * s)
                // Nose
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 8 * s, height: 8 * s)
                    .offset(x: -58 * s, y: 36 * s)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: -34 * s, y: 22 * s)
                // Feet
                Ellipse().fill(CompanionInk.outline).frame(width: 14 * s, height: 8 * s).offset(x: -30 * s, y: 60 * s)
                Ellipse().fill(CompanionInk.outline).frame(width: 14 * s, height: 8 * s).offset(x: 60 * s, y: 60 * s)
            }
        }
    }
}
