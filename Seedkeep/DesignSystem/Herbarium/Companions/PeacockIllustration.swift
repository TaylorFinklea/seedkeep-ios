import SwiftUI

/// Legendary-tier — "Walking iconography, prone to gossip". Display
/// pose with fanned tail of eye-spots.
struct PeacockIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Fan tail — large half-circle background
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 130 * s))
                    p.addArc(
                        center: CGPoint(x: 100 * s, y: 130 * s),
                        radius: 96 * s,
                        startAngle: .degrees(200),
                        endAngle: .degrees(340),
                        clockwise: false
                    )
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [CompanionInk.teal, CompanionInk.leafDark],
                    startPoint: .top, endPoint: .bottom
                ))
                // Eye-spots radiating
                ForEach(0..<9) { i in
                    let a = Double(i) / 8 * (.pi * 0.78) + .pi + 0.12
                    let r: Double = 76
                    let x = (100 + cos(a) * r) * Double(s)
                    let y = (130 + sin(a) * r) * Double(s)
                    Circle()
                        .fill(CompanionInk.amber)
                        .frame(width: 16 * s, height: 16 * s)
                        .offset(x: CGFloat(x) - 100 * s, y: CGFloat(y) - 100 * s)
                    Circle()
                        .fill(CompanionInk.outline)
                        .frame(width: 8 * s, height: 8 * s)
                        .offset(x: CGFloat(x) - 100 * s, y: CGFloat(y) - 100 * s)
                    Circle()
                        .fill(CompanionInk.cream)
                        .frame(width: 2 * s, height: 2 * s)
                        .offset(x: CGFloat(x) - 100 * s - 2 * s, y: CGFloat(y) - 100 * s - 2 * s)
                }
                // Body
                Ellipse()
                    .fill(CompanionInk.teal)
                    .frame(width: 44 * s, height: 64 * s)
                    .offset(y: 30 * s)
                // Long neck
                Path { p in
                    p.move(to: CGPoint(x: 96 * s, y: 110 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 100 * s, y: 60 * s),
                        control: CGPoint(x: 84 * s, y: 80 * s)
                    )
                }
                .stroke(CompanionInk.teal, style: StrokeStyle(lineWidth: 10 * s, lineCap: .round))
                // Head
                Circle()
                    .fill(CompanionInk.teal)
                    .frame(width: 20 * s, height: 22 * s)
                    .offset(x: 0 * s, y: -42 * s)
                // Crest — three little feathers
                ForEach(0..<3) { i in
                    Path { p in
                        let x = CGFloat(94 + i * 6) * s
                        p.move(to: CGPoint(x: x, y: 50 * s))
                        p.addLine(to: CGPoint(x: x + 1 * s, y: 30 * s))
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1 * s)
                    Circle()
                        .fill(CompanionInk.teal)
                        .frame(width: 5 * s, height: 5 * s)
                        .offset(x: CGFloat(-6 + i * 6) * s, y: -74 * s)
                }
                // Beak + eye
                Path { p in
                    p.move(to: CGPoint(x: 102 * s, y: 58 * s))
                    p.addLine(to: CGPoint(x: 112 * s, y: 60 * s))
                    p.addLine(to: CGPoint(x: 102 * s, y: 62 * s))
                    p.closeSubpath()
                }
                .fill(CompanionInk.amber)
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 3 * s, height: 3 * s)
                    .offset(x: -1 * s, y: -44 * s)
                // Legs
                Path { p in
                    p.move(to: CGPoint(x: 90 * s, y: 156 * s))
                    p.addLine(to: CGPoint(x: 86 * s, y: 184 * s))
                    p.move(to: CGPoint(x: 110 * s, y: 156 * s))
                    p.addLine(to: CGPoint(x: 114 * s, y: 184 * s))
                }
                .stroke(CompanionInk.amber, lineWidth: 1.4 * s)
            }
        }
    }
}
