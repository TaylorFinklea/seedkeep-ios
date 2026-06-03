import Foundation

// SSE streaming for the Sprout assistant routes. URLSession.bytes(for:)
// buffers HTTP/2 DATA frames client-side which kills streaming UX (deltas
// arrive in clumps), so we use a URLSessionDataDelegate that parses each
// TLS record as it lands and yields events into an AsyncThrowingStream.
// Pattern mirrors SimmerSmith's SSEStreamDelegate.

extension SeedkeepClient {

    /// Send a user message and stream Sprout's response.
    /// Yields `AssistantStreamEvent` values as the server emits them.
    /// Async because SeedkeepClient is an actor — the call awaits the
    /// actor's hop. The returned stream is independent of the actor.
    public func streamAssistantResponse(
        threadId: String,
        text: String,
        pageContext: AssistantPageContextPayload? = nil,
        attachment: AssistantImageAttachment? = nil,
        clientPetState: [String: AssistantClientPetStateEntry]? = nil
    ) async -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        return openSSE(
            path: "/api/assistant/threads/\(threadId)/stream",
            method: "POST",
            body: StreamRequestBody(
                text: text,
                pageContext: pageContext,
                attachment: attachment,
                clientPetState: clientPetState
            )
        )
    }

    /// Phase 4 B — optional image attached to a user message. Server
    /// passes this through to Anthropic as a vision content block, so
    /// Sprout can answer "what should I plant in this corner?" prompts.
    public struct AssistantImageAttachment: Encodable, Sendable {
        public let media_type: String   // "image/jpeg" | "image/png" | ...
        public let data: String         // base64 (no data: prefix)
        public init(media_type: String, data: String) {
            self.media_type = media_type
            self.data = data
        }
    }

    /// Phase 5.1.5 — per-turn iOS-derived pet state. Keyed by
    /// planting_event_id. The server's `query_pet` tool uses this to fill
    /// `mood` + `age_stars` in its response. Sparse: any planting not in
    /// the map shows up with null mood/age_stars on the server side.
    public struct AssistantClientPetStateEntry: Encodable, Sendable {
        public let mood: String   // "thriving" | "content" | "quiet" | "wilted" | "departingImminent"
        public let age_stars: Int
        public init(mood: String, age_stars: Int) {
            self.mood = mood
            self.age_stars = age_stars
        }
    }

    /// Confirm a proposed tool call. The server applies the deferred mutation
    /// and resumes the LLM conversation in a fresh SSE stream.
    public func confirmAssistantToolCall(
        _ id: String
    ) async -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        return openSSE(
            path: "/api/assistant/tool_calls/\(id)/confirm",
            method: "POST",
            body: EmptyStreamBody()
        )
    }

    // MARK: - Internals

    private struct StreamRequestBody: Encodable {
        let text: String
        let pageContext: AssistantPageContextPayload?
        let attachment: AssistantImageAttachment?
        let clientPetState: [String: AssistantClientPetStateEntry]?
        enum CodingKeys: String, CodingKey {
            case text
            case pageContext = "page_context"
            case attachment
            case clientPetState = "client_pet_state"
        }
    }

    private struct EmptyStreamBody: Encodable {}

    private func openSSE<Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        let url = configuration.baseURL.appendingPathComponent(path)
        let token = bearerToken
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream<AssistantStreamEvent, Error> { continuation in
            let delegate = AssistantSSEDelegate(continuation: continuation)
            // Use a per-stream session so cancellation cleanly tears down.
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            req.httpBody = bodyData

            let task = session.dataTask(with: req)
            delegate.task = task
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

/// Parses incoming SSE bytes incrementally and yields decoded
/// `AssistantStreamEvent` values. Handles partial lines across chunks +
/// comment heartbeats. Multi-line `data:` continuations are joined with \n.
final class AssistantSSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<AssistantStreamEvent, Error>.Continuation
    private var pending = Data()
    private var dataLines: [String] = []
    /// When the server returns a non-2xx, we buffer the body so we can
    /// surface its JSON error message instead of an opaque status code.
    /// `errorStatus` doubles as the "currently buffering an error" flag.
    private var errorStatus: Int?
    private var errorBody = Data()
    fileprivate weak var task: URLSessionDataTask?

    init(continuation: AsyncThrowingStream<AssistantStreamEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Don't finish yet — let didReceive(data:) buffer the
            // response body, then didCompleteWithError fires the error
            // with the parsed message. `.allow` here lets the bytes flow.
            errorStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            completionHandler(.allow)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        if errorStatus != nil {
            errorBody.append(data)
            // Cap at 8 KB — error bodies are tiny; anything larger is
            // bot output we don't want to buffer.
            if errorBody.count > 8 * 1024 { errorBody.removeSubrange(8 * 1024..<errorBody.count) }
            return
        }
        pending.append(data)
        // Split on \n; keep any trailing partial line in `pending`.
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
            pending.removeSubrange(pending.startIndex...newlineIndex)
            // Strip CR for CRLF tolerance.
            let trimmed = (lineData.last == 0x0D)
                ? lineData.subdata(in: lineData.startIndex..<(lineData.endIndex - 1))
                : lineData
            let line = String(data: trimmed, encoding: .utf8) ?? ""

            if line.isEmpty {
                // End-of-event: yield accumulated data lines as one event.
                if !dataLines.isEmpty {
                    let payload = dataLines.joined(separator: "\n")
                    if let ev = AssistantStreamEvent.decode(Data(payload.utf8)) {
                        continuation.yield(ev)
                    }
                }
                dataLines = []
            } else if line.hasPrefix("data:") {
                // Per SSE spec, the value is everything after "data:" with one
                // leading space stripped if present.
                var v = String(line.dropFirst(5))
                if v.hasPrefix(" ") { v = String(v.dropFirst()) }
                dataLines.append(v)
            }
            // `event:` line is informational; the JSON `type` field is canonical.
            // Lines starting with `:` are SSE comments — ignore.
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let nsError = error as NSError?,
           nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            continuation.finish()
            return
        }
        // If we buffered a non-2xx response, parse the server's JSON
        // error envelope and surface its message — much friendlier than
        // a bare status code in the UI.
        if let status = errorStatus {
            let payload = parseErrorBody(errorBody)
            continuation.finish(throwing: AssistantSSEError.badStatus(status: status, code: payload?.code, message: payload?.message))
            return
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            // Flush any trailing event with no terminating blank line.
            if !dataLines.isEmpty {
                let payload = dataLines.joined(separator: "\n")
                if let ev = AssistantStreamEvent.decode(Data(payload.utf8)) {
                    continuation.yield(ev)
                }
                dataLines = []
            }
            continuation.finish()
        }
    }

    /// Best-effort decode of the server's `{ ok: false, error: { code, message } }`
    /// envelope. Returns nil if the body isn't recognizable JSON.
    private func parseErrorBody(_ data: Data) -> (code: String?, message: String?)? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any]
        else { return nil }
        return (err["code"] as? String, err["message"] as? String)
    }
}

public enum AssistantSSEError: Error, Sendable, Equatable {
    case badStatus(status: Int, code: String?, message: String?)
}

extension AssistantSSEError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badStatus(let status, let code, let message):
            // Prefer the server's user-facing message; fall back to
            // code-only, then the bare status as a last resort.
            if let message, !message.isEmpty {
                if let code, !code.isEmpty {
                    return "\(code): \(message)"
                }
                return message
            }
            if let code, !code.isEmpty {
                return "\(code) (HTTP \(status))"
            }
            return "Sprout request failed (HTTP \(status))"
        }
    }
}
