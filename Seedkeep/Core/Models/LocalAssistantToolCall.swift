import Foundation
import SwiftData

/// A tool invocation Sprout made (or proposed). Rendered inline within the
/// assistant message it belongs to. Status transitions:
///   - LLM emitted tool_use → status='running'
///   - Server executed auto tool → status='done' (or 'failed' on error)
///   - Server proposed destructive tool → status='proposed' (UI shows
///     Confirm/Cancel card)
///   - User confirmed → status='done' with confirmedAt set
///   - User cancelled → status='cancelled'
@Model
final class LocalAssistantToolCall {
    @Attribute(.unique) var id: String
    var messageID: String
    var threadID: String
    var toolName: String
    var argsJSON: String
    var status: String
    var resultJSON: String?
    var proposedChangeJSON: String?
    var confirmedAt: Int64?
    var createdAt: Int64
    var updatedAt: Int64

    init(id: String, messageID: String, threadID: String, toolName: String,
         argsJSON: String, status: String, resultJSON: String?,
         proposedChangeJSON: String?, confirmedAt: Int64?,
         createdAt: Int64, updatedAt: Int64) {
        self.id = id
        self.messageID = messageID
        self.threadID = threadID
        self.toolName = toolName
        self.argsJSON = argsJSON
        self.status = status
        self.resultJSON = resultJSON
        self.proposedChangeJSON = proposedChangeJSON
        self.confirmedAt = confirmedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var requiresConfirmation: Bool { status == "proposed" }
    var isTerminal: Bool { status == "done" || status == "failed" || status == "cancelled" }
}
