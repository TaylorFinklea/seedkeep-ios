import SwiftUI
import SwiftData
import PhotosUI
import SeedkeepKit

/// Per-thread chat detail. Renders messages + inline tool-call cards from
/// SwiftData (the coordinator persists each event as it arrives, so the
/// view re-renders give the typewriter UX). Bottom composer sends new
/// messages via AIAssistantCoordinator.send — optionally with a photo
/// attached for "what should I plant here?" prompts (Phase 4 B).
struct AssistantThreadView: View {
    let threadID: String

    @Environment(AppEnvironment.self) private var appEnv

    @Query private var messages: [LocalAssistantMessage]
    @Query private var toolCalls: [LocalAssistantToolCall]

    @State private var composerText: String = ""
    @State private var errorMessage: String?
    @State private var pickedPhotoItem: PhotosPickerItem?
    @State private var pickedPhotoData: Data?

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
        ZStack {
            VellumBackground()
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
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small).tint(HerbColor.sepia)
                                    Text("Sprout is composing…")
                                        .font(HerbFont.bodyItalic(size: 12))
                                        .foregroundStyle(HerbColor.inkSoft)
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
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.rose)
                        .padding(.horizontal)
                }

                Rectangle()
                    .fill(HerbColor.inkFaint)
                    .frame(height: 0.5)

                composer
            }
        }
        .navigationTitle("")
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
        let hasText = !composerText.trimmingCharacters(in: .whitespaces).isEmpty
        let canSend = (hasText || pickedPhotoData != nil) && !isStreaming
        VStack(spacing: 6) {
            if let data = pickedPhotoData, let img = UIImage(data: data) {
                attachmentChip(image: img)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $pickedPhotoItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(HerbColor.sepia)
                }
                .disabled(isStreaming)
                .accessibilityLabel("Attach image")
                TextField("Ask Sprout…", text: $composerText, axis: .vertical)
                    .font(HerbFont.handwritten(size: 17))
                    .lineLimit(1...5)
                    .padding(8)
                    .background(HerbColor.vellumHi)
                    .overlay(
                        Rectangle()
                            .strokeBorder(HerbColor.inkFaint, lineWidth: 0.5)
                    )
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? HerbColor.sepia : HerbColor.inkFaint)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(HerbColor.vellumLo.opacity(0.5))
        .onChange(of: pickedPhotoItem) { _, newItem in
            Task { await loadPickedPhoto(newItem) }
        }
    }

    @ViewBuilder
    private func attachmentChip(image: UIImage) -> some View {
        HStack(spacing: 8) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(.rect(cornerRadius: 4))
                .overlay(Rectangle().strokeBorder(HerbColor.inkFaint, lineWidth: 0.5))
            Text("Photo attached")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
            Spacer()
            Button {
                pickedPhotoData = nil
                pickedPhotoItem = nil
            } label: {
                Text("✗")
                    .font(.system(size: 14))
                    .foregroundStyle(HerbColor.sepia)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var isStreaming: Bool {
        if case .streaming = appEnv.assistant.streamingState { return true }
        return false
    }

    // MARK: - Actions

    private func send() async {
        let text = composerText.trimmingCharacters(in: .whitespaces)
        let attachment = pickedPhotoData.flatMap(Self.makeAttachment)
        // Allow text-empty if there's a photo (vision model can handle
        // image-only prompts, though we'll pad with a default question).
        guard !text.isEmpty || attachment != nil else { return }
        let outgoingText = text.isEmpty ? "What's in this photo? Any planting suggestions?" : text
        composerText = ""
        pickedPhotoData = nil
        pickedPhotoItem = nil
        errorMessage = nil
        do {
            try await appEnv.assistant.send(text: outgoingText, attachment: attachment)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resize + JPEG-encode the picked photo into a payload Anthropic
    /// can handle. ~2048px max dimension, 70% quality. Fits well inside
    /// the server's 4 MB base64 cap.
    private func loadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let raw = try? await item.loadTransferable(type: Data.self) else { return }
        let resized = Self.resizeJPEG(raw, maxDimension: 2048, quality: 0.7) ?? raw
        await MainActor.run {
            pickedPhotoData = resized
        }
    }

    private static func makeAttachment(_ data: Data) -> SeedkeepClient.AssistantImageAttachment {
        SeedkeepClient.AssistantImageAttachment(
            media_type: "image/jpeg",
            data: data.base64EncodedString()
        )
    }

    private static func resizeJPEG(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let longSide = max(size.width, size.height)
        guard longSide > maxDimension else { return image.jpegData(compressionQuality: quality) }
        let scale = maxDimension / longSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return scaled.jpegData(compressionQuality: quality)
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
