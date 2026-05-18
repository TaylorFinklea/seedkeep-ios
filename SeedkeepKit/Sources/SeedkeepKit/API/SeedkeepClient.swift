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

    // MARK: - Locations

    public func locations(since: Int64 = 0, limit: Int? = nil) async throws -> DeltaPage<LocationDTO> {
        try await getJSON(path: "/api/locations", query: deltaQuery(since: since, limit: limit))
    }

    public func createLocation(name: String, sortOrder: Int = 0) async throws -> LocationDTO {
        struct Body: Encodable { let name: String; let sort_order: Int }
        let res: WireResponses.LocationOne = try await postJSON(
            path: "/api/locations",
            body: Body(name: name, sort_order: sortOrder)
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

    public func tags(since: Int64 = 0, limit: Int? = nil) async throws -> DeltaPage<TagDTO> {
        try await getJSON(path: "/api/tags", query: deltaQuery(since: since, limit: limit))
    }

    public func createTag(name: String, color: String? = nil) async throws -> TagDTO {
        struct Body: Encodable { let name: String; let color: String? }
        let res: WireResponses.TagOne = try await postJSON(
            path: "/api/tags",
            body: Body(name: name, color: color)
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
        limit: Int? = nil,
        filters: SeedFilters = .init()
    ) async throws -> DeltaPage<SeedDTO> {
        var q = deltaQuery(since: since, limit: limit)
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
    /// nil keys so the server receives only the fields the caller wants
    /// to change.
    public struct UpdateSeedInput: Codable, Sendable {
        public var catalog_id: String?
        public var state: SeedState?
        public var packet_count: Int?
        public var location_id: String?
        public var year_packed: Int?
        public var source: SeedSource?
        public var custom_name: String?
        public var custom_variety: String?
        public var custom_company: String?
        public var notes: String?
        public var tag_ids: [String]?

        public init(
            catalog_id: String? = nil,
            state: SeedState? = nil,
            packet_count: Int? = nil,
            location_id: String? = nil,
            year_packed: Int? = nil,
            source: SeedSource? = nil,
            custom_name: String? = nil,
            custom_variety: String? = nil,
            custom_company: String? = nil,
            notes: String? = nil,
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

    public func beds(since: Int64 = 0, limit: Int? = nil) async throws -> DeltaPage<BedDTO> {
        try await getJSON(path: "/api/beds", query: deltaQuery(since: since, limit: limit))
    }

    public struct CreateBedInput: Codable, Sendable {
        public var name: String
        public var description: String?
        public var width_feet: Double?
        public var length_feet: Double?
        public var sort_order: Int?
        public init(name: String, description: String? = nil, width_feet: Double? = nil, length_feet: Double? = nil, sort_order: Int? = nil) {
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

    public func plantingEvents(since: Int64 = 0, limit: Int? = nil) async throws -> DeltaPage<PlantingEventDTO> {
        try await getJSON(path: "/api/planting-events", query: deltaQuery(since: since, limit: limit))
    }

    public struct CreatePlantingEventInput: Codable, Sendable {
        public var bed_id: String?
        public var seed_id: String?
        public var catalog_seed_id: String?
        public var kind: String
        public var planned_for: String   // YYYY-MM-DD
        public var completed_at: Int64?
        public var notes: String?
        public init(
            bed_id: String? = nil,
            seed_id: String? = nil,
            catalog_seed_id: String? = nil,
            kind: PlantingEventKind,
            planned_for: String,
            completed_at: Int64? = nil,
            notes: String? = nil
        ) {
            self.bed_id = bed_id
            self.seed_id = seed_id
            self.catalog_seed_id = catalog_seed_id
            self.kind = kind.rawValue
            self.planned_for = planned_for
            self.completed_at = completed_at
            self.notes = notes
        }
    }

    public func createPlantingEvent(_ input: CreatePlantingEventInput) async throws -> PlantingEventDTO {
        let res: WireResponses.PlantingEventOne = try await postJSON(path: "/api/planting-events", body: input)
        return res.planting_event
    }

    public struct UpdatePlantingEventInput: Codable, Sendable {
        public var bed_id: String?
        public var seed_id: String?
        public var catalog_seed_id: String?
        public var kind: String?
        public var planned_for: String?
        public var completed_at: Int64?
        public var notes: String?
        public init(
            bed_id: String? = nil,
            seed_id: String? = nil,
            catalog_seed_id: String? = nil,
            kind: PlantingEventKind? = nil,
            planned_for: String? = nil,
            completed_at: Int64? = nil,
            notes: String? = nil
        ) {
            self.bed_id = bed_id
            self.seed_id = seed_id
            self.catalog_seed_id = catalog_seed_id
            self.kind = kind?.rawValue
            self.planned_for = planned_for
            self.completed_at = completed_at
            self.notes = notes
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

    // MARK: - Internals

    private struct EmptyBody: Encodable {}

    private func deltaQuery(since: Int64, limit: Int?) -> [URLQueryItem] {
        var q: [URLQueryItem] = [.init(name: "since", value: String(since))]
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

    private func deleteJSON<T: Decodable & Sendable>(path: String) async throws -> T {
        let url = configuration.baseURL.appendingPathComponent(path)
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
                message: "HTTP \(http.statusCode): \(detail)"
            )
        }

        switch envelope {
        case .ok(let value, _):
            return value
        case .failure(let error):
            throw error
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
