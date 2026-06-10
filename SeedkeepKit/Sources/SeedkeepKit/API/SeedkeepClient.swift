import Foundation

/// Lightweight HTTP client that knows how to talk to the Seedkeep Workers
/// backend.
///
/// Design notes:
///   - Sendable & actor-isolated. The mutable bearer token lives inside an
///     actor so calls from arbitrary tasks are safe.
///   - Envelope-aware. Every JSON response goes through `Envelope<T>` and
///     a non-`ok: true` body becomes a thrown `SeedkeepError` instead of a
///     half-decoded value.
///   - Transport is injected via `URLSession`, so unit tests can stub the
///     network with `URLProtocol`.
public actor SeedkeepClient {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var session: URLSession

        public init(baseURL: URL, session: URLSession = .shared) {
            self.baseURL = baseURL
            self.session = session
        }
    }

    public private(set) var configuration: Configuration
    public private(set) var bearerToken: String?

    public init(configuration: Configuration, bearerToken: String? = nil) {
        self.configuration = configuration
        self.bearerToken = bearerToken
    }

    public func setBearerToken(_ token: String?) {
        self.bearerToken = token
    }

    public func setBaseURL(_ url: URL) {
        self.configuration.baseURL = url
    }

    // MARK: - Health

    public func health() async throws -> HealthResponse {
        try await getJSON(path: "/api/health", auth: false)
    }

    public struct HealthResponse: Codable, Sendable, Equatable {
        public let status: String
        public let env: String
    }

    // MARK: - Identity

    public func me() async throws -> WireResponses.Me {
        try await getJSON(path: "/api/me")
    }

    // MARK: - Households

    public func createOrFetchHousehold(name: String? = nil) async throws -> WireResponses.CreateOrFetchHousehold {
        struct Body: Encodable { let name: String? }
        return try await postJSON(path: "/api/households", body: Body(name: name))
    }

    public func household() async throws -> WireResponses.Members {
        try await getJSON(path: "/api/households/me")
    }

    public func createInvite() async throws -> WireResponses.Invite {
        try await postJSON(path: "/api/households/me/invites", body: EmptyBody())
    }

    public func acceptInvite(code: String) async throws -> WireResponses.CreateOrFetchHousehold {
        try await postJSON(path: "/api/invites/\(code)/accept", body: EmptyBody())
    }

    // MARK: - Watering state (Phase 4C)

    /// Household-scoped last-watering-notification timestamp. The server
    /// stores this as `households.last_watering_notification_at` (TIMESTAMPTZ
    /// nullable); the wire shape is an ISO-8601 string OR JSON null. The
    /// custom Codable conformance below handles both directions so the
    /// rest of the client can deal in `Date?`.
    ///
    /// Spec: §7 (server piece) and §3 (SeedkeepKit additions). Phase 4C
    /// is the only consumer in v1 — watering-reminder dedup across the
    /// household's devices.
    public struct WateringStateDTO: Codable, Sendable, Equatable {
        public let lastWateringNotificationAt: Date?

        public init(lastWateringNotificationAt: Date?) {
            self.lastWateringNotificationAt = lastWateringNotificationAt
        }

        public enum CodingKeys: String, CodingKey {
            case lastWateringNotificationAt = "last_watering_notification_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try c.decodeIfPresent(String.self, forKey: .lastWateringNotificationAt) {
                self.lastWateringNotificationAt = Self.parseTimestamp(s)
            } else {
                self.lastWateringNotificationAt = nil
            }
        }

        /// Parses the wire timestamp. Primary shape is ISO-8601 `T`+`Z`
        /// (`2026-06-15T13:30:00.000Z`, with or without fractional
        /// seconds). Also tolerates Postgres `::text` renderings —
        /// space separator and abbreviated offset, e.g.
        /// `2026-06-09 18:25:43.511+00` — so a server-side
        /// serialization regression can't silently null the household
        /// watering ledger again.
        static func parseTimestamp(_ s: String) -> Date? {
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = withFractional.date(from: s) ?? plain.date(from: s) {
                return date
            }
            // Postgres text fallback: normalize into strict ISO-8601
            // and retry.
            var normalized = s
            if let spaceIdx = normalized.firstIndex(of: " ") {
                normalized.replaceSubrange(spaceIdx...spaceIdx, with: "T")
            }
            if normalized.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil {
                // Abbreviated two-digit offset ("+00") → "+00:00".
                normalized += ":00"
            } else if normalized.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil,
                      !normalized.hasSuffix("Z") {
                // No offset at all — treat as UTC.
                normalized += "Z"
            }
            return withFractional.date(from: normalized) ?? plain.date(from: normalized)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let date = lastWateringNotificationAt {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                try c.encode(f.string(from: date), forKey: .lastWateringNotificationAt)
            } else {
                try c.encodeNil(forKey: .lastWateringNotificationAt)
            }
        }
    }

    /// `GET /api/households/:id/watering-state` — returns the household's
    /// last-watering-notification timestamp (or null if the household has
    /// never scheduled one).
    public func getWateringState(householdID: String) async throws -> WateringStateDTO {
        try await getJSON(path: "/api/households/\(householdID)/watering-state")
    }

    /// `POST /api/households/:id/watering-state` — records a scheduled
    /// watering notification. The server takes `max(existing, scheduled_for)`
    /// so retries and out-of-order POSTs are idempotent and monotonic.
    public func putWateringState(householdID: String, scheduledFor: Date) async throws -> WateringStateDTO {
        struct Body: Encodable {
            let scheduled_for: String
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try await postJSON(
            path: "/api/households/\(householdID)/watering-state",
            body: Body(scheduled_for: f.string(from: scheduledFor))
        )
    }

    // MARK: - Locations

    public func locations(since: Int64 = 0, sinceID: String? = nil, limit: Int? = nil) async throws -> DeltaPage<LocationDTO> {
        try await getJSON(path: "/api/locations", query: deltaQuery(since: since, sinceID: sinceID, limit: limit))
    }

    /// `id` is the optional client-supplied row id (stabilization contract
    /// decision 7, seeds pattern): the server stores it verbatim, so the
    /// local optimistic row's id stays valid after the create syncs.
    public func createLocation(id: String? = nil, name: String, sortOrder: Int = 0) async throws -> LocationDTO {
        struct Body: Encodable { let id: String?; let name: String; let sort_order: Int }
        let res: WireResponses.LocationOne = try await postJSON(
            path: "/api/locations",
            body: Body(id: id, name: name, sort_order: sortOrder)
        )
        return res.location
    }

    public func updateLocation(id: String, name: String? = nil, sortOrder: Int? = nil) async throws -> LocationDTO {
        struct Body: Encodable {
            let name: String?
            let sort_order: Int?
        }
        let res: WireResponses.LocationOne = try await patchJSON(
            path: "/api/locations/\(id)",
            body: Body(name: name, sort_order: sortOrder)
        )
        return res.location
    }

    @discardableResult
    public func deleteLocation(id: String) async throws -> DeleteResult {
        try await deleteJSON(path: "/api/locations/\(id)")
    }

    // MARK: - Tags

    public func tags(since: Int64 = 0, sinceID: String? = nil, limit: Int? = nil) async throws -> DeltaPage<TagDTO> {
        try await getJSON(path: "/api/tags", query: deltaQuery(since: since, sinceID: sinceID, limit: limit))
    }

    /// `id` is the optional client-supplied row id (contract decision 7).
    public func createTag(id: String? = nil, name: String, color: String? = nil) async throws -> TagDTO {
        struct Body: Encodable { let id: String?; let name: String; let color: String? }
        let res: WireResponses.TagOne = try await postJSON(
            path: "/api/tags",
            body: Body(id: id, name: name, color: color)
        )
        return res.tag
    }

    public func updateTag(id: String, name: String? = nil, color: String?? = nil) async throws -> TagDTO {
        // `color: String??` lets callers express "leave alone" (nil), "set null"
        // (.some(nil)), or "set to value" (.some(v)). Mirrors PATCH semantics.
        struct Body: Encodable {
            let name: String?
            let color: String?
            let _setColor: Bool

            enum CodingKeys: String, CodingKey { case name, color }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let name { try c.encode(name, forKey: .name) }
                if _setColor { try c.encode(color, forKey: .color) }
            }
        }
        let body = Body(
            name: name,
            color: color.flatMap { $0 },
            _setColor: color != nil
        )
        let res: WireResponses.TagOne = try await patchJSON(
            path: "/api/tags/\(id)",
            body: body
        )
        return res.tag
    }

    @discardableResult
    public func deleteTag(id: String) async throws -> DeleteResult {
        try await deleteJSON(path: "/api/tags/\(id)")
    }

    // MARK: - Seeds

    public struct SeedFilters: Sendable {
        public var state: SeedState?
        public var locationID: String?
        public var tagID: String?

        public init(state: SeedState? = nil, locationID: String? = nil, tagID: String? = nil) {
            self.state = state
            self.locationID = locationID
            self.tagID = tagID
        }
    }

    public func seeds(
        since: Int64 = 0,
        sinceID: String? = nil,
        limit: Int? = nil,
        filters: SeedFilters = .init()
    ) async throws -> DeltaPage<SeedDTO> {
        var q = deltaQuery(since: since, sinceID: sinceID, limit: limit)
        if let s = filters.state { q.append(.init(name: "state", value: s.rawValue)) }
        if let l = filters.locationID { q.append(.init(name: "location_id", value: l)) }
        if let t = filters.tagID { q.append(.init(name: "tag_id", value: t)) }
        return try await getJSON(path: "/api/seeds", query: q)
    }

    public func seed(id: String) async throws -> WireResponses.SeedDetail {
        try await getJSON(path: "/api/seeds/\(id)")
    }

    /// Uploads a single packet photo for an existing seed. The server
    /// stores the bytes in R2 and inserts a `seed_photos` row.
    public func uploadSeedPhoto(
        seedID: String,
        role: PhotoRole,
        jpegData: Data
    ) async throws -> SeedPhotoDTO {
        struct PhotoOne: Codable, Sendable { let photo: SeedPhotoDTO }

        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("/api/seeds/\(seedID)/photos"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [.init(name: "role", value: role.rawValue)]
        guard let url = components?.url else {
            throw SeedkeepError(code: "bad_url", message: "Could not construct upload URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = jpegData
        let res: PhotoOne = try await perform(req)
        return res.photo
    }

    /// Fetches a single photo's binary content. The Worker streams from R2;
    /// the response body is the raw JPEG bytes (no envelope).
    public func fetchSeedPhotoData(photoID: String) async throws -> Data {
        let url = configuration.baseURL.appendingPathComponent("/api/photos/\(photoID)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await configuration.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SeedkeepError(code: "fetch_failed", message: "Could not fetch photo bytes")
        }
        return data
    }

    public struct CreateSeedInput: Codable, Sendable {
        public var id: String?
        public var catalog_id: String?
        public var state: SeedState
        public var packet_count: Int
        public var location_id: String?
        public var year_packed: Int?
        public var source: SeedSource
        public var custom_name: String?
        public var custom_variety: String?
        public var custom_company: String?
        public var notes: String?
        public var tag_ids: [String]?

        public init(
            id: String? = nil,
            catalog_id: String? = nil,
            state: SeedState,
            packet_count: Int = 1,
            location_id: String? = nil,
            year_packed: Int? = nil,
            source: SeedSource = .store,
            custom_name: String? = nil,
            custom_variety: String? = nil,
            custom_company: String? = nil,
            notes: String? = nil,
            tag_ids: [String]? = nil
        ) {
            self.id = id
            self.catalog_id = catalog_id
            self.state = state
            self.packet_count = packet_count
            self.location_id = location_id
            self.year_packed = year_packed
            self.source = source
            self.custom_name = custom_name
            self.custom_variety = custom_variety
            self.custom_company = custom_company
            self.notes = notes
            self.tag_ids = tag_ids
        }
    }

    public func createSeed(_ input: CreateSeedInput) async throws -> SeedDTO {
        let res: WireResponses.SeedOne = try await postJSON(path: "/api/seeds", body: input)
        return res.seed
    }

    /// All-optional patch payload for `PATCH /api/seeds/:id`. Encoder skips
    /// omitted keys so the server receives only the fields the caller wants
    /// to change.
    ///
    /// The server-nullable fields (`location_id`, `year_packed`,
    /// `custom_name`, `custom_variety`, `custom_company`, `notes`) use the
    /// double-optional explicit-null pattern (stabilization contract
    /// decision 8, mirroring `UpdateJournalEntryInput`): omit (`nil`) =
    /// "leave alone", `.some(nil)` = JSON null = "clear", `.some(value)` =
    /// set. The hand-rolled Codable below preserves that distinction in
    /// both directions so queued pending-write payloads round-trip.
    public struct UpdateSeedInput: Codable, Sendable {
        public var catalog_id: String?
        public var state: SeedState?
        public var packet_count: Int?
        public var location_id: String??
        public var year_packed: Int??
        public var source: SeedSource?
        public var custom_name: String??
        public var custom_variety: String??
        public var custom_company: String??
        public var notes: String??
        public var tag_ids: [String]?

        public init(
            catalog_id: String? = nil,
            state: SeedState? = nil,
            packet_count: Int? = nil,
            location_id: String?? = nil,
            year_packed: Int?? = nil,
            source: SeedSource? = nil,
            custom_name: String?? = nil,
            custom_variety: String?? = nil,
            custom_company: String?? = nil,
            notes: String?? = nil,
            tag_ids: [String]? = nil
        ) {
            self.catalog_id = catalog_id
            self.state = state
            self.packet_count = packet_count
            self.location_id = location_id
            self.year_packed = year_packed
            self.source = source
            self.custom_name = custom_name
            self.custom_variety = custom_variety
            self.custom_company = custom_company
            self.notes = notes
            self.tag_ids = tag_ids
        }

        private enum CodingKeys: String, CodingKey {
            case catalog_id, state, packet_count, location_id, year_packed
            case source, custom_name, custom_variety, custom_company, notes
            case tag_ids
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            catalog_id = try c.decodeIfPresent(String.self, forKey: .catalog_id)
            state = try c.decodeIfPresent(SeedState.self, forKey: .state)
            packet_count = try c.decodeIfPresent(Int.self, forKey: .packet_count)
            location_id = try Self.decodeNullable(String.self, from: c, forKey: .location_id)
            year_packed = try Self.decodeNullable(Int.self, from: c, forKey: .year_packed)
            source = try c.decodeIfPresent(SeedSource.self, forKey: .source)
            custom_name = try Self.decodeNullable(String.self, from: c, forKey: .custom_name)
            custom_variety = try Self.decodeNullable(String.self, from: c, forKey: .custom_variety)
            custom_company = try Self.decodeNullable(String.self, from: c, forKey: .custom_company)
            notes = try Self.decodeNullable(String.self, from: c, forKey: .notes)
            tag_ids = try c.decodeIfPresent([String].self, forKey: .tag_ids)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let v = catalog_id { try c.encode(v, forKey: .catalog_id) }
            if let v = state { try c.encode(v, forKey: .state) }
            if let v = packet_count { try c.encode(v, forKey: .packet_count) }
            // `.some(nil)` encodes JSON null; omitted keys aren't written.
            if let v = location_id { try c.encode(v, forKey: .location_id) }
            if let v = year_packed { try c.encode(v, forKey: .year_packed) }
            if let v = source { try c.encode(v, forKey: .source) }
            if let v = custom_name { try c.encode(v, forKey: .custom_name) }
            if let v = custom_variety { try c.encode(v, forKey: .custom_variety) }
            if let v = custom_company { try c.encode(v, forKey: .custom_company) }
            if let v = notes { try c.encode(v, forKey: .notes) }
            if let v = tag_ids { try c.encode(v, forKey: .tag_ids) }
        }

        /// Decodes a double-optional field: absent key → `nil` (leave
        /// alone), JSON null → `.some(nil)` (clear), value → `.some(value)`.
        private static func decodeNullable<T: Decodable>(
            _ type: T.Type,
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws -> T?? {
            guard container.contains(key) else { return nil }
            if try container.decodeNil(forKey: key) { return .some(nil) }
            return .some(try container.decode(T.self, forKey: key))
        }
    }

    public func updateSeed(id: String, _ patch: UpdateSeedInput) async throws -> SeedDTO {
        let res: WireResponses.SeedOne = try await patchJSON(path: "/api/seeds/\(id)", body: patch)
        return res.seed
    }

    @discardableResult
    public func deleteSeed(id: String) async throws -> DeleteResult {
        try await deleteJSON(path: "/api/seeds/\(id)")
    }

    public func randomSeed() async throws -> SeedDTO? {
        struct SeedEnvelope: Codable, Sendable { let seed: SeedDTO? }
        do {
            let res: SeedEnvelope = try await getJSON(path: "/api/seeds/random")
            return res.seed
        } catch let err as SeedkeepError where err.code == "no_seeds" {
            return nil
        }
    }

    // MARK: - Extraction

    /// Submits a packet front + back photo pair to `/api/extractions`.
    /// The Worker uploads both images to R2, calls the vision LLM, then
    /// the reviewer LLM, and returns the decision (`published` | `pending`
    /// | `rejected`) plus the extracted fields. Phase 1 is synchronous —
    /// expect 8–15 seconds; the iOS client should show a spinner.
    ///
    /// `barcode` and `perceptualHash` are optional optimization hints —
    /// pass them when the camera detected one. The server uses them for
    /// dedup against existing catalog entries.
    public func submitExtraction(
        frontJPEG: Data,
        backJPEG: Data,
        barcode: String? = nil,
        perceptualHash: String? = nil
    ) async throws -> WireResponses.ExtractionResult {
        let url = configuration.baseURL.appendingPathComponent("/api/extractions")
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        body.appendField(boundary: boundary, name: "front", filename: "front.jpg",
                         contentType: "image/jpeg", payload: frontJPEG)
        body.appendField(boundary: boundary, name: "back", filename: "back.jpg",
                         contentType: "image/jpeg", payload: backJPEG)
        if let barcode {
            body.appendTextField(boundary: boundary, name: "barcode", value: barcode)
        }
        if let perceptualHash {
            body.appendTextField(boundary: boundary, name: "perceptual_hash", value: perceptualHash)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        req.httpBody = body
        return try await perform(req)
    }

    /// Body for `POST /api/extractions/pre-extracted`. The client extracts
    /// fields on-device (Apple Foundation Models, OpenAI, Anthropic, etc.)
    /// and sends the structured result + optional packet photos. Server
    /// runs no LLM call — it persists, dedupes, and applies the catalog
    /// decision based on the client-supplied `self_confidence`.
    public struct PreExtractedInput: Codable, Sendable {
        public var common_name: String?
        public var scientific_name: String?
        public var variety: String?
        public var company: String?
        public var instructions: String?
        // Horticultural data — every field optional; the extractor fills
        // whatever the packet shows. Encoded as flat snake_case to match
        // server's zod schema.
        public var days_to_germinate_min: Int?
        public var days_to_germinate_max: Int?
        public var days_to_maturity_min: Int?
        public var days_to_maturity_max: Int?
        public var soil_temp_min_f: Int?
        public var soil_temp_max_f: Int?
        public var seed_depth_inches: Double?
        public var plant_spacing_inches: Int?
        public var row_spacing_inches: Int?
        public var sun_requirement: String?
        public var frost_tolerance: String?
        public var sow_method: String?
        public var life_cycle: String?
        public var hardiness_zone_min: Int?
        public var hardiness_zone_max: Int?

        public var self_confidence: Double
        public var model_id: String
        public var barcode: String?
        public var perceptual_hash: String?
        public var front_jpeg_b64: String?
        public var back_jpeg_b64: String?

        public init(
            common_name: String?,
            scientific_name: String? = nil,
            variety: String?,
            company: String?,
            instructions: String?,
            days_to_germinate_min: Int? = nil,
            days_to_germinate_max: Int? = nil,
            days_to_maturity_min: Int? = nil,
            days_to_maturity_max: Int? = nil,
            soil_temp_min_f: Int? = nil,
            soil_temp_max_f: Int? = nil,
            seed_depth_inches: Double? = nil,
            plant_spacing_inches: Int? = nil,
            row_spacing_inches: Int? = nil,
            sun_requirement: String? = nil,
            frost_tolerance: String? = nil,
            sow_method: String? = nil,
            life_cycle: String? = nil,
            hardiness_zone_min: Int? = nil,
            hardiness_zone_max: Int? = nil,
            self_confidence: Double,
            model_id: String,
            barcode: String? = nil,
            perceptual_hash: String? = nil,
            front_jpeg_b64: String? = nil,
            back_jpeg_b64: String? = nil
        ) {
            self.common_name = common_name
            self.scientific_name = scientific_name
            self.variety = variety
            self.company = company
            self.instructions = instructions
            self.days_to_germinate_min = days_to_germinate_min
            self.days_to_germinate_max = days_to_germinate_max
            self.days_to_maturity_min = days_to_maturity_min
            self.days_to_maturity_max = days_to_maturity_max
            self.soil_temp_min_f = soil_temp_min_f
            self.soil_temp_max_f = soil_temp_max_f
            self.seed_depth_inches = seed_depth_inches
            self.plant_spacing_inches = plant_spacing_inches
            self.row_spacing_inches = row_spacing_inches
            self.sun_requirement = sun_requirement
            self.frost_tolerance = frost_tolerance
            self.sow_method = sow_method
            self.life_cycle = life_cycle
            self.hardiness_zone_min = hardiness_zone_min
            self.hardiness_zone_max = hardiness_zone_max
            self.self_confidence = self_confidence
            self.model_id = model_id
            self.barcode = barcode
            self.perceptual_hash = perceptual_hash
            self.front_jpeg_b64 = front_jpeg_b64
            self.back_jpeg_b64 = back_jpeg_b64
        }
    }

    public func submitPreExtracted(_ input: PreExtractedInput) async throws -> WireResponses.PreExtractedResult {
        try await postJSON(path: "/api/extractions/pre-extracted", body: input)
    }

    // MARK: - Subscriptions

    /// Response from `GET /api/subscriptions/me` and the `tier` portion of
    /// `POST /api/subscriptions/verify`.
    public struct SubscriptionMeResponse: Codable, Sendable, Equatable {
        public let tier: String   // "free" | "byok" | "hosted"
        public let subscription: SubscriptionDTO?
    }

    public struct SubscriptionDTO: Codable, Sendable, Equatable {
        public let id: String
        public let user_id: String
        public let product_id: String
        public let original_transaction_id: String
        public let latest_transaction_id: String
        public let status: String   // "active" | "expired" | "cancelled" | "refunded"
        public let expires_at: Int64
        public let last_verified_at: Int64
        public let environment: String   // "production" | "sandbox"
        public let created_at: Int64
        public let updated_at: Int64
    }

    /// Reads the authenticated user's subscription state. Used at app
    /// launch to learn the current tier (`free` / `byok` / `hosted`).
    public func subscriptionMe() async throws -> SubscriptionMeResponse {
        try await getJSON(path: "/api/subscriptions/me")
    }

    /// Result of validating a StoreKit receipt against the server.
    public struct VerifyReceiptResponse: Codable, Sendable, Equatable {
        public let tier: String
        public let environment: String
        public let subscription: VerifiedSubscription

        public struct VerifiedSubscription: Codable, Sendable, Equatable {
            public let product_id: String
            public let original_transaction_id: String
            public let status: String
            public let expires_at: Int64
        }
    }

    /// Posts the StoreKit receipt blob (base64-encoded contents of
    /// `Bundle.main.appStoreReceiptURL`) to the server. The server hits
    /// Apple's /verifyReceipt, persists the subscription, and flips the
    /// user's tier to `hosted` while the subscription is active.
    public func verifyAppleReceipt(receiptDataB64: String) async throws -> VerifyReceiptResponse {
        struct Body: Encodable { let receipt_data: String }
        return try await postJSON(
            path: "/api/subscriptions/verify",
            body: Body(receipt_data: receiptDataB64)
        )
    }

    // MARK: - Beds (Phase 2)

    public func beds(since: Int64 = 0, sinceID: String? = nil, limit: Int? = nil) async throws -> DeltaPage<BedDTO> {
        try await getJSON(path: "/api/beds", query: deltaQuery(since: since, sinceID: sinceID, limit: limit))
    }

    public struct CreateBedInput: Codable, Sendable {
        /// Optional client-supplied row id (contract decision 7, seeds
        /// pattern). The server stores it verbatim so the local optimistic
        /// row's id survives the create sync.
        public var id: String?
        public var name: String
        public var description: String?
        public var width_feet: Double?
        public var length_feet: Double?
        public var sort_order: Int?
        public init(id: String? = nil, name: String, description: String? = nil, width_feet: Double? = nil, length_feet: Double? = nil, sort_order: Int? = nil) {
            self.id = id
            self.name = name
            self.description = description
            self.width_feet = width_feet
            self.length_feet = length_feet
            self.sort_order = sort_order
        }
    }

    public func createBed(_ input: CreateBedInput) async throws -> BedDTO {
        let res: WireResponses.BedOne = try await postJSON(path: "/api/beds", body: input)
        return res.bed
    }

    public struct UpdateBedInput: Codable, Sendable {
        public var name: String?
        public var description: String?
        public var width_feet: Double?
        public var length_feet: Double?
        public var sort_order: Int?
        public init(name: String? = nil, description: String? = nil, width_feet: Double? = nil, length_feet: Double? = nil, sort_order: Int? = nil) {
            self.name = name
            self.description = description
            self.width_feet = width_feet
            self.length_feet = length_feet
            self.sort_order = sort_order
        }
    }

    public func updateBed(id: String, _ input: UpdateBedInput) async throws -> BedDTO {
        let res: WireResponses.BedOne = try await patchJSON(path: "/api/beds/\(id)", body: input)
        return res.bed
    }

    @discardableResult
    public func deleteBed(id: String) async throws -> DeleteResult {
        try await deleteJSON(path: "/api/beds/\(id)")
    }

    // MARK: - Planting events (Phase 2)

    public func plantingEvents(since: Int64 = 0, sinceID: String? = nil, limit: Int? = nil) async throws -> DeltaPage<PlantingEventDTO> {
        try await getJSON(path: "/api/planting-events", query: deltaQuery(since: since, sinceID: sinceID, limit: limit))
    }

    public struct CreatePlantingEventInput: Codable, Sendable {
        /// Optional client-supplied row id (contract decision 7, seeds
        /// pattern). Keeping the local id stable means the reminder
        /// scheduled at enqueue time survives the create sync.
        public var id: String?
        public var bed_id: String?
        public var seed_id: String?
        public var catalog_seed_id: String?
        public var kind: String
        public var planned_for: String   // YYYY-MM-DD
        public var completed_at: Int64?
        public var notes: String?
        public var x_feet: Double?
        public var y_feet: Double?
        public init(
            id: String? = nil,
            bed_id: String? = nil,
            seed_id: String? = nil,
            catalog_seed_id: String? = nil,
            kind: PlantingEventKind,
            planned_for: String,
            completed_at: Int64? = nil,
            notes: String? = nil,
            x_feet: Double? = nil,
            y_feet: Double? = nil
        ) {
            self.id = id
            self.bed_id = bed_id
            self.seed_id = seed_id
            self.catalog_seed_id = catalog_seed_id
            self.kind = kind.rawValue
            self.planned_for = planned_for
            self.completed_at = completed_at
            self.notes = notes
            self.x_feet = x_feet
            self.y_feet = y_feet
        }
    }

    public func createPlantingEvent(_ input: CreatePlantingEventInput) async throws -> PlantingEventDTO {
        let res: WireResponses.PlantingEventOne = try await postJSON(path: "/api/planting-events", body: input)
        return res.planting_event
    }

    /// `completed_at` is double-optional (stabilization contract decision
    /// 8): omit (`nil`) = leave alone, `.some(nil)` = JSON null =
    /// un-complete ("mark incomplete"), `.some(ms)` = completed at that
    /// instant. The previous `completed_at: 0` sentinel stored "completed
    /// Jan 1 1970" server-wide; nothing maps 0 → null.
    public struct UpdatePlantingEventInput: Codable, Sendable {
        public var bed_id: String?
        public var seed_id: String?
        public var catalog_seed_id: String?
        public var kind: String?
        public var planned_for: String?
        public var completed_at: Int64??
        public var notes: String?
        public var x_feet: Double?
        public var y_feet: Double?
        public init(
            bed_id: String? = nil,
            seed_id: String? = nil,
            catalog_seed_id: String? = nil,
            kind: PlantingEventKind? = nil,
            planned_for: String? = nil,
            completed_at: Int64?? = nil,
            notes: String? = nil,
            x_feet: Double? = nil,
            y_feet: Double? = nil
        ) {
            self.bed_id = bed_id
            self.seed_id = seed_id
            self.catalog_seed_id = catalog_seed_id
            self.kind = kind?.rawValue
            self.planned_for = planned_for
            self.completed_at = completed_at
            self.notes = notes
            self.x_feet = x_feet
            self.y_feet = y_feet
        }

        private enum CodingKeys: String, CodingKey {
            case bed_id, seed_id, catalog_seed_id, kind, planned_for
            case completed_at, notes, x_feet, y_feet
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bed_id = try c.decodeIfPresent(String.self, forKey: .bed_id)
            seed_id = try c.decodeIfPresent(String.self, forKey: .seed_id)
            catalog_seed_id = try c.decodeIfPresent(String.self, forKey: .catalog_seed_id)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            planned_for = try c.decodeIfPresent(String.self, forKey: .planned_for)
            if c.contains(.completed_at) {
                if try c.decodeNil(forKey: .completed_at) {
                    completed_at = .some(nil)
                } else {
                    completed_at = .some(try c.decode(Int64.self, forKey: .completed_at))
                }
            } else {
                completed_at = nil
            }
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
            x_feet = try c.decodeIfPresent(Double.self, forKey: .x_feet)
            y_feet = try c.decodeIfPresent(Double.self, forKey: .y_feet)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let v = bed_id { try c.encode(v, forKey: .bed_id) }
            if let v = seed_id { try c.encode(v, forKey: .seed_id) }
            if let v = catalog_seed_id { try c.encode(v, forKey: .catalog_seed_id) }
            if let v = kind { try c.encode(v, forKey: .kind) }
            if let v = planned_for { try c.encode(v, forKey: .planned_for) }
            // `.some(nil)` encodes JSON null (un-complete).
            if let v = completed_at { try c.encode(v, forKey: .completed_at) }
            if let v = notes { try c.encode(v, forKey: .notes) }
            if let v = x_feet { try c.encode(v, forKey: .x_feet) }
            if let v = y_feet { try c.encode(v, forKey: .y_feet) }
        }
    }

    public func updatePlantingEvent(id: String, _ input: UpdatePlantingEventInput) async throws -> PlantingEventDTO {
        let res: WireResponses.PlantingEventOne = try await patchJSON(path: "/api/planting-events/\(id)", body: input)
        return res.planting_event
    }

    @discardableResult
    public func deletePlantingEvent(id: String) async throws -> DeleteResult {
        try await deleteJSON(path: "/api/planting-events/\(id)")
    }

    // MARK: - Plant pets (Phase 5.1.1)

    /// `POST /api/pets/:planting_event_id/depart` — request the server to
    /// stamp this pet's departure. Idempotent on the server side: a second
    /// call returns the same row, byte-identical, with no new Sprout call.
    /// Concurrent calls from sibling devices are serialised by the route's
    /// row-level lock, so racing this with another foreground tick is safe.
    ///
    /// `reason` defaults to `nil`, which the server treats as
    /// `wilted_too_long` (the dominant trigger — iOS hits this after the
    /// 5-day streak). The other reason values (`inactivity`,
    /// `user_dismissed`) are reserved but unused in v1.
    public func requestPetDeparture(
        plantingEventID: String,
        reason: String? = nil
    ) async throws -> (event: PlantingEventDTO, departure: PetDepartureDTO) {
        struct Body: Encodable { let reason: String? }
        let res: WireResponses.PetDepartureOne = try await postJSON(
            path: "/api/pets/\(plantingEventID)/depart",
            body: Body(reason: reason)
        )
        return (event: res.planting_event, departure: res.departure)
    }

    /// `GET /api/pets/departures` — delta-sync feed for cross-device
    /// fan-out of departure rows. Mirrors the standard
    /// `{ items, cursor, has_more }` envelope used by every other pull
    /// endpoint. Tombstoned rows ride the same channel via `deleted_at`.
    public func petDepartures(
        since: Int64 = 0,
        sinceID: String? = nil,
        limit: Int? = nil
    ) async throws -> DeltaPage<PetDepartureDTO> {
        try await getJSON(
            path: "/api/pets/departures",
            query: deltaQuery(since: since, sinceID: sinceID, limit: limit)
        )
    }

    // MARK: - Recommendations

    /// Sets (or updates) the geographic location for the current household.
    /// The server resolves the zip code to lat/lon, USDA zone, and frost dates.
    public func setHouseholdLocation(zip: String) async throws -> HouseholdLocationDTO {
        struct Body: Encodable { let zip: String }
        return try await sendJSON(method: "PUT", path: "/api/households/me/location", body: Body(zip: zip))
    }

    /// Fetches a cached planting recommendation for a single catalog seed.
    public func recommendation(catalogSeedID: String) async throws -> RecommendationDTO {
        try await getJSON(path: "/api/recommendations/\(catalogSeedID)")
    }

    /// Requests planting recommendations for multiple catalog seeds in one
    /// round-trip. Seeds whose recommendations are still computing are
    /// returned in `pending`.
    public func bulkRecommendations(catalogSeedIDs: [String]) async throws -> WireRecommendation.BulkResponse {
        struct Body: Encodable { let catalogSeedIds: [String] }
        return try await postJSON(path: "/api/recommendations/bulk", body: Body(catalogSeedIds: catalogSeedIDs))
    }

    // MARK: - Catalog

    public func catalogLookup(barcode: String) async throws -> CatalogSeedDTO? {
        struct Body: Codable, Sendable { let catalog_seed: CatalogSeedDTO? }
        let res: Body = try await getJSON(path: "/api/catalog/lookup", query: [.init(name: "barcode", value: barcode)])
        return res.catalog_seed
    }

    /// Fetch a single catalog entry by id. Returns nil on 404 (e.g. an
    /// entry that was never published or has been removed) so the caller
    /// can fall back to showing just the per-household custom fields.
    public func catalogByID(_ id: String) async throws -> CatalogSeedDTO? {
        struct Body: Codable, Sendable { let catalog_seed: CatalogSeedDTO }
        do {
            let res: Body = try await getJSON(path: "/api/catalog/\(id)")
            return res.catalog_seed
        } catch let err as SeedkeepError where err.code == "not_found" {
            return nil
        }
    }

    /// Server response for any DELETE that soft-deletes a per-household row.
    public struct DeleteResult: Decodable, Sendable, Equatable {
        public let id: String
        public let deleted_at: Int64?
    }

    /// Phase 4 D · submit a structured catalog correction or free-form note.
    ///
    /// The legacy two-arg call (only `catalogID` + `body`) still works for
    /// the original "suggest a correction" path; the additional fields land
    /// on the extended `POST /api/catalog/:id/feedback` route. Pass an
    /// `idempotencyKey` to make the request safe to retry — the server
    /// stores it under a partial unique index on `(idempotency_key, user_id)`
    /// and returns the original row on replay.
    ///
    /// On a 409 `open_correction_exists` the server returns the conflicting
    /// `CatalogCorrectionDTO` alongside the error envelope; the response is
    /// translated to a `SubmitFeedbackResponse` with `existingDTO` populated
    /// and `status == "open_correction_exists"`.
    public func submitCatalogFeedback(
        catalogID: String,
        body: String,
        fieldHint: String? = nil,
        fieldName: String? = nil,
        suggestedValue: String? = nil,
        clientSeenValue: String? = nil,
        userAcknowledgedBounds: Bool = false,
        idempotencyKey: String? = nil
    ) async throws -> SubmitFeedbackResponse {
        struct Input: Encodable, Sendable {
            let body: String
            let field_hint: String?
            let field_name: String?
            let suggested_value: String?
            let client_seen_value: String?
            let user_acknowledged_bounds: Bool?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(body, forKey: .body)
                if let field_hint { try c.encode(field_hint, forKey: .field_hint) }
                if let field_name { try c.encode(field_name, forKey: .field_name) }
                if let suggested_value { try c.encode(suggested_value, forKey: .suggested_value) }
                if let client_seen_value {
                    try c.encode(client_seen_value, forKey: .client_seen_value)
                }
                if let user_acknowledged_bounds {
                    try c.encode(user_acknowledged_bounds, forKey: .user_acknowledged_bounds)
                }
            }
            enum CodingKeys: String, CodingKey {
                case body
                case field_hint
                case field_name
                case suggested_value
                case client_seen_value
                case user_acknowledged_bounds
            }
        }

        // Submission is hand-rolled because (a) the optional
        // `Idempotency-Key` header rides on the request, and (b) a 409 reply
        // carries the conflicting `CatalogCorrectionDTO` in the error
        // envelope — the standard `perform` discards extras after `code` +
        // `message`, so we parse the raw body before falling back.
        let url = configuration.baseURL.appendingPathComponent("/api/catalog/\(catalogID)/feedback")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = idempotencyKey {
            req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let payload = Input(
            body: body,
            field_hint: fieldHint,
            field_name: fieldName,
            suggested_value: suggestedValue,
            client_seen_value: clientSeenValue,
            user_acknowledged_bounds: userAcknowledgedBounds ? true : nil
        )
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await configuration.session.data(for: req)

        // Happy path: ok=true envelope with data: { id, status }. On an
        // idempotency replay the server sets `replay: true` as a
        // top-level SIBLING of `data` — probe the envelope level for it.
        struct OkBody: Decodable, Sendable {
            let id: String
            let status: String
        }
        struct ReplayProbe: Decodable, Sendable {
            let replay: Bool?
        }
        if let env = try? JSONDecoder().decode(Envelope<OkBody>.self, from: data) {
            switch env {
            case .ok(let value, _):
                let replayFlag = (try? JSONDecoder().decode(ReplayProbe.self, from: data))?.replay ?? false
                return SubmitFeedbackResponse(
                    id: value.id,
                    status: value.status,
                    replay: replayFlag,
                    existingDTO: nil
                )
            case .failure(let err):
                // 409 carries the existing DTO as a sibling of `error` in the
                // failure envelope. Re-parse to extract it; if the shape isn't
                // there (any other failure), surface the typed error as-is.
                if err.code == "open_correction_exists",
                   let existing = Self.parseExistingCorrection(from: data) {
                    return SubmitFeedbackResponse(
                        id: existing.id,
                        status: "open_correction_exists",
                        replay: false,
                        existingDTO: existing
                    )
                }
                throw err
            }
        }
        // Envelope decode failed outright — surface the same shape `perform`
        // would have surfaced.
        let detail = Self.describeDecodeError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "submit feedback")),
            body: data
        )
        throw SeedkeepError(code: "decode_failed", message: detail)
    }

    /// Body shape: `{ ok: false, error: {code, message}, existing: CatalogCorrectionDTO }`.
    /// Returns nil when the field isn't present.
    private static func parseExistingCorrection(from data: Data) -> CatalogCorrectionDTO? {
        struct Wrapper: Decodable { let existing: CatalogCorrectionDTO? }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.existing
    }

    /// Envelope returned by `submitCatalogFeedback`. On a happy submit
    /// `status` is the server's current row status (typically `"open"`,
    /// or a terminal state on an idempotency replay). On a 409 the response
    /// carries the conflicting row in `existingDTO` and `status` is the
    /// sentinel `"open_correction_exists"`.
    public struct SubmitFeedbackResponse: Sendable, Equatable {
        public let id: String
        public let status: String
        public let replay: Bool
        public let existingDTO: CatalogCorrectionDTO?

        public init(
            id: String,
            status: String,
            replay: Bool = false,
            existingDTO: CatalogCorrectionDTO? = nil
        ) {
            self.id = id
            self.status = status
            self.replay = replay
            self.existingDTO = existingDTO
        }
    }

    /// Phase 4 D · edit a still-open catalog correction. Allowed only while
    /// `status == 'open'` and the moderation worker hasn't claimed the row
    /// (`ai_locked_at IS NULL`). The server returns the updated DTO.
    public func editOpenCorrection(
        catalogID: String,
        correctionID: String,
        suggestedValue: String? = nil,
        body: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> CatalogCorrectionDTO {
        struct Input: Encodable, Sendable {
            let suggested_value: String?
            let body: String?
            let idempotency_key: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let suggested_value { try c.encode(suggested_value, forKey: .suggested_value) }
                if let body { try c.encode(body, forKey: .body) }
                if let idempotency_key {
                    try c.encode(idempotency_key, forKey: .idempotency_key)
                }
            }
            enum CodingKeys: String, CodingKey {
                case suggested_value
                case body
                case idempotency_key
            }
        }
        struct Wrapper: Decodable, Sendable { let correction: CatalogCorrectionDTO }
        let res: Wrapper = try await sendJSON(
            method: "PUT",
            path: "/api/catalog/\(catalogID)/corrections/\(correctionID)",
            body: Input(
                suggested_value: suggestedValue,
                body: body,
                idempotency_key: idempotencyKey
            )
        )
        return res.correction
    }

    /// Phase 4 D · escalate a dismissed correction with reason
    /// `ai_low_confidence` back into the human-reviewed queue. Server flips
    /// the row to `status='reviewed', dismissed_reason='user_escalated'`.
    public func escalateDismissedCorrection(
        catalogID: String,
        correctionID: String
    ) async throws -> CatalogCorrectionDTO {
        struct Wrapper: Decodable, Sendable { let correction: CatalogCorrectionDTO }
        let res: Wrapper = try await postJSON(
            path: "/api/catalog/\(catalogID)/corrections/\(correctionID)/escalate",
            body: EmptyBody()
        )
        return res.correction
    }

    /// Phase 4 D · delta-sync the current user's catalog corrections. The
    /// server caps `limit` at 50 per page; pass the returned cursor back as
    /// `since` to walk later pages. Mirrors the standard delta-page
    /// envelope used by every other pull endpoint.
    public func catalogCorrectionsMine(
        since: Int64 = 0,
        sinceID: String? = nil,
        limit: Int? = nil
    ) async throws -> DeltaPage<CatalogCorrectionDTO> {
        try await getJSON(
            path: "/api/catalog/corrections/mine",
            query: deltaQuery(since: since, sinceID: sinceID, limit: limit)
        )
    }

    /// Phase 4 D · withdraw a correction (only while `status='open'`).
    /// Server flips the row to `status='dismissed',
    /// dismissed_reason='user_withdrawn'`.
    public func withdrawCatalogCorrection(
        catalogID: String,
        correctionID: String
    ) async throws {
        let _: DeleteResult = try await deleteJSON(
            path: "/api/catalog/\(catalogID)/corrections/\(correctionID)"
        )
    }

    /// Phase 4 D · cross-device dedup ledger reader. Returns the list of
    /// device IDs that have already scheduled a local notification for this
    /// correction. The notifier checks this *before* scheduling; if its own
    /// device is in the list it skips the schedule.
    public func catalogCorrectionNotified(correctionID: String) async throws -> [String] {
        struct Wrapper: Decodable, Sendable { let devices: [String] }
        let res: Wrapper = try await getJSON(
            path: "/api/catalog/corrections/\(correctionID)/notified"
        )
        return res.devices
    }

    /// Phase 4 D · cross-device dedup ledger writer. Records that this
    /// device has scheduled a notification for the given correction.
    /// First writer wins: the server returns `{ inserted: true }` only
    /// for the row that actually claimed the ledger slot — callers
    /// schedule the user-facing ping only when `inserted == true`.
    public func markCatalogCorrectionNotified(
        correctionID: String,
        deviceID: String
    ) async throws -> Bool {
        struct Input: Encodable, Sendable { let device_id: String }
        struct Resp: Decodable, Sendable { let inserted: Bool }
        let res: Resp = try await postJSON(
            path: "/api/catalog/corrections/\(correctionID)/notified",
            body: Input(device_id: deviceID)
        )
        return res.inserted
    }

    // MARK: - MCP tokens (Phase 4 E)

    /// Metadata about an issued MCP token. Returned by list + on create
    /// (with the raw token value only on create).
    public struct MCPTokenDTO: Decodable, Sendable, Identifiable, Equatable {
        public let id: String
        public let label: String
        public let created_at: Int64
        public let last_used_at: Int64?
    }

    public struct MCPTokenSecretDTO: Decodable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let token: String      // raw secret — shown ONCE
        public let created_at: Int64
    }

    /// Issue a new MCP bearer token. The returned `.token` is the only
    /// time the raw secret is visible — store it immediately.
    public func createMCPToken(label: String?) async throws -> MCPTokenSecretDTO {
        struct Body: Encodable, Sendable { let label: String? }
        return try await postJSON(
            path: "/api/mcp/tokens",
            body: Body(label: label))
    }

    public func listMCPTokens() async throws -> [MCPTokenDTO] {
        struct Wrapper: Decodable, Sendable { let tokens: [MCPTokenDTO] }
        let r: Wrapper = try await getJSON(path: "/api/mcp/tokens")
        return r.tokens
    }

    public func revokeMCPToken(_ id: String) async throws {
        struct Resp: Decodable, Sendable { let id: String }
        _ = try await deleteJSON(path: "/api/mcp/tokens/\(id)") as Resp
    }

    /// Phase 4 E (OAuth) · short-lived pairing code used to bridge an
    /// iOS session to a browser session during the OAuth consent flow.
    /// Code lives for 10 min and is single-use.
    public struct WebPairingCodeDTO: Decodable, Sendable, Equatable {
        public let code: String
        public let expires_at: Int64
    }

    public func createWebPairingCode() async throws -> WebPairingCodeDTO {
        struct Empty: Encodable, Sendable {}
        return try await postJSON(path: "/api/web_pairing_codes", body: Empty())
    }

    // MARK: - Journal (Phase 3)

    /// `GET /api/journal` — delta-sync paginated feed. Mirrors the same
    /// envelope used by seeds/beds/etc. (`{ items, cursor, has_more }`).
    /// Filters are server-side: `seedId` / `bedId` / `plantingEventId`
    /// scope to a parent, and `fromDate` / `toDate` constrain
    /// `occurred_on` (YYYY-MM-DD strings).
    public func journalFeed(
        since: Int64 = 0,
        sinceID: String? = nil,
        limit: Int? = nil,
        seedId: String? = nil,
        bedId: String? = nil,
        plantingEventId: String? = nil,
        fromDate: String? = nil,
        toDate: String? = nil
    ) async throws -> JournalFeedResponseDTO {
        var q = deltaQuery(since: since, sinceID: sinceID, limit: limit)
        if let seedId { q.append(.init(name: "seed_id", value: seedId)) }
        if let bedId { q.append(.init(name: "bed_id", value: bedId)) }
        if let plantingEventId { q.append(.init(name: "planting_event_id", value: plantingEventId)) }
        if let fromDate { q.append(.init(name: "from_date", value: fromDate)) }
        if let toDate { q.append(.init(name: "to_date", value: toDate)) }
        return try await getJSON(path: "/api/journal", query: q)
    }

    /// Body for `POST /api/journal`. Encoded as snake_case to match the
    /// server's zod schema; response is the camelCase `JournalEntryDTO`.
    public struct CreateJournalEntryInput: Codable, Sendable {
        public var occurredOn: String           // 'YYYY-MM-DD'
        public var body: String
        public var seedId: String?
        public var bedId: String?
        public var plantingEventId: String?

        public init(
            occurredOn: String,
            body: String,
            seedId: String? = nil,
            bedId: String? = nil,
            plantingEventId: String? = nil
        ) {
            self.occurredOn = occurredOn
            self.body = body
            self.seedId = seedId
            self.bedId = bedId
            self.plantingEventId = plantingEventId
        }

        private enum CodingKeys: String, CodingKey {
            case occurredOn = "occurred_on"
            case body
            case seedId = "seed_id"
            case bedId = "bed_id"
            case plantingEventId = "planting_event_id"
        }
    }

    public func createJournalEntry(_ input: CreateJournalEntryInput) async throws -> JournalEntryDTO {
        struct Wrapper: Codable, Sendable { let entry: JournalEntryDTO }
        let res: Wrapper = try await postJSON(path: "/api/journal", body: input)
        return res.entry
    }

    /// Body for `PATCH /api/journal/:id`. Uses Swift's double-optional
    /// (`String??`) on parent-ref fields so callers can express three
    /// states: omit (no change), `.some(nil)` (clear / null), or
    /// `.some(value)` (set). Encoder honors that distinction so PATCH
    /// only sends what the caller actually wants to change.
    public struct UpdateJournalEntryInput: Sendable {
        public var occurredOn: String?
        public var body: String?
        public var seedId: String??
        public var bedId: String??
        public var plantingEventId: String??

        public init(
            occurredOn: String? = nil,
            body: String? = nil,
            seedId: String?? = nil,
            bedId: String?? = nil,
            plantingEventId: String?? = nil
        ) {
            self.occurredOn = occurredOn
            self.body = body
            self.seedId = seedId
            self.bedId = bedId
            self.plantingEventId = plantingEventId
        }
    }

    public func updateJournalEntry(_ id: String, _ patch: UpdateJournalEntryInput) async throws -> JournalEntryDTO {
        struct Wrapper: Codable, Sendable { let entry: JournalEntryDTO }
        // Hand-rolled Encodable so we can distinguish "omit" vs "set null"
        // for the parent-ref fields. Mirrors the pattern in `updateTag`.
        struct Body: Encodable {
            let patch: UpdateJournalEntryInput
            enum CodingKeys: String, CodingKey {
                case occurredOn = "occurred_on"
                case body
                case seedId = "seed_id"
                case bedId = "bed_id"
                case plantingEventId = "planting_event_id"
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let v = patch.occurredOn { try c.encode(v, forKey: .occurredOn) }
                if let v = patch.body { try c.encode(v, forKey: .body) }
                if let v = patch.seedId { try c.encode(v, forKey: .seedId) }
                if let v = patch.bedId { try c.encode(v, forKey: .bedId) }
                if let v = patch.plantingEventId { try c.encode(v, forKey: .plantingEventId) }
            }
        }
        let res: Wrapper = try await patchJSON(path: "/api/journal/\(id)", body: Body(patch: patch))
        return res.entry
    }

    /// `DELETE /api/journal/:id` — soft-deletes the entry.
    public func deleteJournalEntry(_ id: String) async throws {
        let _: DeleteResult = try await deleteJSON(path: "/api/journal/\(id)")
    }

    // MARK: - Journal photos

    public func listJournalEntryPhotos(entryId: String) async throws -> [JournalEntryPhotoDTO] {
        struct Wrapper: Codable, Sendable { let photos: [JournalEntryPhotoDTO] }
        let res: Wrapper = try await getJSON(path: "/api/journal/\(entryId)/photos")
        return res.photos
    }

    /// Uploads a single photo attached to a journal entry. Mirrors
    /// `uploadSeedPhoto`: the server expects raw image bytes as the body
    /// (not multipart), with `Content-Type` naming the format and the
    /// optional `X-Photo-Width` / `X-Photo-Height` request headers for
    /// dimensions when the client knows them.
    public func uploadJournalPhoto(
        entryId: String,
        jpegData: Data,
        width: Int? = nil,
        height: Int? = nil
    ) async throws -> JournalEntryPhotoDTO {
        struct Wrapper: Codable, Sendable { let photo: JournalEntryPhotoDTO }
        let url = configuration.baseURL.appendingPathComponent("/api/journal/\(entryId)/photos")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        if let width { req.setValue(String(width), forHTTPHeaderField: "X-Photo-Width") }
        if let height { req.setValue(String(height), forHTTPHeaderField: "X-Photo-Height") }
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = jpegData
        let res: Wrapper = try await perform(req)
        return res.photo
    }

    /// `DELETE /api/journal/photos/:photoId`.
    public func deleteJournalPhoto(_ photoId: String) async throws {
        let _: DeleteResult = try await deleteJSON(path: "/api/journal/photos/\(photoId)")
    }

    /// Fetches a single journal photo's raw bytes from R2 via the
    /// Worker. Mirrors `fetchSeedPhotoData`.
    public func journalPhotoData(photoId: String) async throws -> Data {
        let url = configuration.baseURL.appendingPathComponent("/api/journal/photos/\(photoId)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await configuration.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SeedkeepError(code: "fetch_failed", message: "Could not fetch journal photo bytes")
        }
        return data
    }

    // MARK: - Journal checklist

    public func listJournalChecklistItems(entryId: String) async throws -> [JournalChecklistItemDTO] {
        struct Wrapper: Codable, Sendable { let items: [JournalChecklistItemDTO] }
        let res: Wrapper = try await getJSON(path: "/api/journal/\(entryId)/checklist")
        return res.items
    }

    public func addChecklistItem(entryId: String, text: String) async throws -> JournalChecklistItemDTO {
        struct Body: Encodable { let text: String }
        struct Wrapper: Codable, Sendable { let item: JournalChecklistItemDTO }
        let res: Wrapper = try await postJSON(
            path: "/api/journal/\(entryId)/checklist",
            body: Body(text: text)
        )
        return res.item
    }

    /// Body for `PATCH /api/journal/checklist/:itemId`. Plain optionals
    /// for `text`/`completed`/`sortOrder` (no clearing semantics — the
    /// server treats absent fields as "unchanged"; none of these are
    /// nullable in storage).
    public struct UpdateChecklistItemInput: Codable, Sendable {
        public var text: String?
        public var completed: Bool?
        public var sortOrder: Int?

        public init(text: String? = nil, completed: Bool? = nil, sortOrder: Int? = nil) {
            self.text = text
            self.completed = completed
            self.sortOrder = sortOrder
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case completed
            case sortOrder = "sort_order"
        }
    }

    public func updateChecklistItem(
        _ itemId: String,
        _ patch: UpdateChecklistItemInput
    ) async throws -> JournalChecklistItemDTO {
        struct Wrapper: Codable, Sendable { let item: JournalChecklistItemDTO }
        let res: Wrapper = try await patchJSON(
            path: "/api/journal/checklist/\(itemId)",
            body: patch
        )
        return res.item
    }

    public func deleteChecklistItem(_ itemId: String) async throws {
        let _: DeleteResult = try await deleteJSON(path: "/api/journal/checklist/\(itemId)")
    }

    // MARK: - Journal retrospective

    /// `GET /api/journal/retrospective?on=MM-DD` — returns entries from
    /// prior years on (or near) the anchor date. Used by the "this day
    /// in your garden, N years ago" view.
    public func journalRetrospective(on anchor: String) async throws -> RetrospectiveResponseDTO {
        try await getJSON(
            path: "/api/journal/retrospective",
            query: [.init(name: "on", value: anchor)]
        )
    }

    // MARK: - Assistant (Phase 4 — Sprout)

    /// List assistant threads (delta-sync friendly). `since=0` excludes
    /// soft-deletes; any non-zero `since` includes them so clients purge.
    public func assistantThreads(since: Int64 = 0, sinceID: String? = nil, limit: Int? = nil) async throws -> AssistantThreadFeedDTO {
        try await getJSON(path: "/api/assistant/threads", query: deltaQuery(since: since, sinceID: sinceID, limit: limit))
    }

    public struct CreateAssistantThreadInput: Encodable, Sendable {
        public let title: String?
        public let threadKind: String?
        public init(title: String? = nil, threadKind: String? = nil) {
            self.title = title; self.threadKind = threadKind
        }
        enum CodingKeys: String, CodingKey {
            case title; case threadKind = "thread_kind"
        }
    }

    public func createAssistantThread(title: String = "", threadKind: String = "chat") async throws -> AssistantThreadDTO {
        struct Wrapper: Decodable { let thread: AssistantThreadDTO }
        let body = CreateAssistantThreadInput(
            title: title.isEmpty ? nil : title,
            threadKind: threadKind == "chat" ? nil : threadKind)
        let r: Wrapper = try await postJSON(path: "/api/assistant/threads", body: body)
        return r.thread
    }

    public func assistantThread(id: String) async throws -> AssistantThreadDetailDTO {
        return try await getJSON(path: "/api/assistant/threads/\(id)")
    }

    public struct UpdateAssistantThreadInput: Encodable, Sendable {
        public let title: String
        public init(title: String) { self.title = title }
    }

    public func updateAssistantThread(_ id: String, title: String) async throws -> AssistantThreadDTO {
        struct Wrapper: Decodable { let thread: AssistantThreadDTO }
        let r: Wrapper = try await patchJSON(
            path: "/api/assistant/threads/\(id)",
            body: UpdateAssistantThreadInput(title: title))
        return r.thread
    }

    public func deleteAssistantThread(_ id: String) async throws {
        struct DeleteResp: Decodable { let id: String }
        _ = try await deleteJSON(path: "/api/assistant/threads/\(id)") as DeleteResp
    }

    // ── Key management ─────────────────────────────────────────────────────

    public struct SetAssistantKeyInput: Encodable, Sendable {
        public let provider: String
        public let key: String
        public init(provider: String = "anthropic", key: String) {
            self.provider = provider; self.key = key
        }
    }

    public func setAssistantKey(provider: String = "anthropic", key: String) async throws -> AssistantKeyProviderStatus {
        return try await sendJSON(
            method: "PUT",
            path: "/api/households/me/assistant_key",
            body: SetAssistantKeyInput(provider: provider, key: key))
    }

    public func deleteAssistantKey(provider: String = "anthropic") async throws {
        struct DeleteResp: Decodable { let provider: String; let configured: Bool }
        _ = try await deleteJSON(
            path: "/api/households/me/assistant_key",
            query: [URLQueryItem(name: "provider", value: provider)]
        ) as DeleteResp
    }

    public func assistantKeyStatus() async throws -> AssistantKeyStatusDTO {
        return try await getJSON(path: "/api/households/me/assistant_key")
    }

    // ── Tool-call cancel (confirm + stream are in Task 2 because they stream SSE) ──

    public func cancelAssistantToolCall(_ id: String) async throws -> AssistantToolCallDTO {
        struct Wrapper: Decodable { let toolCall: AssistantToolCallDTO }
        let r: Wrapper = try await postJSON(
            path: "/api/assistant/tool_calls/\(id)/cancel",
            body: EmptyBody())
        return r.toolCall
    }

    // MARK: - Internals

    private struct EmptyBody: Encodable {}

    /// `sinceID` is the delta-cursor tiebreaker (stabilization contract
    /// decision 9): sent as `since_id` alongside `since`, the server
    /// resumes mid-millisecond with `updated_at > since OR (updated_at =
    /// since AND id > since_id)`. Omitted (nil) preserves the legacy
    /// strict `updated_at > since` behavior.
    private func deltaQuery(since: Int64, sinceID: String?, limit: Int?) -> [URLQueryItem] {
        var q: [URLQueryItem] = [.init(name: "since", value: String(since))]
        if let sinceID { q.append(.init(name: "since_id", value: sinceID)) }
        if let l = limit { q.append(.init(name: "limit", value: String(l))) }
        return q
    }

    private func getJSON<T: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = [],
        auth: Bool = true
    ) async throws -> T {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw SeedkeepError(code: "bad_url", message: "Could not construct URL for \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if auth, let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await perform(req)
    }

    private func postJSON<Body: Encodable, T: Decodable & Sendable>(
        path: String,
        body: Body
    ) async throws -> T {
        try await sendJSON(method: "POST", path: path, body: body)
    }

    private func patchJSON<Body: Encodable, T: Decodable & Sendable>(
        path: String,
        body: Body
    ) async throws -> T {
        try await sendJSON(method: "PATCH", path: path, body: body)
    }

    private func sendJSON<Body: Encodable, T: Decodable & Sendable>(
        method: String,
        path: String,
        body: Body
    ) async throws -> T {
        let url = configuration.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let encoder = JSONEncoder()
        // Skip nil-valued optional fields so PATCH only sends what changed.
        encoder.outputFormatting = []
        req.httpBody = try encoder.encode(body)
        return try await perform(req)
    }

    private func deleteJSON<T: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw SeedkeepError(code: "bad_url", message: "Could not construct URL for \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await perform(req)
    }

    /// Pretty-print a Swift DecodingError so users + logs can see the
    /// exact key + types involved. Includes a short body excerpt so a
    /// shape mismatch between client and server is obvious at a glance.
    private static func describeDecodeError(_ error: Error, body: Data) -> String {
        let path: (DecodingError.Context) -> String = { ctx in
            ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
        }
        let detail: String
        if let d = error as? DecodingError {
            switch d {
            case .typeMismatch(let type, let ctx):
                detail = "typeMismatch \(type) at '\(path(ctx))' — \(ctx.debugDescription)"
            case .valueNotFound(let type, let ctx):
                detail = "valueNotFound \(type) at '\(path(ctx))' — \(ctx.debugDescription)"
            case .keyNotFound(let key, let ctx):
                detail = "keyNotFound '\(key.stringValue)' at '\(path(ctx))'"
            case .dataCorrupted(let ctx):
                detail = "dataCorrupted at '\(path(ctx))' — \(ctx.debugDescription)"
            @unknown default:
                detail = "DecodingError: \(error.localizedDescription)"
            }
        } else {
            detail = error.localizedDescription
        }
        let snippet = String(data: body, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(220) ?? ""
        return "\(detail) | body: \(snippet)"
    }

    private func perform<T: Decodable & Sendable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await configuration.session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SeedkeepError(code: "no_http_response", message: "Non-HTTP response")
        }

        // Both success and error envelopes parse the same way.
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            // Server returned something that wasn't an envelope. Surface the
            // raw HTTP status with the decode-error detail so the message
            // names the exact key + expected/found types instead of the
            // generic "couldn't be read because it isn't in the correct
            // format."
            let detail = Self.describeDecodeError(error, body: data)
            throw SeedkeepError(
                code: "decode_failed",
                message: "HTTP \(http.statusCode): \(detail)",
                httpStatus: http.statusCode
            )
        }

        switch envelope {
        case .ok(let value, _):
            return value
        case .failure(let error):
            // Attach the HTTP status so callers can classify the failure
            // (429/5xx retryable vs definitive 4xx) without string parsing.
            throw error.attaching(httpStatus: http.statusCode)
        }
    }
}

