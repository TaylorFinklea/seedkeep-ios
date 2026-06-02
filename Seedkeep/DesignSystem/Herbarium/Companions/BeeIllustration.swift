import SwiftUI

/// Uncommon-tier — "Pollen-dusted diligent". Striped abdomen, wings
/// out, leg pollen bundles.
struct BeeIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Wings — pale translucent
                Ellipse()
                    .fill(CompanionInk.cream.opacity(0.55))
                    .frame(width: 60 * s, height: 38 * s)
                    .rotationEffect(.degrees(-20))
                    .offset(x: -10 * s, y: -10 * s)
                Ellipse()
                    .fill(CompanionInk.cream.opacity(0.55))
                    .frame(width: 60 * s, height: 38 * s)
                    .rotationEffect(.degrees(20))
                    .offset(x: 14 * s, y: -10 * s)
                // Body — abdomen
                Ellipse()
                    .fill(CompanionInk.amber)
                    .frame(width: 96 * s, height: 72 * s)
                    .offset(y: 24 * s)
                // Stripes
                ForEach(0..<3) { i in
                    Path { p in
                        let cy = CGFloat(108 + i * 12) * s
                        p.move(to: CGPoint(x: 60 * s, y: cy))
                        p.addQuadCurve(
                            to: CGPoint(x: 140 * s, y: cy),
                            control: CGPoint(x: 100 * s, y: cy + 3 * s)
                        )
                    }
                    .stroke(CompanionInk.outline, lineWidth: 5 * s)
                }
                // Head
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 44 * s, height: 40 * s)
                    .offset(y: -42 * s)
                // Eyes
                Ellipse()
                    .fill(CompanionInk.amber)
                    .frame(width: 12 * s, height: 16 * s)
                    .offset(x: -10 * s, y: -44 * s)
                Ellipse()
                    .fill(CompanionInk.amber)
                    .frame(width: 12 * s, height: 16 * s)
                    .offset(x: 10 * s, y: -44 * s)
                // Antennae
                Path { p in
                    p.move(to: CGPoint(x: 90 * s, y: 42 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 76 * s, y: 22 * s),
                        control: CGPoint(x: 82 * s, y: 30 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
                Path { p in
                    p.move(to: CGPoint(x: 110 * s, y: 42 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 124 * s, y: 22 * s),
                        control: CGPoint(x: 118 * s, y: 30 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1 * s)
                // Pollen bundles on hind legs
                Circle()
                    .fill(CompanionInk.amber)
                    .frame(width: 10 * s, height: 10 * s)
                    .offset(x: -36 * s, y: 50 * s)
            }
        }
    }
}
