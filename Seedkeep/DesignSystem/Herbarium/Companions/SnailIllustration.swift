import SwiftUI

/// Common-tier — "Patient passenger of the leaf-edge". Coiled shell on
/// a smiling slug-like body.
struct SnailIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Body — long oval base
                Capsule()
                    .fill(LinearGradient(
                        colors: [CompanionInk.sepiaLight, CompanionInk.sepia],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 130 * s, height: 32 * s)
                    .offset(y: 36 * s)
                // Shell — coiled
                Circle()
                    .fill(LinearGradient(
                        colors: [CompanionInk.amber, CompanionInk.rust],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 86 * s, height: 86 * s)
                    .offset(x: -16 * s, y: -8 * s)
                // Spiral lines
                ForEach(0..<3) { i in
                    Circle()
                        .strokeBorder(CompanionInk.outline.opacity(0.6), lineWidth: 1 * s)
                        .frame(width: CGFloat(70 - i * 18) * s, height: CGFloat(70 - i * 18) * s)
                        .offset(x: CGFloat(-16 + i * 3) * s, y: CGFloat(-8 + i * 3) * s)
                }
                // Head — front of body
                Circle()
                    .fill(CompanionInk.sepiaLight)
                    .frame(width: 30 * s, height: 30 * s)
                    .offset(x: 56 * s, y: 30 * s)
                // Antennae
                Path { p in
                    p.move(to: CGPoint(x: 154 * s, y: 60 * s))
                    p.addLine(to: CGPoint(x: 160 * s, y: 36 * s))
                }
                .stroke(CompanionInk.sepia, lineWidth: 1.2 * s)
                Path { p in
                    p.move(to: CGPoint(x: 142 * s, y: 62 * s))
                    p.addLine(to: CGPoint(x: 144 * s, y: 38 * s))
                }
                .stroke(CompanionInk.sepia, lineWidth: 1.2 * s)
                // Antennae tips
                Circle().fill(CompanionInk.outline).frame(width: 4 * s, height: 4 * s).offset(x: 60 * s, y: -64 * s)
                Circle().fill(CompanionInk.outline).frame(width: 4 * s, height: 4 * s).offset(x: 44 * s, y: -62 * s)
                // Eye
                Circle().fill(CompanionInk.outline).frame(width: 4 * s, height: 4 * s).offset(x: 56 * s, y: 26 * s)
            }
        }
    }
}