// MARK: - Multipart helpers

private extension Data {
    mutating func appendField(
        boundary: String,
        name: String,
        filename: String,
        contentType: String,
        payload: Data
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(payload)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendTextField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
    }
}

// MARK: - Catalog corrections (Phase 4 D)

/// Wire-format DTO for a single catalog-correction row, returned by
/// `GET /api/catalog/corrections/mine` and the per-correction routes
/// (`edit`, `escalate`). Mirrors `catalog_feedback` after the 0020
/// migration adds the structured columns.
///
/// `catalog_seed_id` is nullable because the FK is `ON DELETE SET NULL` —
/// audit history survives a catalog row going away. `catalog_seed_name`
/// is denormalized at submit time so offline notifications can name the
/// seed even after deletion.
///
/// `field_name` / `value_type` / `suggested_value` are nullable on the
/// wire: free-form ("Something else") submissions and legacy pre-4D
/// feedback rows store NULL for all three. The server passes the nulls
/// through verbatim (stabilization contract decision 1 — no coalescing).
///
/// `applied_patch` accompanies rows transitioning to `applied`: the iOS
/// sync engine uses it to invalidate the cached `CatalogSeedDTO`
/// in-place, so SeedDetail shows the new value without an extra round
/// trip.
public struct CatalogCorrectionDTO: Codable, Sendable, Equatable {
    public let id: String
    public let catalog_seed_id: String?
    public let catalog_seed_name: String?
    public let field_name: String?
    public let value_type: String?
    public let suggested_value: String?
    public let client_seen_value: String?
    public let body: String?
    public let status: String           // "open" | "reviewed" | "applied" | "dismissed"
    public let ai_review_score: Double?
    public let ai_notes: String?        // surfaced verbatim in ContributionDetailSheet
    public let dismissed_reason: String?
    public let conflict_with_id: String?
    public let user_acknowledged_bounds: Bool
    public let created_at: Int64
    public let reviewed_at: Int64?
    public let applied_at: Int64?
    public let escalated_at: Int64?
    public let updated_at: Int64
    public let deleted_at: Int64?
    /// Present only on rows transitioning to `applied`. Carries the field
    /// + new value so the client can patch its cached `CatalogSeedDTO`
    /// without a follow-up GET. Server omits the key when not applicable.
    public let applied_patch: AppliedPatch?

