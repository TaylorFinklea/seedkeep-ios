import Foundation
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Two-stage on-device extraction for seed packets.
///
/// 1. Vision (iOS 13+) runs `VNRecognizeTextRequest` on the front + back
///    JPEGs and gives us OCR text.
/// 2. Apple Foundation Models (iOS 26+) ingests the OCR text and emits
///    structured fields — `common_name`, `variety`, `company`,
///    `instructions`, plus a `self_confidence` rating.
///
/// On iOS 18.1–25.x (or on iOS 26+ devices without Apple Intelligence)
/// the second stage is unavailable. We still return the OCR text so the
/// caller can fall back to a manual-review path or surface the OCR to
/// the user, but `selfConfidence` will be 0 and the structured fields
/// will be `nil`. Hosted-tier users always go through the server path
/// instead — they never call this.
public struct OnDeviceExtractor: Sendable {
    /// Identifier reported to the server in `model_id`. Pinned to a
    /// version so we can split telemetry / catalog rows by extractor
    /// generation later.
    public static let modelID = "apple.foundation-models.v1"

    public struct Output: Sendable, Equatable {
        public let commonName: String?
        public let variety: String?
        public let company: String?
        public let instructions: String?
        public let selfConfidence: Double
        public let modelID: String

        /// Raw OCR text fed into the structured-extraction step. Useful
        /// for debugging "why did it miss this field?" and as a manual
        /// fallback when Foundation Models isn't available on the device.
        public let ocrFrontText: String
        public let ocrBackText: String

        public var hasAnyStructuredFields: Bool {
            [commonName, variety, company, instructions].contains { $0?.isEmpty == false }
        }
    }

    public enum Failure: Error, LocalizedError {
        case visionFailed(String)
        case modelUnavailable(String)
        case modelFailed(String)
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .visionFailed(let m): return "OCR failed: \(m)"
            case .modelUnavailable(let m): return "On-device AI unavailable: \(m)"
            case .modelFailed(let m): return "On-device AI extraction failed: \(m)"
            case .parseFailed(let m): return "On-device AI returned malformed output: \(m)"
            }
        }
    }

    public init() {}

    /// Returns true if the structured-extraction step is usable on the
    /// current device. iOS < 26 always returns false; iOS 26+ depends
    /// on whether the on-device model has been provisioned (Apple
    /// Intelligence enabled, model downloaded, etc.).
    public static func isStructuredExtractionAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public func extract(frontJPEG: Data, backJPEG: Data) async throws -> Output {
        async let frontText = recognizeText(in: frontJPEG)
        async let backText = recognizeText(in: backJPEG)
        let (front, back) = try await (frontText, backText)

        if Self.isStructuredExtractionAvailable() {
            do {
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    let parsed = try await runFoundationModels(front: front, back: back)
                    return Output(
                        commonName: parsed.commonName,
                        variety: parsed.variety,
                        company: parsed.company,
                        instructions: parsed.instructions,
                        selfConfidence: parsed.selfConfidence,
                        modelID: Self.modelID,
                        ocrFrontText: front,
                        ocrBackText: back
                    )
                }
                #endif
            } catch {
                // Surface the model failure but keep the OCR text so the
                // caller can decide whether to retry or fall back to
                // manual entry.
                throw Failure.modelFailed(error.localizedDescription)
            }
        }

        // Fallback: OCR succeeded but structured extraction is unavailable.
        return Output(
            commonName: nil, variety: nil, company: nil, instructions: nil,
            selfConfidence: 0,
            modelID: Self.modelID + "+ocr-only",
            ocrFrontText: front,
            ocrBackText: back
        )
    }

    // MARK: - Vision OCR

    private func recognizeText(in jpeg: Data) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let request = VNRecognizeTextRequest { req, err in
                if let err {
                    continuation.resume(throwing: Failure.visionFailed(err.localizedDescription))
                    return
                }
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(data: jpeg, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: Failure.visionFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Foundation Models

    fileprivate struct ParsedFields {
        let commonName: String?
        let variety: String?
        let company: String?
        let instructions: String?
        let selfConfidence: Double
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runFoundationModels(front: String, back: String) async throws -> ParsedFields {
        let session = LanguageModelSession()
        let prompt = """
        You are reading OCR text scanned from the front and back of a seed packet. \
        Extract the listed fields and return ONLY a single JSON object with these exact keys:
          - "common_name": string or null (the plant's common name, e.g. "Tomato", "Sunflower")
          - "variety": string or null (specific cultivar, e.g. "Cherokee Purple")
          - "company": string or null (the seed company that produced the packet)
          - "instructions": string or null (one to three concise sentences distilling the planting instructions)
          - "self_confidence": number from 0.0 to 1.0 estimating how likely your extraction is correct
        Use null for any field the text does not unambiguously support. Do not invent values. Do not include any prose outside the JSON.

        --- FRONT OCR ---
        \(front)
        --- BACK OCR ---
        \(back)
        """

        let response = try await session.respond(to: prompt)
        let raw = response.content
        return try Self.parseJSON(raw)
    }
    #endif

    /// Parse the model's JSON output. Tolerates leading/trailing
    /// whitespace and the occasional markdown code-fence the model may
    /// emit despite instructions.
    fileprivate static func parseJSON(_ raw: String) throws -> ParsedFields {
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
            // Drop the first line ("```json" or just "```").
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
