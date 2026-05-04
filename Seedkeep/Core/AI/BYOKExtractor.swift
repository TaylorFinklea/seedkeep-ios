import Foundation

/// BYOK (bring-your-own-key) extractor. Sends the front + back photos
/// directly to the user's chosen LLM provider — Anthropic preferred,
/// OpenAI as fallback — using the API key in `APIKeyStore`. The key
/// never reaches the Seedkeep server, and the extracted JSON is then
/// POSTed to `/api/extractions/pre-extracted` like any free-tier
/// extraction.
public struct BYOKExtractor: Sendable {
    public struct Output: Sendable, Equatable {
        public let commonName: String?
        public let variety: String?
        public let company: String?
        public let instructions: String?
        public let selfConfidence: Double
        public let modelID: String
    }

    public enum Failure: Error, LocalizedError {
        case noKey
        case providerError(provider: APIKeyStore.Provider, message: String)
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noKey:
                return "No API key configured. Add one in Settings → API keys."
            case .providerError(let p, let m):
                return "\(p.displayName) error: \(m)"
            case .parseFailed(let m):
                return "Provider returned malformed output: \(m)"
            }
        }
    }

    private let keyStore: APIKeyStore
    private let urlSession: URLSession

    public init(keyStore: APIKeyStore, urlSession: URLSession = .shared) {
        self.keyStore = keyStore
        self.urlSession = urlSession
    }

    public func extract(frontJPEG: Data, backJPEG: Data) async throws -> Output {
        guard let provider = keyStore.preferredProvider(),
              let key = keyStore.load(provider) else {
            throw Failure.noKey
        }
        switch provider {
        case .anthropic:
            return try await extractWithAnthropic(key: key, front: frontJPEG, back: backJPEG)
        case .openai:
            return try await extractWithOpenAI(key: key, front: frontJPEG, back: backJPEG)
        }
    }

    // MARK: - Anthropic

    private static let anthropicModel = "claude-sonnet-4-6"
    private static let openaiModel = "gpt-4o"

    private static let extractionPrompt = """
    You are reading two photos of a seed packet — first the front, then the back. \
    Extract the listed fields and return ONLY a single JSON object with these exact keys:
      - "common_name": string or null (the plant's common name, e.g. "Tomato", "Sunflower")
      - "variety": string or null (specific cultivar, e.g. "Cherokee Purple")
      - "company": string or null (the seed company that produced the packet)
      - "instructions": string or null (one to three concise sentences distilling the planting instructions)
      - "self_confidence": number from 0.0 to 1.0 estimating how likely your extraction is correct
    Use null for any field the photos do not unambiguously support. Do not invent values. Do not include any prose outside the JSON.
    """

    private func extractWithAnthropic(key: String, front: Data, back: Data) async throws -> Output {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": Self.anthropicModel,
            "max_tokens": 1024,
            "messages": [[
                "role": "user",
                "content": [
                    Self.anthropicImageBlock(jpeg: front),
                    Self.anthropicImageBlock(jpeg: back),
                    ["type": "text", "text": Self.extractionPrompt],
                ],
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.providerError(provider: .anthropic, message: "Non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw Failure.providerError(provider: .anthropic, message: "HTTP \(http.statusCode): \(raw.prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstText = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        else {
            throw Failure.parseFailed("Could not pull text content from Anthropic response")
        }
        let parsed = try Self.parseExtractionJSON(firstText)
        return Output(
            commonName: parsed.commonName,
            variety: parsed.variety,
            company: parsed.company,
            instructions: parsed.instructions,
            selfConfidence: parsed.selfConfidence,
            modelID: "anthropic.\(Self.anthropicModel)"
        )
    }

    private static func anthropicImageBlock(jpeg: Data) -> [String: Any] {
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": jpeg.base64EncodedString(),
            ],
        ]
    }

    // MARK: - OpenAI

    private func extractWithOpenAI(key: String, front: Data, back: Data) async throws -> Output {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": Self.openaiModel,
            "response_format": ["type": "json_object"],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": Self.extractionPrompt],
                    Self.openaiImageBlock(jpeg: front),
                    Self.openaiImageBlock(jpeg: back),
                ],
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.providerError(provider: .openai, message: "Non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw Failure.providerError(provider: .openai, message: "HTTP \(http.statusCode): \(raw.prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let firstText = message["content"] as? String
        else {
            throw Failure.parseFailed("Could not pull message content from OpenAI response")
        }
        let parsed = try Self.parseExtractionJSON(firstText)
        return Output(
            commonName: parsed.commonName,
            variety: parsed.variety,
            company: parsed.company,
            instructions: parsed.instructions,
            selfConfidence: parsed.selfConfidence,
            modelID: "openai.\(Self.openaiModel)"
        )
    }

    private static func openaiImageBlock(jpeg: Data) -> [String: Any] {
        return [
            "type": "image_url",
            "image_url": [
                "url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())",
            ],
        ]
    }

    // MARK: - JSON parsing

    fileprivate struct ParsedFields {
        let commonName: String?
        let variety: String?
        let company: String?
        let instructions: String?
        let selfConfidence: Double
    }

    fileprivate static func parseExtractionJSON(_ raw: String) throws -> ParsedFields {
        let trimmed = stripCodeFence(from: raw)
        guard let data = trimmed.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.parseFailed("Could not parse JSON from: \(raw.prefix(200))")
        }
        let conf = (object["self_confidence"] as? Double)
            ?? Double(object["self_confidence"] as? String ?? "")
            ?? 0
        return ParsedFields(
            commonName: nonEmptyString(object["common_name"]),
            variety: nonEmptyString(object["variety"]),
            company: nonEmptyString(object["company"]),
            instructions: nonEmptyString(object["instructions"]),
            selfConfidence: max(0, min(1, conf))
        )
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripCodeFence(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3))
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
