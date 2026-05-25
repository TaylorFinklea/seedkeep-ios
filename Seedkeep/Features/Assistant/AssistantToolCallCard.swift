import SwiftUI

/// Inline tool-call card rendered within an assistant message bubble.
/// Renders status (running/done/failed/cancelled/proposed); for proposed
/// destructive ops, shows Confirm/Cancel buttons that surface the
/// Was→Becomes diff. T8 polishes the visuals; this version is functional.
struct AssistantToolCallCard: View {
    let toolCall: LocalAssistantToolCall
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if toolCall.status == "proposed" {
            ProposedChangeCard(toolCall: toolCall, onConfirm: onConfirm, onCancel: onCancel)
        } else {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if toolCall.status == "running" {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1)
            )
        }
    }

    // MARK: - Style helpers

    private var statusIcon: some View {
        Group {
            switch toolCall.status {
            case "running":   Image(systemName: "gear")
            case "done":      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case "failed":    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case "cancelled": Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            default:          Image(systemName: "wrench.and.screwdriver")
            }
        }
        .font(.system(size: 16))
    }

    private var displayTitle: String {
        // Humanize "create_planting_event" → "Create planting event"
        let parts = toolCall.toolName.split(separator: "_").map(String.init)
        guard let first = parts.first else { return toolCall.toolName }
        let rest = parts.dropFirst().joined(separator: " ")
        return rest.isEmpty ? first.capitalized : "\(first.capitalized) \(rest)"
    }

    private var subtitle: String? {
        switch toolCall.status {
        case "running": return "Sprout is running this tool…"
        case "done":    return "Completed"
        case "failed":  return errorSummary(from: toolCall.resultJSON)
        case "cancelled": return "Cancelled"
        default: return nil
        }
    }

    private var borderColor: Color {
        switch toolCall.status {
        case "failed":    return .red.opacity(0.5)
        case "done":      return .green.opacity(0.3)
        case "cancelled": return .gray.opacity(0.3)
        default:          return .gray.opacity(0.2)
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

/// Confirm/Cancel card for a destructive op the LLM has proposed. Shows
/// the action title; T8 will add a Was→Becomes diff renderer.
struct ProposedChangeCard: View {
    let toolCall: LocalAssistantToolCall
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
            }
            if let description = changeDescription {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onConfirm()
                } label: {
                    Text("Confirm")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private var actionTitle: String {
        let parts = toolCall.toolName.split(separator: "_").map(String.init)
        let humanized = parts.joined(separator: " ").capitalized
        return "Confirm: \(humanized)?"
    }

    /// Renders the `description` field of the proposed_change JSON if present.
    /// T8 will expand this with a Was→Becomes diff renderer.
    private var changeDescription: String? {
        guard let json = toolCall.proposedChangeJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["description"] as? String
    }
}
