import Foundation
import SwiftData
import SeedkeepKit

/// Reads + writes journal entries against `/api/journal`, mirroring the
/// server feed into `LocalJournalEntry` so SwiftUI views can read with
/// `@Query`. Construction mirrors `RecommendationStore`: one client, one
/// `ModelContainer`; a fresh `ModelContext` is created per operation.
@MainActor
@Observable
final class JournalStore {
    private let client: SeedkeepClient
    private let container: ModelContainer

    private(set) var isLoading = false
    private(set) var lastError: String?

    init(client: SeedkeepClient, container: ModelContainer) {
        self.client = client
        self.container = container
    }

    /// Fetch the latest server feed and merge into the local store. Views
    /// read from SwiftData via `@Query`; this method just refills.
    /// Optional filters scope the refresh to a single seed / bed / planting event.
    func refresh(
        seedID: String? = nil,
        bedID: String? = nil,
        plantingEventID: String? = nil
    ) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.journalFeed(
                since: 0,
                seedId: seedID,
                bedId: bedID,
                plantingEventId: plantingEventID
            )
            let context = ModelContext(container)
            for entry in page.items {
                let id = entry.id
                let existing = try context.fetch(
                    FetchDescriptor<LocalJournalEntry>(
                        predicate: #Predicate { $0.id == id }
                    )
                ).first
                if let existing {
                    entry.apply(to: existing)
                } else {
                    context.insert(entry.makeLocal())
                }
            }
            try context.save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Optimistic create — calls the server, then inserts the returned
    /// entry locally so the `@Query` feed picks it up immediately.
    @discardableResult
    func create(
        occurredOn: String,
        body: String,
        seedID: String? = nil,
        bedID: String? = nil,
        plantingEventID: String? = nil
    ) async throws -> LocalJournalEntry {
        let dto = try await client.createJournalEntry(
            .init(
                occurredOn: occurredOn,
                body: body,
                seedId: seedID,
                bedId: bedID,
                plantingEventId: plantingEventID
            )
        )
        let context = ModelContext(container)
        let local = dto.makeLocal()
        context.insert(local)
        try context.save()
        return local
    }

    /// Soft-delete on server, mirror locally by marking `deletedAt`.
    func softDelete(_ entry: LocalJournalEntry) async throws {
        try await client.deleteJournalEntry(entry.id)
        let context = ModelContext(container)
        let id = entry.id
        if let local = try context.fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
        ).first {
            local.deletedAt = Int64(Date().timeIntervalSince1970 * 1000)
            try context.save()
        }
    }

    /// Retrospective fetch (anchor MM-DD).
    func retrospective(on anchor: String) async throws -> RetrospectiveResponseDTO {
        try await client.journalRetrospective(on: anchor)
    }
}
