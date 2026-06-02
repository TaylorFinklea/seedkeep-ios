import SwiftUI

/// Common-tier — "Pocket-sized auditor of the rows". Plump body, round
/// ears, kink-tipped tail.
struct FieldMouseIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Tail — curling away to the right
                Path { p in
                    p.move(to: CGPoint(x: 140 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 184 * s, y: 100 * s),
                        control: CGPoint(x: 172 * s, y: 134 * s)
                    )
                }
                .stroke(CompanionInk.earth, lineWidth: 1.4 * s)
                // Body — egg-shaped
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.earth, CompanionInk.earthDark],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 96 * s, height: 78 * s)
                    .offset(x: -10 * s, y: 16 * s)
                // Head
                Circle()
                    .fill(CompanionInk.earth)
                    .frame(width: 56 * s, height: 56 * s)
                    .offset(x: -52 * s, y: -10 * s)
                // Ears
                Circle()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 24 * s, height: 24 * s)
                    .offset(x: -70 * s, y: -36 * s)
                Circle()
                    .fill(CompanionInk.earthDark)
                    .frame(width: 24 * s, height: 24 * s)
                    .offset(x: -42 * s, y: -42 * s)
                // Inner ear blush
                Circle()
                    .fill(CompanionInk.pale.opacity(0.7))
                    .frame(width: 10 * s, height: 10 * s)
                    .offset(x: -68 * s, y: -34 * s)
                // Eye
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 6 * s, height: 6 * s)
                    .offset(x: -62 * s, y: -8 * s)
                // Eye glint
                Circle()
                    .fill(CompanionInk.cream)
                    .frame(width: 2 * s, height: 2 * s)
                    .offset(x: -61 * s, y: -10 * s)
                // Nose
                Circle()
                    .fill(CompanionInk.outline)
                    .frame(width: 4 * s, height: 4 * s)
                    .offset(x: -80 * s, y: 0 * s)
                // Whiskers
                Path { p in
                    p.move(to: CGPoint(x: 22 * s, y: 96 * s))
                    p.addLine(to: CGPoint(x: 4 * s, y: 92 * s))
                    p.move(to: CGPoint(x: 22 * s, y: 102 * s))
                    p.addLine(to: CGPoint(x: 4 * s, y: 104 * s))
                }
                .stroke(CompanionInk.outline.opacity(0.6), lineWidth: 0.5 * s)
            }
        }
    }
}
