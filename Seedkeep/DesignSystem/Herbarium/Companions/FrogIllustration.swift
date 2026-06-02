import SwiftUI

/// Uncommon-tier — "Damp-throated mid-row chorist". Squat green crouch
/// pose with bug-eyes.
struct FrogIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Back legs (squat)
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 70 * s, y: 160 * s),
                        control: CGPoint(x: 30 * s, y: 150 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 60 * s, y: 130 * s),
                        control: CGPoint(x: 56 * s, y: 138 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.leafDark)
                Path { p in
                    p.move(to: CGPoint(x: 150 * s, y: 130 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 160 * s),
                        control: CGPoint(x: 170 * s, y: 150 * s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 140 * s, y: 130 * s),
                        control: CGPoint(x: 144 * s, y: 138 * s)
                    )
                    p.closeSubpath()
                }
                .fill(CompanionInk.leafDark)
                // Body
                Ellipse()
                    .fill(LinearGradient(
                        colors: [CompanionInk.leafLight, CompanionInk.leafDark],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 130 * s, height: 90 * s)
                    .offset(y: 18 * s)
                // Belly
                Ellipse()
                    .fill(CompanionInk.cream.opacity(0.7))
                    .frame(width: 60 * s, height: 30 * s)
                    .offset(y: 50 * s)
                // Mouth line
                Path { p in
                    p.move(to: CGPoint(x: 70 * s, y: 86 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 130 * s, y: 86 * s),
                        control: CGPoint(x: 100 * s, y: 94 * s)
                    )
                }
                .stroke(CompanionInk.outline, lineWidth: 1.5 * s)
                // Eye domes
                Circle()
                    .fill(CompanionInk.leafLight)
                    .frame(width: 36 * s, height: 36 * s)
                    .offset(x: -22 * s, y: -30 * s)
                Circle()
                    .fill(CompanionInk.leafLight)
                    .frame(width: 36 * s, height: 36 * s)
                    .offset(x: 22 * s, y: -30 * s)
                // Eye black + glint
                Circle().fill(CompanionInk.outline).frame(width: 12 * s, height: 12 * s).offset(x: -22 * s, y: -30 * s)
                Circle().fill(CompanionInk.outline).frame(width: 12 * s, height: 12 * s).offset(x: 22 * s, y: -30 * s)
                Circle().fill(CompanionInk.cream).frame(width: 4 * s, height: 4 * s).offset(x: -19 * s, y: -33 * s)
                Circle().fill(CompanionInk.cream).frame(width: 4 * s, height: 4 * s).offset(x: 25 * s, y: -33 * s)
            }
        }
    }
}
