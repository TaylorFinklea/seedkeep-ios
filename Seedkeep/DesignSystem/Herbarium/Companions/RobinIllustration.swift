import SwiftUI

/// Common-tier (spring) — "Red-breasted herald of the sowing". Side-on
/// perch, ruddy breast against a brown back.
struct RobinIllustration: View {
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
                    .frame(width: 100 * s, height: 80 * s)
                    .offset(y: 8 * s)
                // Breast — rusty bib
                Path { p in
                    p.move(to: CGPoint(x: 64 * s, y: 80 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 70 * s, y: 130 * s),
                        control: CGPoint(x: 56 * s, y: 110 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 110 * s, y: 120 * s),
                        control: CGPoint(x: 90 * s, y: 138 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 64 * s, y: 80 * s),
                        control: CGPoint(x: 90 * s, y: 80 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.rust, CompanionInk.red],
                    startPoint: .top, endPoint: .bottom
                ))
                // Head
                Circle()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 50 * s, height: 48 * s)
                    .offset(x: -34 * s, y: -20 * s)
                // Beak
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 76 * s))
                    p.addLine(to: CGPoint(x: 36 * s, y: 82 * s))
                    p.addLine(to: CGPoint(x: 50 * s, y: 84 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.amber)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 6 * s, height: 6 * s)
                    .offset(x: -42 * s, y: -22 * s)
                // Wing detail
                Path { p in
                    p.move(to: CGPoint(x: 110 * s, y: 90 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 130 * s),
                        control: CGPoint(x: 140 * s, y: 110 * s)
                    )
                }
                .stroke(CompanionInk.outline.opacity(0.7), lineWidth: 1 * s)
                // Legs / perch
                Path { p in
                    p.move(to: CGPoint(x: 86 * s, y: 138 * s))
                    p.addLine(to: CGPoint(x: 88 * s, y: 160 * s))
                    p.move(to: CGPoint(x: 100 * s, y: 138 * s))
                    p.addLine(to: CGPoint(x: 102 * s, y: 160 * s))
                }
                .stroke(CompanionInk.amber, lineWidth: 1.2 * s)
            }
        }
    }
}
