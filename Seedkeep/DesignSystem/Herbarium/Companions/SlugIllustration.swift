import SwiftUI

/// Common-tier — "Silver-tracked nightwalker". Damp grey teardrop with
/// silvery slime line.
struct SlugIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Slime trail
                Path { p in
                    p.move(to: CGPoint(x: 10 * s, y: 156 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 152 * s),
                        control: CGPoint(x: 60 * s, y: 162 * s)
                    )
                }
                .stroke(CompanionInk.cream.opacity(0.6), style: StrokeStyle(lineWidth: 2 * s, dash: [3, 4]))
                // Body — elongated teardrop
                Path { p in
                    p.move(to: CGPoint(x: 36 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 100 * s),
                        control: CGPoint(x: 56 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 168 * s, y: 130 * s),
                        control: CGPoint(x: 150 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 150 * s),
                        control: CGPoint(x: 130 * s, y: 158 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 36 * s, y: 130 * s),
                        control: CGPoint(x: 60 * s, y: 152 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.dusk, CompanionInk.charcoal],
                    startPoint: .top, endPoint: .bottom
                ))
                // Body highlight
                Path { p in
                    p.move(to: CGPoint(x: 60 * s, y: 116 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 116 * s),
                        control: CGPoint(x: 100 * s, y: 104 * s)
                    )
                }
                .stroke(CompanionInk.pale.opacity(0.3), lineWidth: 2 * s)
                // Eye stalks (slug-style)
                Path { p in
                    p.move(to: CGPoint(x: 162 * s, y: 110 * s))
                    p.addLine(to: CGPoint(x: 174 * s, y: 88 * s))
                }
                .stroke(CompanionInk.dusk, lineWidth: 1.5 * s)
                Path { p in
                    p.move(to: CGPoint(x: 150 * s, y: 108 * s))
                    p.addLine(to: CGPoint(x: 156 * s, y: 86 * s))
                }
                .stroke(CompanionInk.dusk, lineWidth: 1.5 * s)
                // Stalk tip eyes
                Circle().fill(CompanionInk.outline).frame(width: 5 * s, height: 5 * s).offset(x: 74 * s, y: -16 * s)
                Circle().fill(CompanionInk.outline).frame(width: 4 * s, height: 4 * s).offset(x: 56 * s, y: -18 * s)
            }
        }
    }
}
