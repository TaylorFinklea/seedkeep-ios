import SwiftUI

/// Rare-tier — "Russet curiosity at the bed-edge". Side-on small fox
/// with triangle ears and bushy tail.
struct FoxKitIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Bushy tail
                Path { p in
                    p.move(to: CGPoint(x: 150 * s, y: 120 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 188 * s, y: 90 * s),
                        control: CGPoint(x: 180 * s, y: 130 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 160 * s, y: 80 * s),
                        control: CGPoint(x: 174 * s, y: 78 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.rust, CompanionInk.cream],
                    startPoint: .leading, endPoint: .trailing
                ))
                // Body
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.rust, CompanionInk.red],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 110 * s, height: 80 * s)
                    .offset(y: 28 * s)
                // Cream belly
                Ellipse()
                    .fill(CompanionInk.cream)
                    .frame(width: 60 * s, height: 32 * s)
                    .offset(y: 48 * s)
                // Legs
                Capsule().fill(CompanionInk.outline).frame(width: 8 * s, height: 36 * s).offset(x: -40 * s, y: 60 * s)
                Capsule().fill(CompanionInk.outline).frame(width: 8 * s, height: 36 * s).offset(x: -20 * s, y: 64 * s)
                Capsule().fill(CompanionInk.outline).frame(width: 8 * s, height: 36 * s).offset(x: 20 * s, y: 64 * s)
                Capsule().fill(CompanionInk.outline).frame(width: 8 * s, height: 36 * s).offset(x: 40 * s, y: 60 * s)
                // Head
                Path { p in
                    p.move(to: CGPoint(x: 30 * s, y: 50 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 90 * s, y: 50 * s),
                        control: CGPoint(x: 60 * s, y: 20 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 76 * s, y: 100 * s),
                        control: CGPoint(x: 92 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 20 * s, y: 90 * s),
                        control: CGPoint(x: 28 * s, y: 110 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 30 * s, y: 50 * s),
                        control: CGPoint(x: 14 * s, y: 70 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.rust, CompanionInk.red],
                    startPoint: .top, endPoint: .bottom
                ))
                // Ears — triangles
                Path { p in
                    p.move(to: CGPoint(x: 32 * s, y: 40 * s))
                    p.addLine(to: CGPoint(x: 26 * s, y: 12 * s))
                    p.addLine(to: CGPoint(x: 48 * s, y: 36 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.outline)
                Path { p in
                    p.move(to: CGPoint(x: 84 * s, y: 40 * s))
                    p.addLine(to: CGPoint(x: 96 * s, y: 12 * s))
                    p.addLine(to: CGPoint(x: 76 * s, y: 36 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.outline)
                // White muzzle + nose
                Ellipse().fill(CompanionInk.cream).frame(width: 22 * s, height: 18 * s).offset(x: -42 * s, y: 12 * s)
                Circle().fill(CompanionInk.outline).frame(width: 6 * s, height: 6 * s).offset(x: -50 * s, y: 12 * s)
                // Eyes
                Circle().fill(CompanionInk.outline).frame(width: 5 * s, height: 5 * s).offset(x: -32 * s, y: -10 * s)
                Circle().fill(CompanionInk.outline).frame(width: 5 * s, height: 5 * s).offset(x: -12 * s, y: -10 * s)
            }
        }
    }
}
