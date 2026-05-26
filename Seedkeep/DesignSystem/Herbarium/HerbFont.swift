import SwiftUI

/// Typography tokens for the Herbarium design system. Three families:
///
/// - **Spectral** — body serif. Light / regular / medium with italic
///   variants. Big italic light is the display style.
/// - **IM Fell English SC** — small-caps display for rubrics, folio
///   markers, tab labels.
/// - **Caveat** — handwritten cursive for margin notes + chat composer
///   placeholder.
///
/// Fonts are bundled via `UIAppFonts` in `project.yml`. PostScript names
/// (used in `.custom`) are intentionally exact — if they don't resolve,
/// iOS silently falls back to the system serif and the design loses its
/// identity, so we centralize the strings here.
enum HerbFont {

    // MARK: - Spectral (body serif)

    static func display(size: CGFloat) -> Font {
        .custom("Spectral-LightItalic", size: size)
    }

    static func displayUpright(size: CGFloat) -> Font {
        .custom("Spectral-Light", size: size)
    }

    static func body(size: CGFloat = 14) -> Font {
        .custom("Spectral-Regular", size: size)
    }

    static func bodyItalic(size: CGFloat = 14) -> Font {
        .custom("Spectral-Italic", size: size)
    }

    static func bodyEmph(size: CGFloat = 14) -> Font {
        .custom("Spectral-Medium", size: size)
    }

    // MARK: - IM Fell English SC (small-caps)

    /// Small-caps rubrics, folio markers, tab labels. The PostScript name
    /// has UNDERSCORES — `IM_FELL_English_SC` — not what the filename
    /// suggests. Letter-spacing is applied at the call-site via `.tracking()`.
    static func smallCaps(size: CGFloat = 10) -> Font {
        .custom("IM_FELL_English_SC", size: size)
    }

    // MARK: - Caveat (handwritten, variable font)

    /// Caveat ships as a single variable-weight TTF. The PostScript name
    /// is `Caveat-Regular`; heavier weights come from `.weight()`.
    static func handwritten(size: CGFloat = 16) -> Font {
        .custom("Caveat-Regular", size: size)
    }

    static func handwrittenEmph(size: CGFloat = 16) -> Font {
        .custom("Caveat-Regular", size: size).weight(.medium)
    }
}

// MARK: - Convenience modifiers

extension View {
    /// Apply a small-caps rubric style: sepia ink, tight letter-spacing,
    /// uppercase. Caller is responsible for the actual `Text` content
    /// (use `.textCase(.uppercase)` or pre-uppercased strings).
    func herbRubricStyle(size: CGFloat = 11, tracking: CGFloat = 2.2) -> some View {
        self
            .font(HerbFont.smallCaps(size: size))
            .tracking(tracking)
            .foregroundStyle(HerbColor.sepia)
            .textCase(.uppercase)
    }

    /// Italic display heading. Caller picks size for the contextual scale
    /// (e.g. 42 for "Pressed specimens", 32 for seed-detail name).
    func herbDisplayStyle(size: CGFloat) -> some View {
        self
            .font(HerbFont.display(size: size))
            .foregroundStyle(HerbColor.ink)
            .lineSpacing(0)
    }

    /// Body italic for binomials + scientific names + "fol. xxiii" type
    /// secondary lines.
    func herbItalicStyle(size: CGFloat = 12) -> some View {
        self
            .font(HerbFont.bodyItalic(size: size))
            .foregroundStyle(HerbColor.inkSoft)
    }

    /// Caveat handwriting for margin notes.
    func herbHandwrittenStyle(size: CGFloat = 16, color: Color = HerbColor.sepia) -> some View {
        self
            .font(HerbFont.handwritten(size: size))
            .foregroundStyle(color)
    }
}
