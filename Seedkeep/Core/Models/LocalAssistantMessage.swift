import Foundation
import SwiftData

/// One message in a Sprout thread. Append-only on the server; on iOS we
/// also append-only (and tear down when the parent thread is hard-deleted).
///
/// `contentJSON` carries an Anthropic-style content-block array as a raw
/// JSON string. Views decode lazily on render rather than at sync time —
/// most messages are simple text and decoding everything up front would
/// waste cycles.
@Model
final class LocalAssistantMessage {
    @Attribute(.unique) var id: String
    var threadID: String
    var role: String                 // 'user' | 'assistant' | 'tool' | 'system'
    var contentJSON: String
    var pageContext: String?         // optional JSON: { pageType, entityId, label }
    var model: String?               // populated on 'assistant' rows
    var usageJSON: String?
    var createdAt: Int64

    init(id: String, threadID: String, role: String, contentJSON: String,
         pageContext: String?, model: String?, usageJSON: String?, createdAt: Int64) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.contentJSON = contentJSON
        self.pageContext = pageContext
        self.model = model
        self.usageJSON = usageJSON
        self.createdAt = createdAt
    }
}
