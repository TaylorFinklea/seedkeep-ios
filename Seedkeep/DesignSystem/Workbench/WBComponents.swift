// Workbench components (R2a). They replace the Herbarium chrome: Rubric, HerbBanner, VellumBackground,
// VellumForm, SunArc and HerbProgressStyle. Text uses `ink` or `muted`; status colour marks icons,
// dots and bars only. Text sizes come from `Font.wb*`, so Dynamic Type scales them.
import SwiftUI

/// Section label: capitals in `muted`, a header for VoiceOver. Replaces `Rubric`.
struct WBSectionHeader: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.wbSectionLabel)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(WBColor.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A screen's large title and optional subtitle, inset on `WBMetrics.screenGutter`.
struct WBScreenTitle: View {
    private let title: String
    private let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.wbLargeTitle)
                .foregroundStyle(WBColor.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WBMetrics.screenGutter)
    }
}

/// Inline status message. Drop-in for `HerbBanner`: same initializer.
struct WBBanner: View {
    enum Severity { case info, success, warning, error }

    let severity: Severity
    let title: String
    let message: String?
    let action: (label: String, handler: () -> Void)?

    @ScaledMetric private var iconSize: CGFloat = 16

    init(
        severity: Severity,
        title: String,
        message: String? = nil,
        action: (label: String, handler: () -> Void)? = nil
    ) {
        self.severity = severity
        self.title = title
        self.message = message
        self.action = action
    }

