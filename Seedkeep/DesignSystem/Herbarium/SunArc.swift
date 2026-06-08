import SwiftUI

/// Sunrise/sunset arc for the Today screen. The sun glyph sits on the
/// arc at the current daylight fraction. Below the arc: sunrise + sunset
/// times. Above (centered): total daylight duration.
///
/// The arc itself is a quadratic bezier, so the sun's y must be computed
/// from the bezier formula — using a sine approximation would float the
/// sun above the actual curve (a real visible bug in early builds).
struct SunArc: View {
    let sunrise: Date
    let sunset: Date
    let now: Date

    /// Fraction of daylight elapsed [0, 1]. Clamped — before sunrise → 0,
    /// after sunset → 1.
    private var progress: Double {
        let totalDay = sunset.timeIntervalSince(sunrise)
        guard totalDay > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(sunrise)
        return min(max(elapsed / totalDay, 0), 1)
    }

    private var totalDaylight: String {
        let total = sunset.timeIntervalSince(sunrise)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let arcInset: CGFloat = 24
            let baselineY = h - 18         // where sunrise / sunset sit
            let apexY: CGFloat = 24        // top of the arc (just below the daylight label)

            // Quadratic bezier control point — chosen so the visible peak
            // of the curve sits at `apexY`. For B(0.5) = 0.5·P0 + 0.5·P2 + 0.5·P1·... wait
            // For a symmetric quad bezier with endpoints at y=baselineY, the
            // visible peak at t=0.5 is (P0.y + P2.y + 2·P1.y) / 4. With
            // P0.y == P2.y == baselineY, peak = (2·baselineY + 2·P1.y) / 4
            // = (baselineY + P1.y) / 2. Solving for P1.y given desired peak:
            // P1.y = 2·peak - baselineY.
            let controlY = 2 * apexY - baselineY
            let p0 = CGPoint(x: arcInset, y: baselineY)
            let p1 = CGPoint(x: w / 2, y: controlY)
            let p2 = CGPoint(x: w - arcInset, y: baselineY)

            ZStack(alignment: .topLeading) {
                // Horizon
                Path { p in
                    p.move(to: CGPoint(x: 0, y: baselineY))
                    p.addLine(to: CGPoint(x: w, y: baselineY))
                }
                .stroke(HerbColor.inkFaint, style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

                // Daylight arc
                Path { p in
                    p.move(to: p0)
                    p.addQuadCurve(to: p2, control: p1)
                }
                .stroke(HerbColor.sepia, lineWidth: 1)

                // Sun glyph — placed on the arc at the bezier coordinate
                let sun = bezierPoint(t: progress, p0: p0, p1: p1, p2: p2)
                sunGlyph
                    .position(x: sun.x, y: sun.y)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeLabel(sunrise))
                        .font(HerbFont.bodyItalic(size: 10))
                        .foregroundStyle(HerbColor.inkSoft)
                    Text("SUNRISE")
                        .font(HerbFont.smallCaps(size: 9))
                        .tracking(1)
                        .foregroundStyle(HerbColor.sepia)
                }
                .padding(.leading, arcInset - 16)
                .padding(.bottom, 0)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(timeLabel(sunset))
                        .font(HerbFont.bodyItalic(size: 10))
                        .foregroundStyle(HerbColor.inkSoft)
                    Text("SUNSET")
                        .font(HerbFont.smallCaps(size: 9))
                        .tracking(1)
                        .foregroundStyle(HerbColor.sepia)
                }
                .padding(.trailing, arcInset - 16)
                .padding(.bottom, 0)
            }
            .overlay(alignment: .top) {
                Text(totalDaylight)
                    .font(HerbFont.smallCaps(size: 9))
                    .tracking(1.5)
                    .foregroundStyle(HerbColor.inkSoft)
                    .padding(.top, 2)
            }
        }
        .frame(height: 110)
    }

    @ViewBuilder
    private var sunGlyph: some View {
        ZStack {
            Circle()
                .fill(HerbColor.ochre)
                .frame(width: 14, height: 14)
            Circle()
                .strokeBorder(HerbColor.sepia, lineWidth: 1)
                .frame(width: 14, height: 14)
        }
    }

    /// Quadratic bezier point evaluation at parameter `t`.
    private func bezierPoint(t: Double, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
        let t = CGFloat(t)
        let oneMinusT = 1 - t
        let x = oneMinusT * oneMinusT * p0.x + 2 * oneMinusT * t * p1.x + t * t * p2.x
        let y = oneMinusT * oneMinusT * p0.y + 2 * oneMinusT * t * p1.y + t * t * p2.y
        return CGPoint(x: x, y: y)
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
