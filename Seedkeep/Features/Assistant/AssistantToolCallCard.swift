import SwiftUI

/// Inline tool-call card rendered within an assistant message bubble.
/// Renders status (running/done/failed/cancelled/proposed). The proposed
/// variant pops a confirm/cancel card with a Was→Becomes description.
///
/// Herbarium chrome: flat vellum surface, small-caps status pill, sepia
/// accent stripe. No SF Symbol noise — single glyph + colored stripe is
/// the visual language.
struct AssistantToolCallCard: View {
    let toolCall: LocalAssistantToolCall
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if toolCall.status == "proposed" {
            ProposedChangeCard(toolCall: toolCall, onConfirm: onConfirm, onCancel: onCancel)
        } else {
            HStack(alignment: .center, spacing: 10) {
                statusGlyph
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(displayTitle)
                            .font(HerbFont.smallCaps(size: 10))
                            .tracking(1.4)
                            .foregroundStyle(HerbColor.ink)
                            .textCase(.uppercase)
                        statusPill
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(HerbFont.bodyItalic(size: 11))
                            .foregroundStyle(HerbColor.inkSoft)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if toolCall.status == "running" {
                    ProgressView().controlSize(.small).tint(HerbColor.sepia)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(HerbColor.vellumHi)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(stripeColor)
                    .frame(width: 2.5)
            }
            .overlay(
                Rectangle().strokeBorder(HerbColor.inkFaint, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Style

    @ViewBuilder
    private var statusGlyph: some View {
        switch toolCall.status {
        case "running":
            Text("⟳")
                .font(HerbFont.smallCaps(size: 13))
                .foregroundStyle(HerbColor.ochre)
        case "done":
            Text("✓")
                .font(HerbFont.smallCaps(size: 13))
                .foregroundStyle(HerbColor.verdictNow)
        case "failed":
            Text("✗")
                .font(HerbFont.smallCaps(size: 13))
                .foregroundStyle(HerbColor.rose)
        case "cancelled":
            Text("—")
                .font(HerbFont.smallCaps(size: 13))
                .foregroundStyle(HerbColor.inkFaint)
        default:
            Text("◇")
                .font(HerbFont.smallCaps(size: 13))
                .foregroundStyle(HerbColor.sepia)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        Text(statusLabel)
            .font(HerbFont.smallCaps(size: 8))
            .tracking(1.2)
            .foregroundStyle(stripeColor)
            .textCase(.uppercase)
    }

    private var statusLabel: String {
        switch toolCall.status {
        case "running":   return "running"
        case "done":      return "completed"
        case "failed":    return "failed"
        case "cancelled": return "cancelled"
        default:          return toolCall.status
        }
    }

    private var stripeColor: Color {
        switch toolCall.status {
        case "running":   return HerbColor.ochre
        case "done":      return HerbColor.verdictNow
        case "failed":    return HerbColor.rose
        case "cancelled": return HerbColor.inkFaint
        default:          return HerbColor.sepia
        }
    }

    private var displayTitle: String {
        // Humanize "create_planting_event" → "Create planting event"
        toolCall.toolName.split(separator: "_").joined(separator: " ")
    }

    private var subtitle: String? {
        switch toolCall.status {
        case "failed":    return errorSummary(from: toolCall.resultJSON)
        default:          return nil
        }
    }

    private func errorSummary(from json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["message"] as? String {
            return msg
        }
        return nil
    }
}

/// Confirm/Cancel card for a destructive op the LLM has proposed.
/// Ochre-bordered "Confirm change" header + bulleted description + two
/// liquid-glass action buttons (Cancel outline + Confirm sepia primary).
struct ProposedChangeCard: View {
    let toolCall: LocalAssistantToolCall
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("⚠")
                    .font(.system(size: 14))
                    .foregroundStyle(HerbColor.ochre)
                Text("Confirm change · \(actionTitle)")
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.5)
                    .foregroundStyle(HerbColor.ink)
                    .textCase(.uppercase)
            }
            if let description = changeDescription {
                Text(description)
                    .font(HerbFont.body(size: 13))
                    .foregroundStyle(HerbColor.ink)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(HerbColor.ochre)
                            .frame(width: 2)
                    }
            }
            HStack(spacing: 10) {
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: confirmRole) {
                    onConfirm()
                } label: {
                    Text("Confirm")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HerbColor.sage)
            }
        }
        .padding(12)
        .background(HerbColor.ochre.opacity(0.08))
        .overlay(
            Rectangle().strokeBorder(HerbColor.ochre.opacity(0.7), lineWidth: 1)
        )
    }

    private var actionTitle: String {
        toolCall.toolName.split(separator: "_").joined(separator: " ")
    }

    /// `.destructive` only for delete_* tools; otherwise neutral.
    /// Keeps Cancel as the safe `role: .cancel` next to it (see body).
    private var confirmRole: ButtonRole? {
        toolCall.toolName.hasPrefix("delete_") ? .destructive : nil
    }

    /// Renders the `description` field of the proposed_change JSON if present.
    private var changeDescription: String? {
        guard let json = toolCall.proposedChangeJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["description"] as? String
    }
}
