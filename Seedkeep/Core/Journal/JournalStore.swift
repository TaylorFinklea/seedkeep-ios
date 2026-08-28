import Foundation
import SwiftData
import SeedkeepKit
import SeedkeepCloudKit

/// Owns the journal mutation boundary. Rollback mode mirrors `/api/journal`
/// into SwiftData; CloudKit mode mutates the active garden locally and lets
/// the app-level coordinator push that graph.
@MainActor
@Observable
final class JournalStore {
    private let client: SeedkeepClient
    private let container: ModelContainer

    @ObservationIgnored var onLocalHouseholdMutation: (() -> Void)?
    @ObservationIgnored var cloudKitScopeIDProvider: (@MainActor () -> String?)?

    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Forwards refresh failures to the app-root error mount
    /// (`AppEnvironment.surfaceError` → banner). Without this,
    /// `lastError` dead-ends: no view reads it, so a failing scoped
    /// refresh (seed/bed/planting journal sections) shows silently
    /// stale or empty data.
    @ObservationIgnored private var errorSink: (@MainActor (Error) -> Void)?

    init(client: SeedkeepClient, container: ModelContainer) {
        self.client = client
        self.container = container
    }

    func wireErrorSink(_ sink: @escaping @MainActor (Error) -> Void) {
        errorSink = sink
    }

    /// Fetch the latest server feed and merge into the local store. Views
    /// read from SwiftData via `@Query`; this method just refills.
    /// Optional filters scope the refresh to a single seed / bed / planting event.
    func refresh(
        seedID: String? = nil,
        bedID: String? = nil,
        plantingEventID: String? = nil
    ) async {
        guard !FeatureFlags.cloudKitHouseholdSyncEnabled else {
            lastError = nil
            return
        }
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
            errorSink?(error)
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
        plantingEventID: String? = nil,
        householdID: String? = nil
    ) async throws -> LocalJournalEntry {
        if FeatureFlags.cloudKitHouseholdSyncEnabled {
            guard let householdID, !householdID.isEmpty else {
                throw SeedkeepError(
                    code: "missing_active_garden",
                    message: "The active garden is unavailable. Sync or reopen the garden and try again."
                )
            }
            let context = ModelContext(container)
            try validateParentScope(
                seedID: seedID,
                bedID: bedID,
                plantingEventID: plantingEventID,
                householdID: householdID,
                context: context
            )
            let now = Self.nowMs()
            let local = LocalJournalEntry(
                id: "journal_local_\(UUID().uuidString)",
                householdID: householdID,
                occurredOn: occurredOn,
                body: body,
                seedID: seedID,
                bedID: bedID,
                plantingEventID: plantingEventID,
                createdAt: now,
                updatedAt: now,
                deletedAt: nil
            )
            context.insert(local)
            try context.save()
            onLocalHouseholdMutation?()
            return local
        }

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

    func update(
        _ entry: LocalJournalEntry,
        occurredOn: String,
        body: String,
        seedID: String?,
        bedID: String?,
        plantingEventID: String?,
        householdID: String? = nil
    ) async throws {
        if FeatureFlags.cloudKitHouseholdSyncEnabled {
            guard let householdID, !householdID.isEmpty, entry.householdID == householdID else {
                throw SeedkeepError(
                    code: "inactive_garden_entry",
                    message: "This entry belongs to a different garden. Reopen the active garden and try again."
                )
            }
            let context = ModelContext(container)
            try validateParentScope(
                seedID: seedID,
                bedID: bedID,
                plantingEventID: plantingEventID,
                householdID: householdID,
                context: context
            )
            let id = entry.id
            guard let local = try context.fetch(
                FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
            ).first, local.deletedAt == nil, local.householdID == householdID else {
                throw SeedkeepError(code: "not_found", message: "Journal entry not found")
            }
            local.occurredOn = occurredOn
            local.body = body
            local.seedID = seedID
            local.bedID = bedID
            local.plantingEventID = plantingEventID
            local.updatedAt = max(Self.nowMs(), local.updatedAt + 1)
            try context.save()
            onLocalHouseholdMutation?()
            return
        }

        var patch = SeedkeepClient.UpdateJournalEntryInput()
        patch.occurredOn = occurredOn
        patch.body = body
        patch.seedId = .some(seedID)
        patch.bedId = .some(bedID)
        patch.plantingEventId = .some(plantingEventID)
        let dto = try await client.updateJournalEntry(entry.id, patch)
        let context = ModelContext(container)
        let id = entry.id
        if let local = try context.fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
        ).first {
            dto.apply(to: local)
            try context.save()
        }
    }

