import SwiftUI

/// A small strip of paper tape, used to "attach" specimen cards to a
/// herbarium sheet. Semi-transparent with a soft drop shadow + slight
/// gradient so it reads as physical tape rather than a colored rect.
struct TapeStrip: View {
    var width: CGFloat = 28
    var height: CGFloat = 10
    var rotation: Double = -8

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        HerbColor.tape.opacity(0.85),
                        HerbColor.tape.opacity(0.65)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: width, height: height)
            .shadow(color: HerbColor.ink.opacity(0.18), radius: 1, x: 0, y: 1)
            .rotationEffect(.degrees(rotation))
    }
}
