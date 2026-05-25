import SwiftUI

/// One message in the assistant thread. Renders text content + any tool
/// calls that belong to this message inline (cards land in T8 — this file
/// renders a simple placeholder for now).
struct MessageBubble: View {
    let message: LocalAssistantMessage
    let toolCalls: [LocalAssistantToolCall]
    let onConfirmTool: (String) -> Void
    let onCancelTool: (String) -> Void

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 60)
                Text(textBody)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 12))
            }
            .padding(.horizontal)

        case "assistant":
            VStack(alignment: .leading, spacing: 6) {
                if !textBody.isEmpty {
                    Text(textBody)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(toolCalls) { call in
                    AssistantToolCallCard(
                        toolCall: call,
                        onConfirm: { onConfirmTool(call.id) },
                        onCancel: { onCancelTool(call.id) }
                    )
                }
            }
            .padding(.horizontal)

        default:
            // Tool-result + system messages are not surfaced; their content
            // is reflected in tool-call cards already.
            EmptyView()
        }
    }

    private var textBody: String {
        MessageContent.text(from: message.contentJSON)
    }
}
