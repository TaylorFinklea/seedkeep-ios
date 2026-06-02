import SwiftUI

/// Legendary-tier — "Tufted patrician of the hedge". Squat upright
/// posture with signature ear-tufts.
struct LynxIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.sepiaLight, CompanionInk.earthDark],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 120 * s, height: 110 * s)
                    .offset(y: 36 * s)
                // Spot pattern
                ForEach(0..<8) { i in
                    Circle()
                        .fill(CompanionInk.outline.opacity(0.55))
                        .frame(width: 6 * s, height: 6 * s)
                        .offset(
                            x: CGFloat(-30 + (i % 4) * 18) * s,
                            y: CGFloat(20 + (i / 4) * 22) * s
                        )
                }
                // Belly
                Ellipse()
                    .fill(CompanionInk.cream.opacity(0.8))
                    .frame(width: 56 * s, height: 32 * s)
                    .offset(y: 60 * s)
                // Head
                Path { p in
                    p.move(to: CGPoint(x: 60 * s, y: 70 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 70 * s),
                        control: CGPoint(x: 100 * s, y: 40 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 116 * s),
                        control: CGPoint(x: 146 * s, y: 100 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 70 * s, y: 116 * s),
                        control: CGPoint(x: 100 * s, y: 134 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 70 * s),
                        control: CGPoint(x: 54 * s, y: 100 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.sepiaLight, CompanionInk.earth],
                    startPoint: .top, endPoint: .bottom
                ))
                // Ears + tufts
                Path { p in
                    p.move(to: CGPoint(x: 70 * s, y: 60 * s))
                    p.addLine(to: CGPoint(x: 62 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 90 * s, y: 50 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.earth)
                Path { p in
                    p.move(to: CGPoint(x: 130 * s, y: 60 * s))
                    p.addLine(to: CGPoint(x: 138 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 110 * s, y: 50 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.earth)
                Path { p in
                    p.move(to: CGPoint(x: 62 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 60 * s, y: 0 * s))
                    p.move(to: CGPoint(x: 138 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 140 * s, y: 0 * s))
                }
                .stroke(CompanionInk.outline, lineWidth: 1.4 * s)
                // Cheek ruffs
                Path { p in
                    p.move(to: CGPoint(x: 60 * s, y: 96 * s))
                    p.addLine(to: CGPoint(x: 36 * s, y: 110 * s))
                    p.addLine(to: CGPoint(x: 60 * s, y: 104 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.cream.opacity(0.7))
                // Eyes
                Ellipse().fill(CompanionInk.amber).frame(width: 10 * s, height: 12 * s).offset(x: -16 * s, y: -16 * s)
                Ellipse().fill(CompanionInk.amber).frame(width: 10 * s, height: 12 * s).offset(x: 16 * s, y: -16 * s)
                Circle().fill(CompanionInk.outline).frame(width: 3 * s, height: 6 * s).offset(x: -16 * s, y: -16 * s)
                Circle().fill(CompanionInk.outline).frame(width: 3 * s, height: 6 * s).offset(x: 16 * s, y: -16 * s)
                // Nose
                Path { p in
                    p.move(to: CGPoint(x: 94 * s, y: 4 * s + 90 * s))
                    p.addLine(to: CGPoint(x: 100 * s, y: 100 * s))
                    p.addLine(to: CGPoint(x: 106 * s, y: 94 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.outline)
            }
        }
    }
}
