import Foundation

/// Server response envelope mirrored from the `seedkeep` Workers API:
///
///     { "ok": true,  "data": { ... }, "request_id": "..." }
///     { "ok": false, "error": { "code": "...", "message": "..." } }
///
/// Decoding goes through `Envelope<T>.decode(from:)` so callers always
/// surface a typed `T` or a typed `SeedkeepError`.
public enum Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    case ok(T, requestID: String?)
    case failure(SeedkeepError)

    private enum Keys: String, CodingKey { case ok, data, error, request_id, retry_after_seconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let ok = try c.decode(Bool.self, forKey: .ok)
        let requestID = try c.decodeIfPresent(String.self, forKey: .request_id)
        if ok {
            let data = try c.decode(T.self, forKey: .data)
            self = .ok(data, requestID: requestID)
        } else {
            let err = try c.decode(SeedkeepError.Body.self, forKey: .error)
            // 429 responses carry `retry_after_seconds` as a top-level
            // sibling of `error`, not inside it.
            let retryAfter = try c.decodeIfPresent(Int.self, forKey: .retry_after_seconds)
            self = .failure(SeedkeepError(
                code: err.code,
                message: err.message,
                requestID: requestID,
                retryAfterSeconds: retryAfter
            ))
        }
    }
}

/// Typed server error.  Includes the request ID when the server returned one
/// so logs can correlate client + server.
public struct SeedkeepError: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    public let requestID: String?
    /// Populated from the envelope-level `retry_after_seconds` sibling
    /// on rate-limited (429) responses; `nil` otherwise.
    public let retryAfterSeconds: Int?
    /// HTTP status code of the response this error was decoded from.
    /// `nil` for errors minted locally (bad URL, non-HTTP response).
    /// Lets callers classify transport-shaped failures (5xx / 429 are
    /// retryable; definitive 4xx rejections are not) without parsing
    /// machine strings.
    public let httpStatus: Int?

    public init(
        code: String,
        message: String,
        requestID: String? = nil,
        retryAfterSeconds: Int? = nil,
        httpStatus: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.retryAfterSeconds = retryAfterSeconds
        self.httpStatus = httpStatus
    }

    /// Copy of this error with the HTTP status attached. Used by the
    /// client's `perform` so envelope-decoded failures carry the status
    /// of the response they rode in on.
    func attaching(httpStatus: Int) -> SeedkeepError {
        SeedkeepError(
            code: code,
            message: message,
            requestID: requestID,
            retryAfterSeconds: retryAfterSeconds,
            httpStatus: httpStatus
        )
    }

    /// Wire shape of the inner `error` object.
    struct Body: Decodable, Sendable {
        let code: String
        let message: String
    }
}

/// `error.localizedDescription` on a bridged Swift error without
/// `LocalizedError` yields the useless NSError placeholder ("The
/// operation couldn't be completed…"). Route it through `humanizeError`
/// so every view-level `catch { … error.localizedDescription … }` site
/// shows the same user-readable copy as the banner path.
extension SeedkeepError: LocalizedError {
    public var errorDescription: String? { humanizeError(self) }
}
