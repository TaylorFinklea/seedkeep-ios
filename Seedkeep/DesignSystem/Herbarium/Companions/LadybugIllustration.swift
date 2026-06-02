import SwiftUI

/// Common-tier — "Auspicious red speck on a stem". Round dome with
/// black spots + midline split.
struct LadybugIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Legs
                ForEach(0..<3) { i in
                    let y = CGFloat(80 + i * 20) * s
                    Path { p in
                        p.move(to: CGPoint(x: 80 * s, y: y))
                        p.addLine(to: CGPoint(x: 50 * s, y: y + 10 * s))
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1 * s)
                    Path { p in
                        p.move(to: CGPoint(x: 120 * s, y: y))
                        p.addLine(to: CGPoint(x: 150 * s, y: y + 10 * s))
                    }
                    .stroke(CompanionInk.outline, lineWidth: 1 * s)
                }
                // Body — round red dome
                Circle()
                    .fill(LinearGradient(
                        colors: [CompanionInk.red, Color(red: 0.42, green: 0.12, blue: 0.08)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 96 * s, height: 96 * s)
                    .offset(y: 4 * s)
                // Midline split
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 56 * s))
                    p.addLine(to: CGPoint(x: 100 * s, y: 148 * s))
                }
                .stroke(CompanionInk.outline, lineWidth: 1.2 * s)
                // Spots
                ForEach(0..<6) { i in
                    let isLeft = i % 2 == 0
                    let row = i / 2
                    Circle()
                        .fill(CompanionInk.outline)
                        .frame(width: 14 * s, height: 14 * s)
                        .offset(
                            x: CGFloat(isLeft ? -22 : 22) * s,
                            y: CGFloat(-12 + row * 26) * s
                        )
                }
                // Head — black hemisphere on top
                Path { p in
                    p.addEllipse(in: CGRect(x: 76 * s, y: 36 * s, width: 48 * s, height: 36 * s))
                }
                .fill(CompanionInk.outline)
                // Eyes
                Circle().fill(CompanionInk.cream).frame(width: 6 * s, height: 6 * s).offset(x: -10 * s, y: -42 * s)
                Circle().fill(CompanionInk.cream).frame(width: 6 * s, height: 6 * s).offset(x: 10 * s, y: -42 * s)
            }
        }
    }
}
