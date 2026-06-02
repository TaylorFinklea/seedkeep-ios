import SwiftUI

/// Legendary-tier — "Long-eared cartographer of the moon". Long upright
/// ears, alert hindquarters.
struct HareIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.earth, CompanionInk.earthDark],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 110 * s, height: 110 * s)
                    .offset(y: 30 * s)
                // Belly
                Ellipse()
                    .fill(CompanionInk.cream)
                    .frame(width: 50 * s, height: 32 * s)
                    .offset(y: 64 * s)
                // Head
                Ellipse()
                    .fill(CompanionInk.earth)
                    .frame(width: 56 * s, height: 60 * s)
                    .offset(x: -30 * s, y: -10 * s)
                // Long ears — upright
                Path { p in
                    p.move(to: CGPoint(x: 64 * s, y: 60 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 8 * s),
                        control: CGPoint(x: 56 * s, y: 30 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 76 * s, y: 60 * s),
                        control: CGPoint(x: 78 * s, y: 28 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.earth)
                Path { p in
                    p.move(to: CGPoint(x: 84 * s, y: 64 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 92 * s, y: 12 * s),
                        control: CGPoint(x: 88 * s, y: 36 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 96 * s, y: 64 * s),
                        control: CGPoint(x: 106 * s, y: 32 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.earth)
                // Inner ear blush
                Path { p in
                    p.move(to: CGPoint(x: 66 * s, y: 50 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 64 * s, y: 22 * s),
                        control: CGPoint(x: 60 * s, y: 36 * s)
                    )
                    p.addLine(to: CGPoint(x: 72 * s, y: 50 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.pale.opacity(0.7))
                // Nose + eye
                Circle().fill(CompanionInk.outline).frame(width: 4 * s, height: 4 * s).offset(x: -60 * s, y: 14 * s)
                Circle().fill(CompanionInk.outline).frame(width: 6 * s, height: 6 * s).offset(x: -40 * s, y: -2 * s)
                // Forelegs
                Capsule().fill(CompanionInk.earthDark).frame(width: 12 * s, height: 50 * s).offset(x: -18 * s, y: 70 * s)
                Capsule().fill(CompanionInk.earthDark).frame(width: 12 * s, height: 50 * s).offset(x: 6 * s, y: 70 * s)
                // Big back leg
                Path { p in
                    p.move(to: CGPoint(x: 130 * s, y: 110 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 160 * s, y: 160 * s),
                        control: CGPoint(x: 170 * s, y: 120 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 120 * s, y: 144 * s),
                        control: CGPoint(x: 140 * s, y: 164 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.earthDark)
            }
        }
    }
}
