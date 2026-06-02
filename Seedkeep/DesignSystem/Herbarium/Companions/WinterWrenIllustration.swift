import SwiftUI

/// Common-tier (winter) — "Small voice insisting the year continues".
/// Tiny brown round bird with raised cocked tail.
struct WinterWrenIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body — small + round
                Circle()
                    .fill(LinearGradient(
                        colors: [CompanionInk.earth, CompanionInk.earthDark],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 84 * s, height: 84 * s)
                    .offset(y: 8 * s)
                // Belly highlight
                Ellipse()
                    .fill(CompanionInk.cream.opacity(0.55))
                    .frame(width: 38 * s, height: 26 * s)
                    .offset(x: -4 * s, y: 26 * s)
                // Head
                Circle()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 46 * s, height: 44 * s)
                    .offset(x: -30 * s, y: -22 * s)
                // Eye + eye stripe
                Path { p in
                    p.move(to: CGPoint(x: 56 * s, y: 78 * s))
                    p.addLine(to: CGPoint(x: 78 * s, y: 84 * s))
                }
                .stroke(CompanionInk.cream.opacity(0.8), lineWidth: 1.4 * s)
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 5 * s, height: 5 * s)
                    .offset(x: -38 * s, y: -22 * s)
                // Beak
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 76 * s))
                    p.addLine(to: CGPoint(x: 36 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 50 * s, y: 84 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.amber)
                // Cocked tail — pointing up
                Path { p in
                    p.move(to: CGPoint(x: 140 * s, y: 100 * s))
                    p.addLine(to: CGPoint(x: 168 * s, y: 60 * s))
                    p.addLine(to: CGPoint(x: 148 * s, y: 60 * s))
                    p.addLine(to: CGPoint(x: 130 * s, y: 100 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.earthDark)
                // Wing barring
                ForEach(0..<3) { i in
                    Path { p in
                        let y = CGFloat(88 + i * 8) * s
                        p.move(to: CGPoint(x: 110 * s, y: y))
                        p.addLine(to: CGPoint(x: 130 * s, y: y))
                    }
                    .stroke(CompanionInk.outline.opacity(0.6), lineWidth: 0.6 * s)
                }
                // Legs
                Path { p in
                    p.move(to: CGPoint(x: 88 * s, y: 138 * s))
                    p.addLine(to: CGPoint(x: 90 * s, y: 154 * s))
                    p.move(to: CGPoint(x: 100 * s, y: 138 * s))
                    p.addLine(to: CGPoint(x: 102 * s, y: 154 * s))
                }
                .stroke(CompanionInk.outlineSoft, lineWidth: 1 * s)
            }
        }
    }
}
