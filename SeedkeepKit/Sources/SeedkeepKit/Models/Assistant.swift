import Foundation

/// Wire-format DTOs for the Phase 4 (Sprout AI assistant) API endpoints.
///
/// Server response keys are camelCase (matching the journal + recommendation
/// routes), so synthesized `Codable` conformance works without custom
/// `CodingKeys` here. Request bodies use snake_case — those live in the
/// `*Input` types declared next to the client methods.
///
/// Content blocks (text / tool_use / tool_result) follow Anthropic's
/// tagged-union shape. We carry them as opaque `contentJson: String` rather
/// than decoding to typed cases — the server is the only consumer that needs
/// to interpret them; iOS treats them as a JSON blob for storage + display.

public struct AssistantThreadDTO: Codable, Sendable, Equatable {
    public let id: String
    public let householdId: String
    public let title: String
    public let threadKind: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let deletedAt: Int64?

    public init(id: String, householdId: String, title: String, threadKind: String,
                createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) {
        self.id = id
        self.householdId = householdId
        self.title = title
        self.threadKind = threadKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct AssistantMessageDTO: Codable, Sendable, Equatable {
    public let id: String
    public let threadId: String
    public let role: String              // 'user' | 'assistant' | 'tool' | 'system'
    public let contentJson: String       // raw Anthropic content-block JSON
    public let pageContext: String?      // optional JSON: { pageType, entityId, label }
    public let model: String?            // populated on 'assistant' rows
    public let usageJson: String?        // input/output token counts
    public let createdAt: Int64

    public init(id: String, threadId: String, role: String, contentJson: String,
                pageContext: String?, model: String?, usageJson: String?, createdAt: Int64) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.contentJson = contentJson
        self.pageContext = pageContext
        self.model = model
        self.usageJson = usageJson
        self.createdAt = createdAt
    }
}

public struct AssistantToolCallDTO: Codable, Sendable, Equatable {
    public let id: String
    public let messageId: String
    public let threadId: String
    public let toolName: String
    public let argsJson: String
    public let status: String                  // 'proposed' | 'running' | 'done' | 'failed' | 'cancelled'
    public let resultJson: String?
    public let proposedChangeJson: String?
    public let confirmedAt: Int64?
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(id: String, messageId: String, threadId: String, toolName: String,
                argsJson: String, status: String, resultJson: String?,
                proposedChangeJson: String?, confirmedAt: Int64?,
                createdAt: Int64, updatedAt: Int64) {
        self.id = id
        self.messageId = messageId
        self.threadId = threadId
        self.toolName = toolName
        self.argsJson = argsJson
        self.status = status
        self.resultJson = resultJson
        self.proposedChangeJson = proposedChangeJson
        self.confirmedAt = confirmedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Full thread payload returned by GET /api/assistant/threads/:id.
public struct AssistantThreadDetailDTO: Codable, Sendable, Equatable {
    public let thread: AssistantThreadDTO
    public let messages: [AssistantMessageDTO]
    public let toolCalls: [AssistantToolCallDTO]

    public init(thread: AssistantThreadDTO,
                messages: [AssistantMessageDTO],
                toolCalls: [AssistantToolCallDTO]) {
        self.thread = thread
        self.messages = messages
        self.toolCalls = toolCalls
    }
}

/// One provider's configured-state. Returned by GET /me/assistant_key.
/// Never carries the key itself; just whether it's set.
public struct AssistantKeyProviderStatus: Codable, Sendable, Equatable {
    public let provider: String          // 'anthropic'
    public let configured: Bool
    public let updatedAt: Int64?

    public init(provider: String, configured: Bool, updatedAt: Int64?) {
        self.provider = provider
        self.configured = configured
        self.updatedAt = updatedAt
    }
}

public struct AssistantKeyStatusDTO: Codable, Sendable, Equatable {
    public let providers: [AssistantKeyProviderStatus]
    public init(providers: [AssistantKeyProviderStatus]) { self.providers = providers }
}

/// Thread feed reuses the existing delta-sync envelope.
public typealias AssistantThreadFeedDTO = DeltaPage<AssistantThreadDTO>

/// Page context attached to the first user message of a sparkle-launched
/// thread. Decoded server-side to ground the system prompt.
public struct AssistantPageContextPayload: Codable, Sendable, Equatable {
    public let pageType: String
    public let entityId: String?
    public let label: String?

    public init(pageType: String, entityId: String? = nil, label: String? = nil) {
        self.pageType = pageType
        self.entityId = entityId
        self.label = label
    }
}

/// Parsed SSE event from the assistant streaming endpoint. The server emits
/// these JSON-encoded inside `data:` lines; iOS decodes each line + dispatches
/// the matching case to the AIAssistantCoordinator state machine.
public enum AssistantStreamEvent: Sendable, Equatable {
    case textDelta(messageId: String, delta: String)
    case toolUseStart(toolCallId: String, messageId: String, toolName: String)
    case toolUseDone(toolCallId: String, argsJson: String)
    case toolResult(toolCallId: String, status: String, resultJson: String?)
    case proposedChange(toolCallId: String, proposedChangeJson: String)
    case done(messageId: String)
    case streamError(code: String, message: String)
}

/// Internal: decodable shape of one SSE event's JSON payload. The server emits
/// snake_case fields so this struct uses CodingKeys to map to camelCase here.
internal struct AssistantStreamEventWire: Decodable {
    let type: String
    let messageId: String?
    let delta: String?
    let toolCallId: String?
    let toolName: String?
    let argsJson: String?
    let status: String?
    let resultJson: String?
    let proposedChangeJson: String?
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case messageId = "message_id"
        case delta
        case toolCallId = "tool_call_id"
        case toolName = "tool_name"
        case argsJson = "args_json"
        case status
        case resultJson = "result_json"
        case proposedChangeJson = "proposed_change_json"
        case code
        case message
    }
}

extension AssistantStreamEvent {
    /// Decode a single SSE `data: {...}` JSON payload into a typed event,
    /// or return nil if the payload doesn't match any known event shape.
    public static func decode(_ data: Data) -> AssistantStreamEvent? {
        guard let wire = try? JSONDecoder().decode(AssistantStreamEventWire.self, from: data) else {
            return nil
        }
        switch wire.type {
        case "text_delta":
            guard let mid = wire.messageId, let d = wire.delta else { return nil }
            return .textDelta(messageId: mid, delta: d)
        case "tool_use_start":
            guard let tcid = wire.toolCallId, let mid = wire.messageId, let n = wire.toolName else { return nil }
            return .toolUseStart(toolCallId: tcid, messageId: mid, toolName: n)
        case "tool_use_done":
            guard let tcid = wire.toolCallId, let aj = wire.argsJson else { return nil }
            return .toolUseDone(toolCallId: tcid, argsJson: aj)
        case "tool_result":
            guard let tcid = wire.toolCallId, let s = wire.status else { return nil }
            return .toolResult(toolCallId: tcid, status: s, resultJson: wire.resultJson)
        case "proposed_change":
            guard let tcid = wire.toolCallId, let pc = wire.proposedChangeJson else { return nil }
            return .proposedChange(toolCallId: tcid, proposedChangeJson: pc)
        case "done":
            guard let mid = wire.messageId else { return nil }
            return .done(messageId: mid)
        case "error":
            return .streamError(code: wire.code ?? "unknown", message: wire.message ?? "")
        default:
            return nil
        }
    }
}
