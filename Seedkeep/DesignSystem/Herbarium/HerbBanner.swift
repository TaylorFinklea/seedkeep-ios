import SwiftUI

/// Inline informational banner styled to the herbarium canon. Used for
/// inline status messages (permission not granted, prefill applied, sync
/// failure, etc.) that aren't important enough for a modal but need to
/// pull the eye. Color is chosen via severity.
struct HerbBanner: View {
    enum Severity { case info, success, warning, error }

    let severity: Severity
    let title: String
    let message: String?
    let action: (label: String, handler: () -> Void)?

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

    private var tint: Color {
        switch severity {
        case .info: return HerbColor.sepia
        case .success: return HerbColor.sage
        case .warning: return HerbColor.ochre
        case .error: return HerbColor.rose
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(HerbColor.ink)
                if let message {
                    Text(message)
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    Button(action.label, action: action.handler)
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(HerbColor.sepia)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
    }
}
