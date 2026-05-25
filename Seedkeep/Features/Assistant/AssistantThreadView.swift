import SwiftUI
import SwiftData

/// Per-thread chat detail. Renders messages + inline tool-call cards from
/// SwiftData (the coordinator persists each event as it arrives, so the
/// view re-renders give the typewriter UX). Bottom composer sends new
/// messages via AIAssistantCoordinator.send.
struct AssistantThreadView: View {
    let threadID: String

    @Environment(AppEnvironment.self) private var appEnv

    @Query private var messages: [LocalAssistantMessage]
    @Query private var toolCalls: [LocalAssistantToolCall]

    @State private var composerText: String = ""
    @State private var errorMessage: String?

    init(threadID: String) {
        self.threadID = threadID
        let id = threadID
        _messages = Query(
            filter: #Predicate<LocalAssistantMessage> { $0.threadID == id },
            sort: \.createdAt)
        _toolCalls = Query(
            filter: #Predicate<LocalAssistantToolCall> { $0.threadID == id },
            sort: \.createdAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(
                                message: message,
                                toolCalls: toolCalls.filter { $0.messageID == message.id },
                                onConfirmTool: { id in
                                    Task { await confirm(toolCallID: id) }
                                },
                                onCancelTool: { id in
                                    Task { await cancel(toolCallID: id) }
                                }
                            )
                            .id(message.id)
                        }
                        if isStreaming {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Sprout is thinking…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            composer
        }
        .navigationTitle("Sprout")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            appEnv.assistant.openThread(threadID)
            // Pull canonical state from the server so cross-device updates
            // land — also picks up the rows the placeholder-message logic
            // inserted on the server during streaming.
            try? await appEnv.sync.refreshAssistantThread(threadID)
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        let canSend = !composerText.trimmingCharacters(in: .whitespaces).isEmpty && !isStreaming
        HStack(alignment: .bottom) {
            TextField("Ask Sprout…", text: $composerText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var isStreaming: Bool {
        if case .streaming = appEnv.assistant.streamingState { return true }
        return false
    }

    // MARK: - Actions

    private func send() async {
        let text = composerText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        composerText = ""
        errorMessage = nil
        do {
            try await appEnv.assistant.send(text: text)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirm(toolCallID: String) async {
        do { try await appEnv.assistant.confirmToolCall(toolCallID) }
        catch { errorMessage = error.localizedDescription }
    }

    private func cancel(toolCallID: String) async {
        do { try await appEnv.assistant.cancelToolCall(toolCallID) }
        catch { errorMessage = error.localizedDescription }
    }
}