    /// Soft-delete on server, mirror locally by marking `deletedAt`.
    func softDelete(_ entry: LocalJournalEntry, householdID: String? = nil) async throws {
        if FeatureFlags.cloudKitHouseholdSyncEnabled {
            guard let householdID, !householdID.isEmpty, entry.householdID == householdID else {
                throw SeedkeepError(
                    code: "inactive_garden_entry",
                    message: "This entry belongs to a different garden. Reopen the active garden and try again."
                )
            }
            let context = ModelContext(container)
            let id = entry.id
            guard let local = try context.fetch(
                FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
            ).first, local.deletedAt == nil, local.householdID == householdID else { return }
            let now = max(Self.nowMs(), local.updatedAt + 1)
            local.deletedAt = now
            local.updatedAt = now
            try context.save()
            onLocalHouseholdMutation?()
            return
        }

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

    @discardableResult
    func addChecklistItem(
        entryID: String,
        text: String,
        householdID: String? = nil
    ) async throws -> LocalJournalChecklistItem {
        if FeatureFlags.cloudKitHouseholdSyncEnabled {
            let context = ModelContext(container)
            _ = try requireActiveEntry(entryID: entryID, householdID: householdID, context: context)
            let id = entryID
            let existing = try context.fetch(
                FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.entryID == id })
            )
            let local = LocalJournalChecklistItem(
                id: "journal_checklist_local_\(UUID().uuidString)",
                entryID: entryID,
                text: text,
                completed: false,
                sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1,
                updatedAt: Self.nowMs()
            )
            context.insert(local)
            try context.save()
            onLocalHouseholdMutation?()
            return local
        }

