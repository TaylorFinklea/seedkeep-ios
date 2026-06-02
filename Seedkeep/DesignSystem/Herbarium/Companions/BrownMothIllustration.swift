import SwiftUI

/// Common-tier — "Dusk-loiterer of pale wings". Trapezoid wings spread
/// flat over a fuzzy thorax. Sepia palette, dust-pattern dots.
struct BrownMothIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Wings — left
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 90 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 30 * s, y: 70 * s),
                        control: CGPoint(x: 60 * s, y: 50 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 38 * s, y: 130 * s),
                        control: CGPoint(x: 22 * s, y: 110 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 120 * s),
                        control: CGPoint(x: 72 * s, y: 134 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.sepiaLight, CompanionInk.sepia],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                // Wings — right (mirrored)
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 90 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 170 * s, y: 70 * s),
                        control: CGPoint(x: 140 * s, y: 50 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 162 * s, y: 130 * s),
                        control: CGPoint(x: 178 * s, y: 110 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 120 * s),
                        control: CGPoint(x: 128 * s, y: 134 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.sepiaLight, CompanionInk.sepia],
                    startPoint: .topTrailing, endPoint: .bottomLeading
                ))
                // Wing dust pattern
                ForEach(0..<6) { i in
                    Circle()
                        .fill(CompanionInk.outline.opacity(0.3))
                        .frame(width: 3 * s, height: 3 * s)
                        .offset(
                            x: CGFloat(i.isMultiple(of: 2) ? -40 : 36) * s,
                            y: CGFloat(-8 + (i / 2) * 16) * s
                        )
                }
                // Body — fuzzy ovoid
                Capsule()
                    .fill(CompanionInk.outline)
                    .frame(width: 14 * s, height: 60 * s)
                // Head
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 16 * s, height: 16 * s)
                    .offset(y: -36 * s)
                // Antennae — feathery
                Path { p in
                    p.move(to: CGPoint(x: 96 * s, y: 60 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 78 * s, y: 32 * s),
                        control: CGPoint(x: 84 * s, y: 44 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
                Path { p in
                    p.move(to: CGPoint(x: 104 * s, y: 60 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 122 * s, y: 32 * s),
                        control: CGPoint(x: 116 * s, y: 44 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
            }
        }
    }
}
