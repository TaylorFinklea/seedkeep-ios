import SwiftUI

/// Sunrise/sunset arc for the Today screen. The sun glyph sits on the
/// arc at the current daylight fraction. Below the arc are sunrise +
/// sunset times. The total daylight duration sits centered above.
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
            let arcInset: CGFloat = 20
            let arcTopGap: CGFloat = 20

            ZStack(alignment: .topLeading) {
                // Horizon
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 12))
                    p.addLine(to: CGPoint(x: w, y: h - 12))
                }
                .stroke(
                    HerbColor.inkFaint,
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
                )

                // Daylight arc
                Path { p in
                    p.move(to: CGPoint(x: arcInset, y: h - 12))
                    p.addQuadCurve(
                        to: CGPoint(x: w - arcInset, y: h - 12),
                        control: CGPoint(x: w / 2, y: arcTopGap - 15)
                    )
                }
                .stroke(HerbColor.sepia, lineWidth: 1)

                // Hour ticks
                ForEach(0..<12, id: \.self) { i in
                    let t = Double(i) / 11
                    let arcX = arcInset + t * (w - arcInset * 2)
                    let arcY = (h - 12) - sin(t * .pi) * (h - arcTopGap)
                    Circle()
                        .fill(HerbColor.sepiaHi)
                        .frame(width: 2.8, height: 2.8)
                        .offset(x: arcX - 1.4, y: arcY - 1.4)
                }

                // Sun glyph at current position
                let sunX = arcInset + progress * (w - arcInset * 2)
                let sunY = (h - 12) - sin(progress * .pi) * (h - arcTopGap)
                ZStack {
                    Circle()
                        .fill(HerbColor.ochre)
                        .frame(width: 18, height: 18)
                    Circle()
                        .strokeBorder(HerbColor.sepia, lineWidth: 1)
                        .frame(width: 18, height: 18)
                    // Rays — draw via individual capsules positioned by
                    // .offset so they sit around the local center of the
                    // ZStack rather than at the GeometryReader origin.
                    ForEach(0..<8, id: \.self) { i in
                        let a = Double(i) / 8 * .pi * 2
                        Capsule()
                            .fill(HerbColor.ochre)
                            .frame(width: 0.9, height: 4)
                            .offset(x: CGFloat(cos(a)) * 14, y: CGFloat(sin(a)) * 14)
                            .rotationEffect(.degrees(a * 180 / .pi - 90))
                    }
                }
                .frame(width: 32, height: 32)
                .position(x: sunX, y: sunY)
            }
            .overlay(alignment: .topLeading) {
                Text(timeLabel(sunrise))
                    .font(HerbFont.bodyItalic(size: 10))
                    .foregroundStyle(HerbColor.inkSoft)
                    .offset(x: arcInset, y: h - 26)
                Text("SUNRISE")
                    .font(HerbFont.smallCaps(size: 9))
                    .tracking(1)
                    .foregroundStyle(HerbColor.sepia)
                    .offset(x: arcInset, y: h - 10)
            }
            .overlay(alignment: .topTrailing) {
                Text(timeLabel(sunset))
                    .font(HerbFont.bodyItalic(size: 10))
                    .foregroundStyle(HerbColor.inkSoft)
                    .offset(x: -arcInset, y: h - 26)
                Text("SUNSET")
                    .font(HerbFont.smallCaps(size: 9))
                    .tracking(1)
                    .foregroundStyle(HerbColor.sepia)
                    .offset(x: -arcInset, y: h - 10)
            }
            .overlay(alignment: .top) {
                Text(totalDaylight)
                    .font(HerbFont.smallCaps(size: 9))
                    .tracking(1.5)
                    .foregroundStyle(HerbColor.inkSoft)
            }
        }
        .frame(height: 90)
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: date)
    }
}
