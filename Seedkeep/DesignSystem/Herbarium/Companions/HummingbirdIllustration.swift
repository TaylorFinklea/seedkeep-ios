import SwiftUI

/// Uncommon-tier — "Iridescent comma in the air". Hovering pose,
/// blurred wing suggestion, long needle beak.
struct HummingbirdIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Wing blur — translucent ovals
                Ellipse()
                    .fill(CompanionInk.teal.opacity(0.35))
                    .frame(width: 80 * s, height: 30 * s)
                    .rotationEffect(.degrees(-30))
                    .offset(x: 40 * s, y: -10 * s)
                Ellipse()
                    .fill(CompanionInk.teal.opacity(0.35))
                    .frame(width: 80 * s, height: 30 * s)
                    .rotationEffect(.degrees(30))
                    .offset(x: 40 * s, y: 24 * s)
                // Body — long teardrop curving down-right
                Path { p in
                    p.move(to: CGPoint(x: 88 * s, y: 70 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 110 * s),
                        control: CGPoint(x: 60 * s, y: 80 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 130 * s),
                        control: CGPoint(x: 70 * s, y: 134 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 88 * s, y: 70 * s),
                        control: CGPoint(x: 116 * s, y: 100 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.teal, CompanionInk.leafDark],
                    startPoint: .top, endPoint: .bottom
                ))
                // Iridescent throat patch
                Path { p in
                    p.move(to: CGPoint(x: 80 * s, y: 86 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 110 * s),
                        control: CGPoint(x: 64 * s, y: 92 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 88 * s, y: 110 * s),
                        control: CGPoint(x: 72 * s, y: 114 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.red.opacity(0.85))
                // Head
                Circle()
                    .fill(CompanionInk.teal)
                    .frame(width: 36 * s, height: 34 * s)
                    .offset(x: 14 * s, y: -32 * s)
                // Beak — long thin needle
                Path { p in
                    p.move(to: CGPoint(x: 110 * s, y: 64 * s))
                    p.addLine(to: CGPoint(x: 180 * s, y: 58 * s))
                }
                .stroke(CompanionInk.outline, style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: 116 * s, y: 66 * s)
                // Tail
                Path { p in
                    p.move(to: CGPoint(x: 70 * s, y: 124 * s))
                    p.addLine(to: CGPoint(x: 40 * s, y: 150 * s))
                    p.addLine(to: CGPoint(x: 64 * s, y: 134 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.leafDark)
            }
        }
    }
}
