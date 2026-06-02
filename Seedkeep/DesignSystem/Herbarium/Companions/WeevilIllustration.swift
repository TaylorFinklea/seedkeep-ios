import SwiftUI

/// Common-tier — "Long-snouted philosopher of grain". Bulbous abdomen
/// + signature elongated snout.
struct WeevilIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Legs
                ForEach(0..<3) { i in
                    let y = CGFloat(110 + i * 14) * s
                    Path { p in
                        p.move(to: CGPoint(x: 84 * s, y: y))
                        p.addLine(to: CGPoint(x: 50 * s, y: y + 12 * s))
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1 * s)
                    Path { p in
                        p.move(to: CGPoint(x: 116 * s, y: y))
                        p.addLine(to: CGPoint(x: 150 * s, y: y + 12 * s))
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1 * s)
                }
                // Body — rounded teardrop
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 70 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 130 * s),
                        control: CGPoint(x: 56 * s, y: 90 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 130 * s),
                        control: CGPoint(x: 100 * s, y: 160 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 70 * s),
                        control: CGPoint(x: 144 * s, y: 90 * s)
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.earth, CompanionInk.earthDark],
                    startPoint: .top, endPoint: .bottom
                ))
                // Body central ridge
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 100 * s, y: 140 * s))
                }
                .stroke(CompanionInk.outline.opacity(0.5), lineWidth: 0.6 * s)
                // Head
                Circle()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 28 * s, height: 24 * s)
                    .offset(y: -38 * s)
                // Long snout (signature)
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 56 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 86 * s, y: 12 * s),
                        control: CGPoint(x: 96 * s, y: 30 * s)
                    )
                }
                .stroke(CompanionInk.outline, style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
                // Antennae on snout
                Path { p in
                    p.move(to: CGPoint(x: 92 * s, y: 24 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 76 * s, y: 10 * s),
                        control: CGPoint(x: 80 * s, y: 16 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 0.8 * s)
                // Eyes
                Circle().fill(CompanionInk.cream).frame(width: 4 * s, height: 4 * s).offset(x: -6 * s, y: -38 * s)
                Circle().fill(CompanionInk.cream).frame(width: 4 * s, height: 4 * s).offset(x: 6 * s, y: -38 * s)
            }
        }
    }
}
