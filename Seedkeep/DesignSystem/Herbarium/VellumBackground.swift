import SwiftUI

/// The "paper" background of every Herbarium screen. Light radial
/// gradient from vellumHi → vellum → vellumLo plus subtle speckle dots
/// and an inset warm vignette so the surface reads as aged parchment
/// instead of flat color.
///
/// Apply as a background:
/// ```
/// content
///   .background(VellumBackground())
/// ```
struct VellumBackground: View {
    var body: some View {
        ZStack {
            // Base radial gradient — bright at top, deeper at bottom edges.
            RadialGradient(
                colors: [HerbColor.vellumHi, HerbColor.vellum, HerbColor.vellumLo],
                center: .top,
                startRadius: 0,
                endRadius: 700
            )

            // Pseudo-random speckle: small dim dots from a fixed seed so
            // the texture stays stable across renders.
            Canvas { ctx, size in
                var rng = SystemRandomNumberGeneratorSeeded(seed: 1729)
                let speckCount = Int(size.width * size.height / 1800)
                for _ in 0..<speckCount {
                    let x = Double.random(in: 0..<Double(size.width), using: &rng)
                    let y = Double.random(in: 0..<Double(size.height), using: &rng)
                    let r = Double.random(in: 0.4...1.6, using: &rng)
                    let alpha = Double.random(in: 0.04...0.10, using: &rng)
                    let rect = CGRect(x: x - r/2, y: y - r/2, width: r, height: r)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(HerbColor.sepia.opacity(alpha))
                    )
                }
            }
            .allowsHitTesting(false)

            // Warm vignette around the edges.
            RadialGradient(
                colors: [
                    Color.clear,
                    Color.clear,
                    HerbColor.vellumLo.opacity(0.35)
                ],
                center: .center,
                startRadius: 200,
                endRadius: 600
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Deterministic RNG so the speckle pattern is identical every render.
/// Without seeding, `Canvas` re-rolls on every redraw and the texture
/// flickers as you scroll.
private struct SystemRandomNumberGeneratorSeeded: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEAD_BEEF : seed }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}
