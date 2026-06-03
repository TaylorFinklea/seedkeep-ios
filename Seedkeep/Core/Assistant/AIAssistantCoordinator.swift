import Foundation
import SwiftData
import SeedkeepKit

/// Sprout's runtime state machine. Owns the live conversation (which thread
/// is open, what's streaming, what's awaiting confirmation), the page-context
/// bus (so the global sparkle button can capture the user's current view),
/// and the BYOK key-configured flag.
///
/// The actual API key is never stored locally — `keyConfigured` reflects the
/// server's GET /assistant_key response. Settings UI either prompts for a
/// fresh key or shows "configured / replace / revoke" based on this flag.
@MainActor
@Observable
final class AIAssistantCoordinator {
    private let client: SeedkeepClient
    private let container: ModelContainer
    private(set) var sync: SyncEngine?

    // ── Public state observed by SwiftUI views ─────────────────────────────

    var currentThreadID: String?
    private(set) var streamingState: StreamingState = .idle
    private(set) var lastError: String?

    /// Drives the global popup-sheet overlay. The bottom-right SproutFAB
    /// flips this to true after creating/reusing a thread with the current
    /// pageContext attached; the overlay (mounted once at the root) presents
    /// a sheet with detents and drag-to-dismiss. The dedicated Sprout tab
    /// remains for browsing past threads.
    var isSheetPresented: Bool = false

    /// What the user is currently looking at. Pages publish via the
    /// PageContextPublisher view modifier (T9); the sparkle button reads
    /// this when launching a new thread.
    var pageContext: AIPageContext?

    /// Has the user configured an API key on the server? Drives the Settings
    /// UI + the Assistant tab's empty-state vs starter-prompts branch.
    private(set) var keyConfigured: Bool = false
    private(set) var keyCheckError: String?

    enum StreamingState: Equatable {
        case idle
        case streaming(messageID: String)
        case awaitingConfirmation(toolCallID: String)
        case error(String)
    }

    struct AIPageContext: Equatable, Hashable {
        let pageType: String          // 'seed' | 'bed' | 'planting_event' | 'garden' | 'library' | ...
        let entityID: String?
        let label: String?
    }

    init(client: SeedkeepClient, container: ModelContainer) {
        self.client = client
        self.container = container
    }

    /// Inject the sync engine after both are constructed (avoids an init cycle).
    func wireSync(_ engine: SyncEngine) { self.sync = engine }

    // ── Page-context bus ───────────────────────────────────────────────────

    func setPageContext(_ context: AIPageContext) { pageContext = context }
    func clearPageContext() { pageContext = nil }

    // ── Key status ─────────────────────────────────────────────────────────

    /// Refresh from the server. Call on app launch + after Settings changes.
    func refreshKeyStatus() async {
        do {
            let status = try await client.assistantKeyStatus()
            keyConfigured = status.providers.contains(where: { $0.provider == "anthropic" && $0.configured })
            keyCheckError = nil
        } catch {
            keyCheckError = error.localizedDescription
        }
    }

    // ── Thread management ──────────────────────────────────────────────────

    @discardableResult
    func createThread(title: String = "") async throws -> LocalAssistantThread {
        let dto = try await client.createAssistantThread(title: title, threadKind: "chat")
        let local = dto.makeLocal()
        let ctx = ModelContext(container)
        ctx.insert(local)
        try ctx.save()
        return local
    }