    public struct AppliedPatch: Codable, Sendable, Equatable {
        public let field_name: String
        public let new_value: String

        public init(field_name: String, new_value: String) {
            self.field_name = field_name
            self.new_value = new_value
        }
    }

    public init(
        id: String,
        catalog_seed_id: String?,
        catalog_seed_name: String?,
        field_name: String?,
        value_type: String?,
        suggested_value: String?,
        client_seen_value: String?,
        body: String?,
        status: String,
        ai_review_score: Double?,
        ai_notes: String?,
        dismissed_reason: String?,
        conflict_with_id: String?,
        user_acknowledged_bounds: Bool,
        created_at: Int64,
        reviewed_at: Int64?,
        applied_at: Int64?,
        escalated_at: Int64?,
        updated_at: Int64,
        deleted_at: Int64?,
        applied_patch: AppliedPatch? = nil
    ) {
        self.id = id
        self.catalog_seed_id = catalog_seed_id
        self.catalog_seed_name = catalog_seed_name
        self.field_name = field_name
        self.value_type = value_type
        self.suggested_value = suggested_value
        self.client_seen_value = client_seen_value
        self.body = body
        self.status = status
        self.ai_review_score = ai_review_score
        self.ai_notes = ai_notes
        self.dismissed_reason = dismissed_reason
        self.conflict_with_id = conflict_with_id
        self.user_acknowledged_bounds = user_acknowledged_bounds
        self.created_at = created_at
        self.reviewed_at = reviewed_at
        self.applied_at = applied_at
        self.escalated_at = escalated_at
        self.updated_at = updated_at
        self.deleted_at = deleted_at
        self.applied_patch = applied_patch
    }
}
