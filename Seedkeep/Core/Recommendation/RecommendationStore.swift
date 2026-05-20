import Foundation
import SwiftData
import SeedkeepKit

/// Fetches server recommendation baselines, caches them in `LocalRecommendation`,
/// and applies `WeatherKitRefiner` for a locally-refined planting window.
///
/// Construction mirrors `SyncEngine` exactly: one `SeedkeepClient` + one
/// `ModelContainer`; a fresh `ModelContext` is created per operation so the
/// class is safe to use across many SwiftUI view lifecycles without keeping
/// live model objects alive.
@MainActor
@Observable
public final class RecommendationStore {
    private let client: SeedkeepClient
    private let container: ModelContainer

    // MARK: - Observable state

    /// Set `true` when any server call returns `no_household_location`, so the
    /// UI can surface the "set your ZIP" prompt.
    public var needsHomeLocation: Bool = false

    /// Incremented after every successful SwiftData save so `@Observable`
    /// SwiftUI views can track it as a dependency and re-render after
    /// `refresh` / `bulkRefresh` upserts new data.
    public private(set) var updateEpoch: Int = 0

    // MARK: - In-memory caches (non-persisted)

    /// WeatherKit-refined results keyed by `catalogSeedID`.
    private var refinedCache: [String: RefinedRecommendation] = [:]

    /// Last-fetched forecast and when it was fetched.
    private var cachedForecast: [ForecastDay] = []
    private var forecastFetchedAt: Date? = nil

    /// Six-hour TTL for the in-memory forecast.
    private static let forecastTTL: TimeInterval = 6 * 60 * 60

    /// Catalog seed IDs returned as `pending` by the last bulk call.  A
    /// subsequent `bulkRefresh` will include them.
    private var pendingIDs: Set<String> = []

    // MARK: - Init

    public init(client: SeedkeepClient, container: ModelContainer) {
        self.client = client
        self.container = container
    }

    // MARK: - Synchronous read (for SwiftUI view bodies)

    /// Synchronous read from SwiftData.  Safe to call in a view body — no
    /// network I/O, no async overhead.
    func recommendation(for catalogSeedID: String) -> LocalRecommendation? {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalRecommendation>(
            predicate: #Predicate { $0.catalogSeedID == catalogSeedID }
        )
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Refresh (single)

    /// Fetches the server recommendation for one catalog seed and upserts it
    /// into SwiftData.  Network errors are swallowed (logged only) — a missing
    /// recommendation is not fatal.  A `no_household_location` code sets
    /// `needsHomeLocation` instead of propagating.
    public func refresh(catalogSeedID: String) async {
        let dto: RecommendationDTO
        do {
            dto = try await client.recommendation(catalogSeedID: catalogSeedID)
        } catch let err as SeedkeepError {
            if err.code == "no_household_location" {
                needsHomeLocation = true
            } else {
                print("[RecommendationStore] refresh(\(catalogSeedID)) error: \(err.code): \(err.message)")
            }
            return
        } catch {
            print("[RecommendationStore] refresh(\(catalogSeedID)) error: \(error.localizedDescription)")
            return
        }
        upsert(dto: dto)
    }

    // MARK: - Bulk refresh

    /// Fetches recommendations for multiple catalog seeds in one round-trip.
    /// Also re-requests any IDs previously returned as `pending`.
    /// Caps the combined input at 200 IDs.
    public func bulkRefresh(catalogSeedIDs: [String]) async {
        var ids = Array(Set(catalogSeedIDs).union(pendingIDs))
        if ids.count > 200 {
            ids = Array(ids.prefix(200))
        }
        guard !ids.isEmpty else { return }

        let response: WireRecommendation.BulkResponse
        do {
            response = try await client.bulkRecommendations(catalogSeedIDs: ids)
        } catch let err as SeedkeepError {
            if err.code == "no_household_location" {
                needsHomeLocation = true
            } else {
                print("[RecommendationStore] bulkRefresh error: \(err.code): \(err.message)")
            }
            return
        } catch {
            print("[RecommendationStore] bulkRefresh error: \(error.localizedDescription)")
            return
        }

        for dto in response.recommendations {
            upsert(dto: dto)
        }
        // Track IDs the server says are still computing so we re-request them.
        pendingIDs = Set(response.pending)
    }

    // MARK: - WeatherKit-refined recommendation

    /// Returns a `RefinedRecommendation` that blends the persisted server
    /// baseline with a 10-day local WeatherKit forecast.
    ///
    /// - Returns `nil` when no baseline exists in SwiftData yet.
    /// - Never throws; on any WeatherKit failure the unrefined baseline is
    ///   returned so the UI degrades gracefully.
    func refinedRecommendation(
        for catalogSeedID: String,
        householdLat: Double,
        householdLon: Double,
        frostTolerance: String?,
        soilTempMaxF: Int?
    ) async -> RefinedRecommendation? {
        guard let baseline = recommendation(for: catalogSeedID) else { return nil }

        // Fetch / reuse cached forecast.
        let forecast = await ensureForecast(latitude: householdLat, longitude: householdLon)

        let refined = WeatherKitRefiner.refine(
            verdict: baseline.verdict,
            scores: baseline.dailyScores,
            anchorDate: baseline.scoresAnchorDate,
            frostTolerance: frostTolerance,
            soilTempMaxF: soilTempMaxF,
            forecast: forecast
        )
        refinedCache[catalogSeedID] = refined
        return refined
    }

    // MARK: - Private helpers

    /// Fetch a forecast, reusing the in-memory cache when it is younger than 6 hours.
    private func ensureForecast(latitude: Double, longitude: Double) async -> [ForecastDay] {
        let now = Date()
        if let fetchedAt = forecastFetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.forecastTTL,
           !cachedForecast.isEmpty {
            return cachedForecast
        }

        do {
            let fresh = try await WeatherKitRefiner.fetchForecast(
                latitude: latitude, longitude: longitude
            )
            cachedForecast = fresh
            forecastFetchedAt = now
            return fresh
        } catch {
            print("[RecommendationStore] WeatherKit fetch error: \(error.localizedDescription)")
            // Return whatever was previously cached (may be empty), never crash.
            return cachedForecast
        }
    }

    /// Fetch-then-upsert a single `RecommendationDTO` into SwiftData.
    private func upsert(dto: RecommendationDTO) {
        let context = ModelContext(container)
        let id = dto.catalogSeedId
        let descriptor = FetchDescriptor<LocalRecommendation>(
            predicate: #Predicate { $0.catalogSeedID == id }
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            if let existing = try context.fetch(descriptor).first {
                dto.apply(to: existing, fetchedAt: now)
            } else {
                context.insert(dto.makeLocal(fetchedAt: now))
            }
            try context.save()
            updateEpoch += 1
        } catch {
            print("[RecommendationStore] upsert(\(id)) SwiftData error: \(error.localizedDescription)")
        }
        // Invalidate any stale refined entry so the next read recomputes.
        refinedCache.removeValue(forKey: id)
    }
}
