import SwiftUI

/// One message in the assistant thread. Renders the text content and any
/// inline tool-call cards. Herbarium styling — small-caps role tag
/// ("— the gardener" / "Sprout ✦") above each bubble, vellum paper
/// background with a sepia accent on the assistant side.
struct MessageBubble: View {
    let message: LocalAssistantMessage
    let toolCalls: [LocalAssistantToolCall]
    let onConfirmTool: (String) -> Void
    let onCancelTool: (String) -> Void

    var body: some View {
        switch message.role {
        case "user":
            userBubble
        case "assistant":
            assistantBubble
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("— the gardener")
                .font(HerbFont.smallCaps(size: 8))
                .tracking(1.5)
                .foregroundStyle(HerbColor.sepia)
                .textCase(.uppercase)
                .padding(.trailing, 16)
            HStack(alignment: .top) {
                Spacer(minLength: 40)
                Text(textBody)
                    .font(HerbFont.body(size: 13))
                    .foregroundStyle(HerbColor.ink)
                    .padding(10)
                    .frame(maxWidth: 300, alignment: .leading)
                    .background(HerbColor.sage.opacity(0.15))
                    .overlay(
                        Rectangle()
                            .strokeBorder(HerbColor.sage, lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sprout ✦")
                .font(HerbFont.smallCaps(size: 8))
                .tracking(1.5)
                .foregroundStyle(HerbColor.sepia)
                .textCase(.uppercase)
                .padding(.leading, 16)
            VStack(alignment: .leading, spacing: 6) {
                if !textBody.isEmpty {
                    Text(textBody)
                        .font(HerbFont.body(size: 13))
                        .foregroundStyle(HerbColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(HerbColor.vellumHi)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(HerbColor.sepia)
                                .frame(width: 2.5)
                        }
                        .overlay(
                            Rectangle()
                                .strokeBorder(HerbColor.inkFaint, lineWidth: 0.5)
                        )
                }
                ForEach(toolCalls) { call in
                    AssistantToolCallCard(
                        toolCall: call,
                        onConfirm: { onConfirmTool(call.id) },
                        onCancel: { onCancelTool(call.id) }
                    )
                }
            }
        }
        .padding(.horizontal)
    }

    private var textBody: String {
        MessageContent.text(from: message.contentJSON)
    }
}
