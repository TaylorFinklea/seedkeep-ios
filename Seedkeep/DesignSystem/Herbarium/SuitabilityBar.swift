import SwiftUI

/// 60-day suitability strip for the planting window on Seed Detail.
/// Each day cell is shaded sage by suitability — full sage at the peak
/// (now), fading to faint at the edges. Week separators show as tick
/// marks between cells.
struct SuitabilityBar: View {
    /// 60-element array of [0, 1] suitability values (0 = unsuitable,
    /// 1 = peak). If a real recommendation curve isn't available, the
    /// caller can pass `SuitabilityBar.gaussianCurve(peakIndex:width:)`.
    let values: [Double]
    /// Labels evenly distributed beneath the strip (e.g. ["May 23",
    /// "Jun 12", "Jul 02", "Jul 22"]).
    let labels: [String]

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(values.indices, id: \.self) { i in
                        Rectangle()
                            .fill(cellColor(values[i]))
                            .overlay(alignment: .trailing) {
                                if (i + 1) % 7 == 0 && i < values.count - 1 {
                                    Rectangle()
                                        .fill(HerbColor.ink.opacity(0.2))
                                        .frame(width: 0.5)
                                }
                            }
                    }
                }
                .frame(height: geo.size.height)
            }
            .frame(height: 16)

            HStack {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i])
                        .font(HerbFont.smallCaps(size: 8))
                        .tracking(1.2)
                        .foregroundStyle(HerbColor.sepia)
                    if i < labels.count - 1 { Spacer() }
                }
            }
        }
    }

    private func cellColor(_ s: Double) -> Color {
        if s < 0.05 {
            return HerbColor.sepia.opacity(0.18)
        }
        // Map suitability → sage blend: opacity = 0.35 .. 0.9 over the curve
        let alpha = 0.35 + s * 0.55
        return HerbColor.sage.opacity(alpha)
    }

    /// Convenience: a 60-day gaussian curve centered at `peakIndex`. Used
    /// when we don't have a real recommendation distribution yet.
    static func gaussianCurve(peakIndex: Int = 25, width: Double = 16) -> [Double] {
        (0..<60).map { i in
            let d = Double(i - peakIndex) / width
            return max(0, 0.95 * exp(-d * d))
        }
    }
}
