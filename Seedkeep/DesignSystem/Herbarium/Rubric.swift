import SwiftUI

/// Section heading in scholarly small-caps with an optional Roman numeral
/// prefix ("I. growing info"). Sepia ink, tight letter-spacing.
struct Rubric: View {
    let text: String
    var number: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let n = number {
                Text("\(HerbRomanNumeral.string(for: n)).")
                    .font(HerbFont.bodyItalic(size: 13))
                    .foregroundStyle(HerbColor.sepia)
            }
            Text(text)
                .herbRubricStyle(size: 11, tracking: 2.2)
        }
    }
}
