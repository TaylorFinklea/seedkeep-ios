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
                    GardenSpiderRadial(index: i, scale: s)
                }
                // Web concentric arcs
                ForEach(1..<4) { ring in
                    Circle()
                        .strokeBorder(CompanionInk.pale.opacity(0.25), lineWidth: 0.5 * s)
                        .frame(width: CGFloat(ring * 40) * s, height: CGFloat(ring * 40) * s)
                }
                // Legs — eight, all radiating
                ForEach(0..<8) { i in
                    GardenSpiderLeg(index: i, scale: s)
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
                    GardenSpiderEye(index: i, scale: s)
                }
            }
        }
    }
}

/// Single radial line in the web background.
private struct GardenSpiderRadial: View {
    let index: Int
    let scale: CGFloat

    var body: some View {
        let s = scale
        let a = Double(index) / 8 * .pi * 2
        let r: Double = 90
        let endX = (100 + cos(a) * r) * Double(s)
        let endY = (100 + sin(a) * r) * Double(s)
        return Path { p in
            p.move(to: CGPoint(x: 100 * s, y: 100 * s))
            p.addLine(to: CGPoint(x: endX, y: endY))
        }
        .stroke(CompanionInk.pale.opacity(0.3), lineWidth: 0.5 * s)
    }
}

/// Single radiating leg. Extracted into its own view so the
/// type-checker doesn't time out on the parent body.
private struct GardenSpiderLeg: View {
    let index: Int
    let scale: CGFloat

    var body: some View {
        let s = scale
        let signX: CGFloat = (index % 2 == 0 ? -1 : 1)
        let row = index / 2
        let baseY = CGFloat(80 + row * 12) * s
        let endX = (100 + signX * 64) * s
        let endY = baseY + CGFloat(row) * 6 * s - 10 * s
        let ctlX = (100 + signX * 36) * s
        let ctlY = baseY - 16 * s
        return Path { p in
            p.move(to: CGPoint(x: 100 * s, y: baseY))
            p.addQuadCurve(
                to: CGPoint(x: endX, y: endY),
                control: CGPoint(x: ctlX, y: ctlY)
            )
        }
        .stroke(CompanionInk.outline, lineWidth: 1.4 * s)
    }
}

/// Single eye in the head cluster. Extracted to keep parent body type-checkable.
private struct GardenSpiderEye: View {
    let index: Int
    let scale: CGFloat

    var body: some View {
        let s = scale
        let dx = CGFloat(-6 + (index % 2) * 12) * s
        let dy = CGFloat(-26 + (index / 2) * 4) * s
        return Circle()
            .fill(CompanionInk.cream)
            .frame(width: 3 * s, height: 3 * s)
            .offset(x: dx, y: dy)
    }
}
