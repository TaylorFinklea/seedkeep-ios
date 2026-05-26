import SwiftUI

/// Hairline divider with a center ◆◇◆ ornament. Used between major
/// page sections — the visual equivalent of a chapter break in a
/// scholarly book.
struct ScholarRule: View {
    var verticalMargin: CGFloat = 8

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(HerbColor.inkFaint)
                .frame(height: 0.5)
            HStack(spacing: 4) {
                Text("◆").font(.system(size: 9))
                Text("◇").font(.system(size: 9))
                Text("◆").font(.system(size: 9))
            }
            .foregroundStyle(HerbColor.sepia)
            Rectangle()
                .fill(HerbColor.inkFaint)
                .frame(height: 0.5)
        }
        .padding(.vertical, verticalMargin)
    }
}
