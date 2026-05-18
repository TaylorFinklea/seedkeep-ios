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
///    structured fields including the horticultural data we surface in
///    SeedDetail and use later in the Phase 2 garden planner.
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
        // Identity
        public let commonName: String?
        public let scientificName: String?
        public let variety: String?
        public let company: String?
        public let instructions: String?
        // Horticultural ranges
        public let daysToGerminateMin: Int?
        public let daysToGerminateMax: Int?
        public let daysToMaturityMin: Int?
        public let daysToMaturityMax: Int?
        public let soilTempMinF: Int?
        public let soilTempMaxF: Int?
        public let seedDepthInches: Double?
        public let plantSpacingInches: Int?
        public let rowSpacingInches: Int?
        public let sunRequirement: String?
        public let frostTolerance: String?
        public let sowMethod: String?
        public let lifeCycle: String?
        public let hardinessZoneMin: Int?
        public let hardinessZoneMax: Int?

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
                        scientificName: parsed.scientificName,
                        variety: parsed.variety,
                        company: parsed.company,
                        instructions: parsed.instructions,
                        daysToGerminateMin: parsed.daysToGerminateMin,
                        daysToGerminateMax: parsed.daysToGerminateMax,
                        daysToMaturityMin: parsed.daysToMaturityMin,
                        daysToMaturityMax: parsed.daysToMaturityMax,
                        soilTempMinF: parsed.soilTempMinF,
                        soilTempMaxF: parsed.soilTempMaxF,
                        seedDepthInches: parsed.seedDepthInches,
                        plantSpacingInches: parsed.plantSpacingInches,
                        rowSpacingInches: parsed.rowSpacingInches,
                        sunRequirement: parsed.sunRequirement,
                        frostTolerance: parsed.frostTolerance,
                        sowMethod: parsed.sowMethod,
                        lifeCycle: parsed.lifeCycle,
                        hardinessZoneMin: parsed.hardinessZoneMin,
                        hardinessZoneMax: parsed.hardinessZoneMax,
                        selfConfidence: parsed.selfConfidence,
                        modelID: Self.modelID,
                        ocrFrontText: front,
                        ocrBackText: back
                    )
                }
                #endif
            } catch {
                throw Failure.modelFailed(error.localizedDescription)
            }
        }

        // Fallback: OCR succeeded but structured extraction is unavailable.
        return Output(
            commonName: nil, scientificName: nil, variety: nil, company: nil, instructions: nil,
            daysToGerminateMin: nil, daysToGerminateMax: nil,
            daysToMaturityMin: nil, daysToMaturityMax: nil,
            soilTempMinF: nil, soilTempMaxF: nil,
            seedDepthInches: nil, plantSpacingInches: nil, rowSpacingInches: nil,
            sunRequirement: nil, frostTolerance: nil, sowMethod: nil, lifeCycle: nil,
            hardinessZoneMin: nil, hardinessZoneMax: nil,
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
        let scientificName: String?
        let variety: String?
        let company: String?
        let instructions: String?
        let daysToGerminateMin: Int?
        let daysToGerminateMax: Int?
        let daysToMaturityMin: Int?
        let daysToMaturityMax: Int?
        let soilTempMinF: Int?
        let soilTempMaxF: Int?
        let seedDepthInches: Double?
        let plantSpacingInches: Int?
        let rowSpacingInches: Int?
        let sunRequirement: String?
        let frostTolerance: String?
        let sowMethod: String?
        let lifeCycle: String?
        let hardinessZoneMin: Int?
        let hardinessZoneMax: Int?
        let selfConfidence: Double
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runFoundationModels(front: String, back: String) async throws -> ParsedFields {
        let session = LanguageModelSession()
        let prompt = """
        You are reading OCR text scanned from the front and back of a seed packet. \
        Extract the listed fields and return ONLY a single JSON object with these exact keys:

        Identity:
          - "common_name": string or null (e.g. "Tomato", "Sunflower")
          - "scientific_name": string or null (binomial, e.g. "Solanum lycopersicum"; only if printed)
          - "variety": string or null (cultivar, e.g. "Cherokee Purple")
          - "company": string or null (the seed company that produced the packet)
          - "instructions": string or null (one to three concise sentences distilling the planting instructions)

        Days-from-sowing ranges:
          - "days_to_germinate_min": int or null
          - "days_to_germinate_max": int or null
          - "days_to_maturity_min": int or null
          - "days_to_maturity_max": int or null

        Environmental requirements:
          - "soil_temp_min_f": int or null (Fahrenheit)
          - "soil_temp_max_f": int or null (Fahrenheit)
          - "seed_depth_inches": number or null (e.g. 0.25 for 1/4 inch)
          - "plant_spacing_inches": int or null
          - "row_spacing_inches": int or null
          - "sun_requirement": "full" | "partial" | "shade" | null
          - "frost_tolerance": "tender" | "half_hardy" | "hardy" | null
          - "sow_method": "direct" | "transplant" | "either" | null
          - "life_cycle": "annual" | "biennial" | "perennial" | null
          - "hardiness_zone_min": int or null (USDA, 1..13)
          - "hardiness_zone_max": int or null (USDA, 1..13)

          - "self_confidence": number from 0.0 to 1.0 (overall extraction confidence)

        Rules:
        - For ranges, if a single number is given use it for both min and max.
        - For "Plant 1/4 inch deep" return seed_depth_inches: 0.25.
        - Use null for any field the text does not unambiguously support. Do not invent values.
        - Do not include any prose outside the JSON.

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
            scientificName: nonEmptyString(object["scientific_name"]),
            variety: nonEmptyString(object["variety"]),
            company: nonEmptyString(object["company"]),
            instructions: nonEmptyString(object["instructions"]),
            daysToGerminateMin: asInt(object["days_to_germinate_min"]),
            daysToGerminateMax: asInt(object["days_to_germinate_max"]),
            daysToMaturityMin: asInt(object["days_to_maturity_min"]),
            daysToMaturityMax: asInt(object["days_to_maturity_max"]),
            soilTempMinF: asInt(object["soil_temp_min_f"]),
            soilTempMaxF: asInt(object["soil_temp_max_f"]),
            seedDepthInches: asDouble(object["seed_depth_inches"]),
            plantSpacingInches: asInt(object["plant_spacing_inches"]),
            rowSpacingInches: asInt(object["row_spacing_inches"]),
            sunRequirement: enumValue(object["sun_requirement"], allowed: ["full", "partial", "shade"]),
            frostTolerance: enumValue(object["frost_tolerance"], allowed: ["tender", "half_hardy", "hardy"]),
            sowMethod: enumValue(object["sow_method"], allowed: ["direct", "transplant", "either"]),
            lifeCycle: enumValue(object["life_cycle"], allowed: ["annual", "biennial", "perennial"]),
            hardinessZoneMin: asInt(object["hardiness_zone_min"]),
            hardinessZoneMax: asInt(object["hardiness_zone_max"]),
            selfConfidence: max(0, min(1, conf))
        )
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func asInt(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let d = raw as? Double { return Int(d.rounded()) }
        if let s = raw as? String, let n = Int(s) { return n }
        return nil
    }

    private static func asDouble(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let n = raw as? Int { return Double(n) }
        if let s = raw as? String, let d = Double(s) { return d }
        return nil
    }

    private static func enumValue(_ raw: Any?, allowed: [String]) -> String? {
        guard let s = raw as? String else { return nil }
        let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowed.contains(lower) ? lower : nil
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
