import SwiftUI

/// Common-tier — "Brown coat, brisk opinions". Compact brown-grey perch
/// shape, beak ajar.
struct SparrowIllustration: View {
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
                    .frame(width: 100 * s, height: 90 * s)
                    .offset(y: 4 * s)
                // Belly — paler underside
                Ellipse()
                    .fill(CompanionInk.pale.opacity(0.7))
                    .frame(width: 60 * s, height: 36 * s)
                    .offset(x: 4 * s, y: 32 * s)
                // Wing wash
                Path { p in
                    p.move(to: CGPoint(x: 110 * s, y: 70 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 120 * s),
                        control: CGPoint(x: 156 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 100 * s),
                        control: CGPoint(x: 124 * s, y: 130 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.outline.opacity(0.55))
                // Head
                Circle()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 52 * s, height: 50 * s)
                    .offset(x: -34 * s, y: -22 * s)
                // Cheek patch
                Circle()
                    .fill(CompanionInk.earth)
                    .frame(width: 18 * s, height: 16 * s)
                    .offset(x: -28 * s, y: -16 * s)
                // Beak — open
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 76 * s))
                    p.addLine(to: CGPoint(x: 32 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 50 * s, y: 86 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.outlineSoft)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 5 * s, height: 5 * s)
                    .offset(x: -42 * s, y: -22 * s)
                // Tail
                Path { p in
                    p.move(to: CGPoint(x: 150 * s, y: 100 * s))
                    p.addLine(to: CGPoint(x: 180 * s, y: 110 * s))
                    p.addLine(to: CGPoint(x: 152 * s, y: 116 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.earthDark)
                // Legs
                Path { p in
                    p.move(to: CGPoint(x: 88 * s, y: 140 * s))
                    p.addLine(to: CGPoint(x: 90 * s, y: 160 * s))
                    p.move(to: CGPoint(x: 102 * s, y: 140 * s))
                    p.addLine(to: CGPoint(x: 104 * s, y: 160 * s))
                }
                .stroke(CompanionInk.outlineSoft, lineWidth: 1 * s)
            }
        }
    }
}
