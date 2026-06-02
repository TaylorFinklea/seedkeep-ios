import SwiftUI

/// Uncommon-tier — "Dew-architect of the morning". Round abdomen,
/// eight angled legs, suggestion of web behind.
struct GardenSpiderIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Web hint — radial lines from center
                ForEach(0..<8) { i in
                    Path { p in
                        let a = Double(i) / 8 * .pi * 2
                        let r: Double = 90
                        p.move(to: CGPoint(x: 100 * s, y: 100 * s))
                        p.addLine(to: CGPoint(
                            x: (100 + cos(a) * r) * s,
                            y: (100 + sin(a) * r) * s
                        ))
                    }
                    .stroke(CompanionInk.pale.opacity(0.3), lineWidth: 0.5 * s)
                }
                // Web concentric arcs
                ForEach(1..<4) { ring in
                    Circle()
                        .strokeBorder(CompanionInk.pale.opacity(0.25), lineWidth: 0.5 * s)
                        .frame(width: CGFloat(ring * 40) * s, height: CGFloat(ring * 40) * s)
                }
                // Legs — eight, all radiating
                ForEach(0..<8) { i in
                    let signX: CGFloat = (i % 2 == 0 ? -1 : 1)
                    let row = i / 2
                    let baseY = CGFloat(80 + row * 12) * s
                    Path { p in
                        p.move(to: CGPoint(x: 100 * s, y: baseY))
                        p.addQuadCurve(
                            to: CGPoint(x: (100 + signX * 64) * s, y: baseY + CGFloat(row) * 6 * s - 10 * s),
                            control: CGPoint(x: (100 + signX * 36) * s, y: baseY - 16 * s)
                        )
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1.4 * s)
                }
                // Abdomen
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.amber, CompanionInk.outline],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 50 * s, height: 56 * s)
                    .offset(y: 20 * s)
                // Cross mark on back
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 100 * s))
                    p.addLine(to: CGPoint(x: 100 * s, y: 140 * s))
                    p.move(to: CGPoint(x: 84 * s, y: 120 * s))
                    p.addLine(to: CGPoint(x: 116 * s, y: 120 * s))
                }
                .stroke(CompanionInk.cream, lineWidth: 1.4 * s)
                // Head
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 30 * s, height: 28 * s)
                    .offset(y: -22 * s)
                // Eyes (cluster)
                ForEach(0..<4) { i in
                    Circle()
                        .fill(CompanionInk.cream)
                        .frame(width: 3 * s, height: 3 * s)
                        .offset(
                            x: CGFloat(-6 + (i % 2) * 12) * s,
                            y: CGFloat(-26 + (i / 2) * 4) * s
                        )
                }
            }
        }
    }
}
