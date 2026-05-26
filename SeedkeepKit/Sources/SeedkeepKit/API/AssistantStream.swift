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
        attachment: AssistantImageAttachment? = nil
    ) async -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        return openSSE(
            path: "/api/assistant/threads/\(threadId)/stream",
            method: "POST",
            body: StreamRequestBody(
                text: text,
                pageContext: pageContext,
                attachment: attachment
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
        enum CodingKeys: String, CodingKey {
            case text
            case pageContext = "page_context"
            case attachment
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
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            continuation.finish(throwing: AssistantSSEError.badStatus(code))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
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
}

public enum AssistantSSEError: Error, Sendable, Equatable {
    case badStatus(Int)
}
