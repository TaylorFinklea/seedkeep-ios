import SwiftUI

/// Top page-marker strip — small-caps page section name on the left,
/// italic foliation ("fol. xxiii") on the right. Renders just below
/// the safe-area inset on every Herbarium screen.
struct FolioStrip: View {
    let section: String
    let folio: Int

    var body: some View {
        HStack {
            Text(section)
                .herbRubricStyle(size: 10, tracking: 2.0)
            Spacer()
            Text("fol. \(HerbRomanNumeral.folio(folio))")
                .font(HerbFont.bodyItalic(size: 11))
                .foregroundStyle(HerbColor.inkSoft)
                .tracking(1)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}
