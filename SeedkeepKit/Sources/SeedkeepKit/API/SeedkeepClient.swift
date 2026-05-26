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
        public var x_feet: Double?
        public var y_feet: Double?
        public init(
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

    public struct UpdatePlantingEventInput: Codable, Sendable {
        public var bed_id: String?
        public var seed_id: String?
        public var catalog_seed_id: String?
        public var kind: String?
        public var planned_for: String?
        public var completed_at: Int64?
        public var notes: String?
        public var x_feet: Double?
        public var y_feet: Double?
        public init(
            bed_id: String? = nil,
            seed_id: String? = nil,
            catalog_seed_id: String? = nil,
            kind: PlantingEventKind? = nil,
            planned_for: String? = nil,
            completed_at: Int64? = nil,
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
    }

    public func updatePlantingEvent(id: String, _ input: UpdatePlantingEventInput) async throws -> PlantingEventDTO {
        let res: WireResponses.PlantingEventOne = try await patchJSON(path: "/api/planting-events/\(id)", body: input)
        return res.planting_event
    }

    @discardableResult
    public func deletePlantingEvent(id: String) async throws -> DeleteResult {
        try await deleteJSON(path: "/api/planting-events/\(id)")
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

    /// Phase 4 D · submit a free-form correction / observation about a
    /// catalog entry. Stored on the server and reviewed out of band; no
    /// in-app review UI for the queue yet. Returns the feedback id.
    public func submitCatalogFeedback(
        catalogID: String,
        body: String,
        fieldHint: String? = nil
    ) async throws -> String {
        struct Input: Encodable, Sendable {
            let body: String
            let field_hint: String?
        }
        struct Response: Decodable, Sendable { let id: String }
        let res: Response = try await postJSON(
            path: "/api/catalog/\(catalogID)/feedback",
            body: Input(body: body, field_hint: fieldHint))
        return res.id
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

    // MARK: - Journal (Phase 3)

    /// `GET /api/journal` — delta-sync paginated feed. Mirrors the same
    /// envelope used by seeds/beds/etc. (`{ items, cursor, has_more }`).
    /// Filters are server-side: `seedId` / `bedId` / `plantingEventId`
    /// scope to a parent, and `fromDate` / `toDate` constrain
    /// `occurred_on` (YYYY-MM-DD strings).
    public func journalFeed(
        since: Int64 = 0,
        limit: Int? = nil,
        seedId: String? = nil,
        bedId: String? = nil,
        plantingEventId: String? = nil,
        fromDate: String? = nil,
        toDate: String? = nil
    ) async throws -> JournalFeedResponseDTO {
        var q = deltaQuery(since: since, limit: limit)
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
    public func assistantThreads(since: Int64 = 0, limit: Int? = nil) async throws -> AssistantThreadFeedDTO {
        var components = URLComponents(string: "/api/assistant/threads")!
        components.queryItems = deltaQuery(since: since, limit: limit)
        return try await getJSON(path: components.url!.absoluteString)
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
        var components = URLComponents(string: "/api/households/me/assistant_key")!
        components.queryItems = [.init(name: "provider", value: provider)]
        _ = try await deleteJSON(path: components.url!.absoluteString) as DeleteResp
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
