import SwiftUI

/// N2-E (G2): shown in every window while the bound garden is gone and waits for the user's choice.
/// It is a placeholder: G3 replaces it with the choice (keep a copy as a new garden, or discard this
/// copy). Nothing is written into the gone garden, and nothing here can be.
struct GardenGonePlaceholderView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 36

    /// The words of the placeholder (tests pin them).
    static let title = "This garden is no longer in iCloud"
    static let message = "Your seeds, beds and journal are still on this device. Nothing more is sent to this garden while Seedkeep waits for a decision about it."

    var body: some View {
        ScrollView {
            VStack(spacing: WBMetrics.gapLarge) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: symbolSize))
                    .foregroundStyle(WBColor.muted)
                    .accessibilityHidden(true)
                Text(Self.title)
                    .font(.wbTitle)
                    .foregroundStyle(WBColor.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.message)
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WBScreenBackground() }
        .accessibilityIdentifier("screen.gardenGone")
    }
}
