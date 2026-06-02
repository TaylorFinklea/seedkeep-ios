import SwiftUI

/// Common-tier — "Small foreman of grand projects". Three-bead body,
/// jointed legs, slim antennae.
struct AntIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Legs — six total, three per side.
                ForEach(0..<3) { i in
                    Path { p in
                        let y = CGFloat(90 + i * 14) * s
                        p.move(to: CGPoint(x: 80 * s, y: y))
                        p.addQuadCurve(
                            to: CGPoint(x: 40 * s, y: y + 18 * s),
                            control: CGPoint(x: 60 * s, y: y + 8 * s)
                        )
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1.2 * s)
                    Path { p in
                        let y = CGFloat(90 + i * 14) * s
                        p.move(to: CGPoint(x: 120 * s, y: y))
                        p.addQuadCurve(
                            to: CGPoint(x: 160 * s, y: y + 18 * s),
                            control: CGPoint(x: 140 * s, y: y + 8 * s)
                        )
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1.2 * s)
                }
                // Head
                Ellipse()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 36 * s, height: 30 * s)
                    .offset(y: -52 * s)
                // Thorax
                Ellipse()
                    .fill(CompanionInk.earth)
                    .frame(width: 32 * s, height: 30 * s)
                    .offset(y: -12 * s)
                // Abdomen
                Ellipse()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 48 * s, height: 42 * s)
                    .offset(y: 36 * s)
                // Antennae
                Path { p in
                    p.move(to: CGPoint(x: 92 * s, y: 52 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 70 * s, y: 28 * s),
                        control: CGPoint(x: 78 * s, y: 36 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1.2 * s)
                Path { p in
                    p.move(to: CGPoint(x: 108 * s, y: 52 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 28 * s),
                        control: CGPoint(x: 122 * s, y: 36 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1.2 * s)
                // Eye highlight
                Circle()
                    .fill(CompanionInk.cream.opacity(0.4))
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: 4 * s, y: -56 * s)
            }
        }
    }
}