    func deleteThread(_ id: String) async throws {
        try await client.deleteAssistantThread(id)
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<LocalAssistantThread>(predicate: #Predicate { $0.id == id })
        if let existing = try ctx.fetch(descriptor).first {
            // Cascade-clean children + delete locally; matches what the sync
            // engine would do on the next pull. Doing it now keeps the UI
            // consistent without waiting for a sync round-trip.
            let messages = try ctx.fetch(FetchDescriptor<LocalAssistantMessage>(predicate: #Predicate { $0.threadID == id }))
            for m in messages { ctx.delete(m) }
            let tools = try ctx.fetch(FetchDescriptor<LocalAssistantToolCall>(predicate: #Predicate { $0.threadID == id }))
            for t in tools { ctx.delete(t) }
            ctx.delete(existing)
        }
        try ctx.save()
        if currentThreadID == id { currentThreadID = nil }
    }

    func openThread(_ id: String) {
        currentThreadID = id
        streamingState = .idle
        lastError = nil
    }

    // ── Send + stream ──────────────────────────────────────────────────────

    /// Send a user message and stream Sprout's response into the thread.
    /// Inserts the user message + the assistant message locally as the
    /// stream produces events. The thread/message rows are visible to the
    /// view via @Query — SwiftData re-renders give the typewriter effect.
    func send(
        text: String,
        contextOverride: AIPageContext? = nil,
        attachment: SeedkeepClient.AssistantImageAttachment? = nil
    ) async throws {
        guard let threadID = currentThreadID else {
            throw NSError(domain: "Sprout", code: 0, userInfo: [NSLocalizedDescriptionKey: "No thread open"])
        }
        guard streamingState == .idle else { return }
        lastError = nil
        let ctx = contextOverride ?? pageContext
        let payload = ctx.map { AssistantPageContextPayload(pageType: $0.pageType, entityId: $0.entityID, label: $0.label) }

        let clientPetState = buildClientPetState()

        let stream = await client.streamAssistantResponse(
            threadId: threadID,
            text: text,
            pageContext: payload,
            attachment: attachment,
            clientPetState: clientPetState
        )
        try await consumeStream(stream, threadID: threadID)
    }

    /// Phase 5.1.5 — build the iOS-derived pet-state map for the next
    /// assistant turn. Includes every alive (non-completed, non-deleted,
    /// petSeed != nil) planting event in the active household. The server
    /// uses this opportunistically via `query_pet`; sending it on every
    /// turn is cheap and avoids client-side heuristics about whether a
    /// turn "is likely about pets".
    @MainActor
    private func buildClientPetState() -> [String: SeedkeepClient.AssistantClientPetStateEntry]? {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalPlantingEvent>(
            predicate: #Predicate<LocalPlantingEvent> { event in
                event.deletedAt == nil && event.completedAt == nil
            }
        )
        guard let fetched = try? context.fetch(descriptor), !fetched.isEmpty else { return nil }
        let candidates = fetched.filter { $0.petSeed != nil }
        guard !candidates.isEmpty else { return nil }
        var map: [String: SeedkeepClient.AssistantClientPetStateEntry] = [:]
        for event in candidates {
            let stars = petAgeStars(for: event)
            map[event.id] = .init(mood: event.petMoodLabel.rawValue, age_stars: stars)
        }
        return map
    }

    private func petAgeStars(for pet: LocalPlantingEvent) -> Int {
        guard let spawned = pet.petSpawnedAt else { return 0 }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let days = (nowMs - spawned) / (1000 * 60 * 60 * 24)
        return min(5, max(0, Int(days / 14)))
    }

    /// Confirm a proposed destructive tool call. Opens a fresh SSE stream
    /// from `/tool_calls/:id/confirm` that runs the deferred mutation and
    /// resumes the LLM conversation.
    func confirmToolCall(_ toolCallID: String) async throws {
        guard let threadID = currentThreadID else { return }
        guard case .awaitingConfirmation(let pending) = streamingState, pending == toolCallID else {
            // Already resolved or out of state — refresh from server to be safe.
            try await sync?.refreshAssistantThread(threadID)
            streamingState = .idle
            return
        }
        let stream = await client.confirmAssistantToolCall(toolCallID)
        try await consumeStream(stream, threadID: threadID)
    }

    /// Cancel a proposed destructive tool call. No stream — server returns
    /// the updated tool_call row directly.
    func cancelToolCall(_ toolCallID: String) async throws {
        guard let threadID = currentThreadID else { return }
        let updated = try await client.cancelAssistantToolCall(toolCallID)
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<LocalAssistantToolCall>(predicate: #Predicate { $0.id == toolCallID })
        if let existing = try ctx.fetch(descriptor).first {
            updated.apply(to: existing)
        } else {
            ctx.insert(updated.makeLocal())
        }
        try ctx.save()
        streamingState = .idle
        // Refresh the thread so the UI sees the cancel state + any LLM
        // continuation that may follow (when iOS triggers a new send).
        try? await sync?.refreshAssistantThread(threadID)
    }

    // ── Sparkle button entry ───────────────────────────────────────────────

    /// Create a new thread, attach the current pageContext, and return the
    /// thread id so the caller can navigate. Used by TopBarSparkleButton.
    @discardableResult
    func launchFromSparkle(initialText: String = "") async throws -> String {
        let title = pageContext?.label ?? ""
        let thread = try await createThread(title: title)
        currentThreadID = thread.id
        return thread.id
    }

    /// Open the popup-sheet overlay. Creates a fresh thread with the current
    /// pageContext baked into the title (so the sheet is always a "new
    /// conversation about this page"). The dedicated Sprout tab is still
    /// where users browse and resume past threads.
    func presentSheet() async throws {
        _ = try await launchFromSparkle()
        isSheetPresented = true
    }

    func dismissSheet() {
        isSheetPresented = false
    }

    // ── Internals ──────────────────────────────────────────────────────────

    private func consumeStream(
        _ stream: AsyncThrowingStream<AssistantStreamEvent, Error>,
        threadID: String
    ) async throws {
        // We persist the events into SwiftData as they arrive so the view's
        // @Query re-renders give the typewriter effect. The server already
        // wrote the row to Postgres; we mirror that here.
        //
        // Text deltas can fire hundreds of times per response — a save()
        // per token is real CPU + battery churn. We coalesce: apply the
        // delta in-memory on every event, but only commit to SwiftData
        // when (a) at least `streamSaveDebounceMs` has elapsed since the
        // last flush, (b) the event is a non-delta (tool_use_*, done,
        // error), or (c) the stream ends. Non-text-delta events ALWAYS
        // flush so the view sees tool cards immediately.
        let ctx = ModelContext(container)
        var activeAssistantMessageID: String?
        var lastFlushAt = Date()
        var dirty = false
        let flushIntervalSeconds: TimeInterval = 0.15

        func flushIfDirty(force: Bool = false) {
            guard dirty else { return }
            if !force && Date().timeIntervalSince(lastFlushAt) < flushIntervalSeconds { return }
            do { try ctx.save() } catch {
                // A failed save here is recoverable on the next event —
                // the in-memory model state is still correct, the next
                // flush will retry. Don't fail the stream over it.
            }
            dirty = false
            lastFlushAt = Date()
        }

        do {
            for try await event in stream {
                switch event {
                case .textDelta(let messageId, let delta):
                    activeAssistantMessageID = messageId
                    streamingState = .streaming(messageID: messageId)
                    try appendTextDeltaInMemory(to: messageId, threadID: threadID, delta: delta, in: ctx)
                    dirty = true
                    flushIfDirty()

                case .toolUseStart(let toolCallId, let messageId, let toolName):
                    activeAssistantMessageID = messageId
                    streamingState = .streaming(messageID: messageId)
                    try upsertToolCallInMemory(
                        id: toolCallId, messageID: messageId, threadID: threadID,
                        toolName: toolName, argsJSON: "{}", status: "running",
                        in: ctx)
                    dirty = true
                    flushIfDirty(force: true)

                case .toolUseDone(let toolCallId, let argsJson):
                    try patchToolCallArgsInMemory(id: toolCallId, argsJSON: argsJson, in: ctx)
                    dirty = true
                    flushIfDirty(force: true)

                case .toolResult(let toolCallId, let status, let resultJson):
                    try patchToolCallResultInMemory(id: toolCallId, status: status, resultJSON: resultJson, in: ctx)
                    dirty = true
                    flushIfDirty(force: true)

                case .proposedChange(let toolCallId, let proposedChangeJson):
                    try patchToolCallProposedInMemory(id: toolCallId, proposedChangeJSON: proposedChangeJson, in: ctx)
                    dirty = true
                    flushIfDirty(force: true)
                    streamingState = .awaitingConfirmation(toolCallID: toolCallId)
                    // Stream will close after this event; loop exits cleanly.

                case .done(let messageId):
                    activeAssistantMessageID = messageId
                    streamingState = .idle

                case .streamError(let code, let message):
                    streamingState = .error("\(code): \(message)")
                    lastError = message
                }
            }
            // Stream completed normally without a `done` (proposed_change exit
            // path) — leave state as-is.
            if case .streaming = streamingState {
                streamingState = .idle
            }
        } catch {
            // Persist whatever we accumulated before the error so the
            // user can see the partial reply on next view appear.
            flushIfDirty(force: true)
            streamingState = .error(error.localizedDescription)
            lastError = error.localizedDescription
            throw error
        }
        // Final flush so the typewriter's last few tokens land.
        flushIfDirty(force: true)
        _ = activeAssistantMessageID  // (kept for future use if we want to scroll-to)
        // After the stream ends, refresh from server so we pick up the
        // canonical message + tool call rows (and to update updatedAt etc.).
        try? await sync?.refreshAssistantThread(threadID)
    }

    // In-memory variants — mutate the SwiftData objects but DON'T save.
    // The streaming loop calls `flushIfDirty` to batch saves so the
    // view sees the typewriter effect without per-token transaction
    // overhead. Each helper mirrors its original save-inline cousin.

    private func appendTextDeltaInMemory(
        to messageID: String,
        threadID: String,
        delta: String,
        in ctx: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<LocalAssistantMessage>(predicate: #Predicate { $0.id == messageID })
        if let existing = try ctx.fetch(descriptor).first {
            existing.contentJSON = appendDeltaToContentJSON(existing.contentJSON, delta: delta)
        } else {
            let initial = serializeContent(blocks: [.text(delta)])
            let msg = LocalAssistantMessage(
                id: messageID, threadID: threadID, role: "assistant",
                contentJSON: initial, pageContext: nil, model: nil, usageJSON: nil,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000))
            ctx.insert(msg)
        }
    }

    private func upsertToolCallInMemory(
        id: String, messageID: String, threadID: String,
        toolName: String, argsJSON: String, status: String,
        in ctx: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<LocalAssistantToolCall>(predicate: #Predicate { $0.id == id })
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let existing = try ctx.fetch(descriptor).first {
            existing.toolName = toolName
            existing.status = status
            existing.updatedAt = now
        } else {
            ctx.insert(LocalAssistantToolCall(
                id: id, messageID: messageID, threadID: threadID,
                toolName: toolName, argsJSON: argsJSON, status: status,
                resultJSON: nil, proposedChangeJSON: nil, confirmedAt: nil,
                createdAt: now, updatedAt: now))
        }
    }

    private func patchToolCallArgsInMemory(id: String, argsJSON: String, in ctx: ModelContext) throws {
        let descriptor = FetchDescriptor<LocalAssistantToolCall>(predicate: #Predicate { $0.id == id })
        if let existing = try ctx.fetch(descriptor).first {
            existing.argsJSON = argsJSON
            existing.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    private func patchToolCallResultInMemory(id: String, status: String, resultJSON: String?, in ctx: ModelContext) throws {
        let descriptor = FetchDescriptor<LocalAssistantToolCall>(predicate: #Predicate { $0.id == id })
        if let existing = try ctx.fetch(descriptor).first {
            existing.status = status
            existing.resultJSON = resultJSON
            existing.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    private func patchToolCallProposedInMemory(id: String, proposedChangeJSON: String, in ctx: ModelContext) throws {
        let descriptor = FetchDescriptor<LocalAssistantToolCall>(predicate: #Predicate { $0.id == id })
        if let existing = try ctx.fetch(descriptor).first {
            existing.status = "proposed"
            existing.proposedChangeJSON = proposedChangeJSON
            existing.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    // ── Content-block helpers ──────────────────────────────────────────────

    /// Anthropic-style content blocks. We don't expose a typed enum to views
    /// (they read text directly via `MessageContent.text(from:)`); the
    /// encoder/decoder here is internal.
    private enum Block {
        case text(String)
    }

    private func serializeContent(blocks: [Block]) -> String {
        let json = blocks.map { block -> [String: String] in
            switch block {
            case .text(let t): return ["type": "text", "text": t]
            }
        }
        return (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "[]"
    }

    private func appendDeltaToContentJSON(_ contentJSON: String, delta: String) -> String {
        // Decode → find the LAST text block → append delta. If none exists,
        // create one. We keep the serialized shape stable for sync.
        struct AnyTextBlock: Codable { var type: String; var text: String? }
        guard let data = contentJSON.data(using: .utf8),
              var blocks = try? JSONDecoder().decode([AnyTextBlock].self, from: data) else {
            return serializeContent(blocks: [.text(delta)])
        }
        if let lastIdx = blocks.lastIndex(where: { $0.type == "text" }) {
            blocks[lastIdx].text = (blocks[lastIdx].text ?? "") + delta
        } else {
            blocks.append(AnyTextBlock(type: "text", text: delta))
        }
        return (try? String(data: JSONEncoder().encode(blocks), encoding: .utf8)) ?? contentJSON
    }
}

/// Helper for views: pull the text out of an assistant message's contentJSON.
enum MessageContent {
    /// Returns the concatenated text content from the message's content
    /// blocks. Tool-use blocks are not included (they render as inline
    /// cards via LocalAssistantToolCall).
    static func text(from contentJSON: String) -> String {
        struct Block: Decodable { let type: String; let text: String? }
        guard let data = contentJSON.data(using: .utf8),
              let blocks = try? JSONDecoder().decode([Block].self, from: data) else {
            return ""
        }
        return blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }
}
