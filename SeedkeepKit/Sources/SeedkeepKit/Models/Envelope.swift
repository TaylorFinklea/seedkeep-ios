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

    private enum Keys: String, CodingKey { case ok, data, error, request_id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let ok = try c.decode(Bool.self, forKey: .ok)
        let requestID = try c.decodeIfPresent(String.self, forKey: .request_id)
        if ok {
            let data = try c.decode(T.self, forKey: .data)
            self = .ok(data, requestID: requestID)
        } else {
            let err = try c.decode(SeedkeepError.Body.self, forKey: .error)
            self = .failure(SeedkeepError(code: err.code, message: err.message, requestID: requestID))
        }
    }
}

/// Typed server error.  Includes the request ID when the server returned one
/// so logs can correlate client + server.
public struct SeedkeepError: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    public let requestID: String?

    public init(code: String, message: String, requestID: String? = nil) {
        self.code = code
        self.message = message
        self.requestID = requestID
    }

    /// Wire shape of the inner `error` object.
    struct Body: Decodable, Sendable {
        let code: String
        let message: String
    }
}