        let dto = try await client.addChecklistItem(entryId: entryID, text: text)
        let context = ModelContext(container)
        let local = dto.makeLocal()
        context.insert(local)
        try context.save()
        return local
    }

    func updateChecklistItem(
        _ item: LocalJournalChecklistItem,
        text: String? = nil,
        completed: Bool? = nil,
        sortOrder: Int? = nil,
        householdID: String? = nil
    ) async throws {
        if FeatureFlags.cloudKitHouseholdSyncEnabled {
            let context = ModelContext(container)
            _ = try requireActiveEntry(entryID: item.entryID, householdID: householdID, context: context)
            let id = item.id
            guard let local = try context.fetch(
                FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == id })
            ).first else {
                throw SeedkeepError(code: "not_found", message: "Checklist item not found")
            }
            if let text { local.text = text }
            if let completed { local.completed = completed }
            if let sortOrder { local.sortOrder = sortOrder }
            local.updatedAt = max(Self.nowMs(), local.updatedAt + 1)
            try context.save()
            onLocalHouseholdMutation?()
            return
        }

        let dto = try await client.updateChecklistItem(
            item.id,
            .init(text: text, completed: completed, sortOrder: sortOrder)
        )
        let context = ModelContext(container)
        let id = item.id
        if let local = try context.fetch(
            FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == id })
        ).first {
            dto.apply(to: local)
            try context.save()
        }
    }

    func deleteChecklistItem(
        _ item: LocalJournalChecklistItem,
        householdID: String? = nil
    ) async throws {
        if FeatureFlags.cloudKitHouseholdSyncEnabled {
            let validationContext = ModelContext(container)
            let activeEntry = try requireActiveEntry(
                entryID: item.entryID,
                householdID: householdID,
                context: validationContext
            )
            let recordName = SeedkeepRecordNames.journalChecklistItem(item.id)
            let activeHouseholdID = activeEntry.householdID
            guard let scopeID = cloudKitScopeIDProvider?(), !scopeID.isEmpty else {
                throw SeedkeepError(
                    code: "missing_cloudkit_scope",
                    message: "The active iCloud garden is unavailable. Sync or reopen the garden and try again."
                )
            }
            let context = ModelContext(container)
            let id = item.id
            if let local = try context.fetch(
                FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == id })
            ).first {
                let deletionID = "\(scopeID)|\(recordName)"
                let existingIntent = try context.fetch(
                    FetchDescriptor<LocalCloudKitDeletion>(predicate: #Predicate { $0.id == deletionID })
                ).first
                if existingIntent == nil {
                    context.insert(LocalCloudKitDeletion(
                        scopeID: scopeID, householdID: activeHouseholdID,
                        recordName: recordName,
                        createdAt: Self.nowMs()
                    ))
                }
                context.delete(local)
                try context.save()
                onLocalHouseholdMutation?()
            }
            return
        }

        try await client.deleteChecklistItem(item.id)
        let context = ModelContext(container)
        let id = item.id
        if let local = try context.fetch(
            FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == id })
        ).first {
            context.delete(local)
            try context.save()
        }
    }

    /// Retrospective fetch (anchor MM-DD).
    func retrospective(on anchor: String, householdID: String? = nil) async throws -> RetrospectiveResponseDTO {
        if FeatureFlags.cloudKitHouseholdSyncEnabled {
            guard let householdID, !householdID.isEmpty else {
                return RetrospectiveResponseDTO(anchor: anchor, years: [])
            }
            let anchors = try Self.retrospectiveWindow(anchor)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let currentYear = calendar.component(.year, from: Date())
            let context = ModelContext(container)
            let hid = householdID
            let rows = try context.fetch(
                FetchDescriptor<LocalJournalEntry>(predicate: #Predicate {
                    $0.householdID == hid && $0.deletedAt == nil
                })
            ).filter { entry in
                guard entry.occurredOn.count >= 10,
                      let year = Int(entry.occurredOn.prefix(4)),
                      year < currentYear else { return false }
                return anchors.contains(String(entry.occurredOn.suffix(5)))
            }.sorted {
                $0.occurredOn == $1.occurredOn ? $0.id > $1.id : $0.occurredOn > $1.occurredOn
            }
            let grouped = Dictionary(grouping: rows) { Int($0.occurredOn.prefix(4))! }
            let years = grouped.keys.sorted(by: >).map { year in
                RetrospectiveYearDTO(year: year, entries: grouped[year, default: []].map(Self.dto))
            }
            return RetrospectiveResponseDTO(anchor: anchor, years: years)
        }
        return try await client.journalRetrospective(on: anchor)
    }

    private func validateParentScope(
        seedID: String?,
        bedID: String?,
        plantingEventID: String?,
        householdID: String,
        context: ModelContext
    ) throws {
        guard [seedID, bedID, plantingEventID].compactMap({ $0 }).count <= 1 else {
            throw SeedkeepError(code: "invalid_parent", message: "Choose only one journal attachment")
        }
        if let seedID {
            let id = seedID
            guard try context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate {
                $0.id == id && $0.householdID == householdID && $0.deletedAt == nil
            })).first != nil else {
                throw SeedkeepError(code: "invalid_parent", message: "The selected seed is not in the active garden")
            }
        }
        if let bedID {
            let id = bedID
            guard try context.fetch(FetchDescriptor<LocalBed>(predicate: #Predicate {
                $0.id == id && $0.householdID == householdID && $0.deletedAt == nil
            })).first != nil else {
                throw SeedkeepError(code: "invalid_parent", message: "The selected bed is not in the active garden")
            }
        }
        if let plantingEventID {
            let id = plantingEventID
            guard try context.fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate {
                $0.id == id && $0.householdID == householdID && $0.deletedAt == nil
            })).first != nil else {
                throw SeedkeepError(code: "invalid_parent", message: "The selected planting is not in the active garden")
            }
        }
    }

    private func requireActiveEntry(
        entryID: String,
        householdID: String?,
        context: ModelContext
    ) throws -> LocalJournalEntry {
        guard let householdID, !householdID.isEmpty else {
            throw SeedkeepError(
                code: "missing_active_garden",
                message: "The active garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        let id = entryID
        guard let entry = try context.fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
        ).first, entry.deletedAt == nil, entry.householdID == householdID else {
            throw SeedkeepError(
                code: "inactive_garden_entry",
                message: "This entry belongs to a different garden. Reopen the active garden and try again."
            )
        }
        return entry
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static func dto(_ entry: LocalJournalEntry) -> JournalEntryDTO {
        JournalEntryDTO(
            id: entry.id,
            householdId: entry.householdID,
            occurredOn: entry.occurredOn,
            body: entry.body,
            seedId: entry.seedID,
            bedId: entry.bedID,
            plantingEventId: entry.plantingEventID,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            deletedAt: entry.deletedAt
        )
    }

    private static func retrospectiveWindow(_ anchor: String) throws -> Set<String> {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        let parts = anchor.split(separator: "-").compactMap { Int($0) }
        guard anchor.range(of: #"^\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              parts.count == 2,
              (1...12).contains(parts[0]),
              (1...31).contains(parts[1]),
              let base = parser.date(from: "2000-\(anchor)") else {
            throw SeedkeepError(code: "bad_request", message: "A valid MM-DD retrospective date is required")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return Set((-3...3).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: base).map(formatter.string)
        })
    }
}