    private var iconName: String {
        switch severity {
        case .info: return "info.circle"
        case .success: return "checkmark.seal"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    /// Icon colour only. The text is always `ink` or `muted`.
    private var tint: Color {
        switch severity {
        case .info, .success: return WBColor.accent
        case .warning, .error: return WBColor.warn
        }
    }

    private var background: Color {
        switch severity {
        case .info, .success: return WBColor.accentSoft
        case .warning, .error: return WBColor.warnSoft
        }
    }

    /// Severity is spoken with the text, since colour alone does not carry it.
    private var spokenSummary: String {
        let prefix: String
        switch severity {
        case .info: prefix = "Information"
        case .success: prefix = "Success"
        case .warning: prefix = "Warning"
        case .error: prefix = "Error"
        }
        return [prefix, title, message].compactMap { $0 }.joined(separator: ". ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: WBMetrics.gap) {
            Image(systemName: iconName)
                .font(.system(size: iconSize))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.wbCallout.weight(.semibold))
                        .foregroundStyle(WBColor.ink)
                    if let message {
                        Text(message)
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spokenSummary)
                if let action {
                    // The minimum frame and the hit shape sit inside the label, so the whole target grows.
                    Button(action: action.handler) {
                        Text(action.label)
                            .font(.wbCallout.weight(.semibold))
                            .foregroundStyle(WBColor.accent)
                            .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(background, in: RoundedRectangle(cornerRadius: WBMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: WBMetrics.radiusControl)
                .strokeBorder(WBColor.line, lineWidth: 1)
        )
    }
}

/// Status or verdict chip. The text carries the meaning; the dot only adds colour.
struct WBStatusChip: View {
    enum Tone: Equatable {
        case neutral
        case accent
        case warn
        /// A planting-window verdict. The raw value is `LocalRecommendation.verdict`.
        case verdict(String)
    }

    let text: String
    let tone: Tone
    // Scaled with the text, so a chip that wraps at large sizes keeps its words clear of the
    // capsule's curved ends.
    @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 7
    @ScaledMetric(relativeTo: .caption) private var horizontalPadding: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var verticalPadding: CGFloat = 4

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    /// What VoiceOver reads. A warning says so in words, so the tone is never colour-only.
    var accessibilityText: String {
        switch tone {
        case .warn: return "Warning: \(text)"
        case .neutral, .accent, .verdict: return text
        }
    }

    private var dot: Color {
        switch tone {
        case .neutral: return WBColor.faint
        case .accent: return WBColor.accent
        case .warn: return WBColor.warn
        case .verdict(let raw): return WBColor.verdict(raw)
        }
    }

    private var background: Color {
        switch tone {
        case .neutral, .verdict: return WBColor.panel2
        case .accent: return WBColor.accentSoft
        case .warn: return WBColor.warnSoft
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: dotSize, height: dotSize)
                .accessibilityHidden(true)
            Text(text)
                .font(.wbCaption.weight(.semibold))
                .foregroundStyle(WBColor.ink)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(background, in: Capsule())
        .overlay(Capsule().strokeBorder(WBColor.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

/// Empty state in Workbench style. Replaces `ContentUnavailableView` at the call sites.
struct WBEmptyState: View {
    let title: String
    let message: String?
    let systemImage: String
    let action: (label: String, handler: () -> Void)?

    @ScaledMetric private var iconSize: CGFloat = 36

    init(
        title: String,
        message: String? = nil,
        systemImage: String,
        action: (label: String, handler: () -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        VStack(spacing: WBMetrics.gapLarge) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize))
                .foregroundStyle(WBColor.muted)
                .accessibilityHidden(true)
            VStack(spacing: WBMetrics.gap) {
                Text(title)
                    .font(.wbHeadline)
                    .foregroundStyle(WBColor.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.wbCallout)
                        .foregroundStyle(WBColor.muted)
                        .multilineTextAlignment(.center)
                }
            }
            if let action {
                // The minimum frame and the hit shape sit inside the label, so the whole target grows.
                Button(action: action.handler) {
                    Text(action.label)
                        .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .tint(WBColor.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// Sunrise, sunset and day length, with a bar for how much of the day has passed. Replaces `SunArc`.
/// The text comes first, and VoiceOver hears one summary.
struct WBDaylightPanel: View {
    let sunrise: Date
    let sunset: Date
    let now: Date

    init(sunrise: Date, sunset: Date, now: Date) {
        self.sunrise = sunrise
        self.sunset = sunset
        self.now = now
    }

    /// Fraction of daylight elapsed, clamped to 0...1: zero before sunrise, one after sunset.
    private var progress: Double {
        let total = sunset.timeIntervalSince(sunrise)
        guard total > 0 else { return 0 }
        return min(max(now.timeIntervalSince(sunrise) / total, 0), 1)
    }

    private var dayLength: (hours: Int, minutes: Int) {
        let total = max(Int(sunset.timeIntervalSince(sunrise)), 0)
        return (total / 3600, (total % 3600) / 60)
    }

    private var summary: String {
        let length = dayLength
        let percent = Int((progress * 100).rounded())
        return "Daylight: sunrise \(time(sunrise)), sunset \(time(sunset)), "
            + "\(length.hours) hours \(length.minutes) minutes. "
            + "\(percent) percent of daylight has passed."
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WBMetrics.gap) {
            HStack(alignment: .top, spacing: WBMetrics.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sunrise")
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                    Text(time(sunrise))
                        .font(.wbMono)
                        .foregroundStyle(WBColor.ink)
                }
                Spacer(minLength: WBMetrics.gap)
                VStack(spacing: 2) {
                    Text("Day length")
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                    Text("\(dayLength.hours)h \(dayLength.minutes)m")
                        .font(.wbMono)
                        .foregroundStyle(WBColor.ink)
                }
                Spacer(minLength: WBMetrics.gap)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Sunset")
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                    Text(time(sunset))
                        .font(.wbMono)
                        .foregroundStyle(WBColor.ink)
                }
            }
            ProgressView(value: progress)
                .progressViewStyle(.wb)
        }
        .wbPanel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }
}

/// The Workbench page background: `bg`, under the safe area too. Replaces `VellumBackground`.
struct WBScreenBackground: View {
    var body: some View {
        WBColor.bg.ignoresSafeArea()
    }
}

extension View {
    /// A Workbench panel: `panel` fill, `line` border, panel corner radius.
    func wbPanel(padding: CGFloat = WBMetrics.gapLarge) -> some View {
        self
            .padding(padding)
            .background(WBColor.panel, in: RoundedRectangle(cornerRadius: WBMetrics.radiusPanel))
            .overlay(
                RoundedRectangle(cornerRadius: WBMetrics.radiusPanel)
                    .strokeBorder(WBColor.line, lineWidth: 1)
            )
    }

    /// A Form or List on the Workbench background. Rows keep the system grouped style. Replaces
    /// `.vellumForm()`.
    func wbForm() -> some View {
        ZStack {
            WBScreenBackground()
            self.scrollContentBackground(.hidden)
        }
    }
}

/// Linear progress: an `accent` fill on a `line` track. Use it for determinate bars only. An
/// indeterminate ProgressView keeps the system style.
struct WBProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        let fraction = configuration.fractionCompleted ?? 0
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(WBColor.line)
                Capsule()
                    .fill(WBColor.accent)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
    }
}

extension ProgressViewStyle where Self == WBProgressStyle {
    static var wb: WBProgressStyle { WBProgressStyle() }
}
