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

    public struct CreateSeedInput: Encodable, Sendable {
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

    public func randomSeed() async throws -> SeedDTO? {
        struct SeedEnvelope: Codable, Sendable { let seed: SeedDTO? }
        do {
            let res: SeedEnvelope = try await getJSON(path: "/api/seeds/random")
            return res.seed
        } catch let err as SeedkeepError where err.code == "no_seeds" {
            return nil
        }
    }

    // MARK: - Catalog

    public func catalogLookup(barcode: String) async throws -> CatalogSeedDTO? {
        struct Body: Codable, Sendable { let catalog_seed: CatalogSeedDTO? }
        let res: Body = try await getJSON(path: "/api/catalog/lookup", query: [.init(name: "barcode", value: barcode)])
        return res.catalog_seed
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
        let url = configuration.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(body)
        return try await perform(req)
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
            // raw HTTP status with the decode error so logs still help.
            throw SeedkeepError(
                code: "decode_failed",
                message: "HTTP \(http.statusCode): \(error.localizedDescription)"
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
