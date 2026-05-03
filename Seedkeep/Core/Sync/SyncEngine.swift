import Foundation
import SwiftData
import SeedkeepKit

/// Reconciles SwiftData with the Workers backend.
///
/// **Pull**: `syncAll()` walks `locations`, `tags`, `seeds` in order. Each
/// pass uses the `LocalSyncCursor` row for that table as the `?since=`
/// watermark and upserts incoming DTOs. Deletes the local row when the
/// server marks `deleted_at`.
///
/// **Push**: `flushPending()` drains `LocalPendingWrite` rows in createdAt
/// order. On 2xx, it removes the pending row. On error it bumps
/// `attemptCount` and stores `lastError`. Phase 1 doesn't add backoff —
/// retries fire on the next `syncAll()` (see step E for hardening).
///
/// **Optimistic writes**: `enqueueCreate / enqueueUpdate / enqueueDelete`
/// mutate the local entity AND insert a `LocalPendingWrite` in a single
/// SwiftData save. Views call these directly; they don't touch the API
/// surface.
@MainActor
public final class SyncEngine {
    private let client: SeedkeepClient
    private let container: ModelContainer
    public private(set) var isSyncing: Bool = false
    public private(set) var lastError: String?

    public init(client: SeedkeepClient, container: ModelContainer) {
        self.client = client
        self.container = container
    }

    // MARK: - Pull

    public func syncAll(householdID: String) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await pullLocations(householdID: householdID)
            try await pullTags(householdID: householdID)
            try await pullSeeds(householdID: householdID)
            try await flushPending()
            lastError = nil
        } catch let err as SeedkeepError {
            lastError = "\(err.code): \(err.message)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func pullLocations(householdID: String) async throws {
        let cursor = currentCursor(householdID: householdID, kind: "locations")
        var since = cursor
        repeat {
            let page = try await client.locations(since: since)
            try upsertLocations(page.items)
            since = page.cursor
            try saveCursor(householdID: householdID, kind: "locations", cursor: since)
            if !page.has_more { break }
        } while true
    }

    private func pullTags(householdID: String) async throws {
        let cursor = currentCursor(householdID: householdID, kind: "tags")
        var since = cursor
        repeat {
            let page = try await client.tags(since: since)
            try upsertTags(page.items)
            since = page.cursor
            try saveCursor(householdID: householdID, kind: "tags", cursor: since)
            if !page.has_more { break }
        } while true
    }

    private func pullSeeds(householdID: String) async throws {
        let cursor = currentCursor(householdID: householdID, kind: "seeds")
        var since = cursor
        repeat {
            let page = try await client.seeds(since: since)
            try upsertSeeds(page.items)
            since = page.cursor
            try saveCursor(householdID: householdID, kind: "seeds", cursor: since)
            if !page.has_more { break }
        } while true
    }

    // MARK: - Push (write queue)

    public func flushPending() async throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalPendingWrite>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let pending = try context.fetch(descriptor)
        for write in pending {
            do {
                try await dispatch(write)
                context.delete(write)
                try context.save()
            } catch let err as SeedkeepError {
                write.attemptCount += 1
                write.lastError = "\(err.code): \(err.message)"
                try? context.save()
                // Don't loop on the same broken row in this pass.
            } catch {
                write.attemptCount += 1
                write.lastError = error.localizedDescription
                try? context.save()
            }
        }
    }

    private func dispatch(_ write: LocalPendingWrite) async throws {
        switch (write.entityType, write.operation) {
        case ("location", "create"):
            let body = try JSONDecoder().decode(LocationCreate.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.createLocation(name: body.name, sortOrder: body.sort_order ?? 0)
            try replaceLocalLocation(oldID: write.entityID, with: dto)

        case ("location", "update"):
            let body = try JSONDecoder().decode(LocationUpdate.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.updateLocation(id: write.entityID, name: body.name, sortOrder: body.sort_order)
            try upsertLocations([dto])

        case ("location", "delete"):
            _ = try await client.deleteLocation(id: write.entityID)

        case ("tag", "create"):
            let body = try JSONDecoder().decode(TagCreate.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.createTag(name: body.name, color: body.color)
            try replaceLocalTag(oldID: write.entityID, with: dto)

        case ("tag", "update"):
            let body = try JSONDecoder().decode(TagUpdate.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.updateTag(id: write.entityID, name: body.name, color: body.color.map { Optional($0) })
            try upsertTags([dto])

        case ("tag", "delete"):
            _ = try await client.deleteTag(id: write.entityID)

        case ("seed", "create"):
            let body = try JSONDecoder().decode(SeedkeepClient.CreateSeedInput.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.createSeed(body)
            // Server may echo a different id only if the client didn't supply one.
            try replaceLocalSeed(oldID: write.entityID, with: dto)

        case ("seed", "update"):
            let body = try JSONDecoder().decode(SeedkeepClient.UpdateSeedInput.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.updateSeed(id: write.entityID, body)
            try upsertSeeds([dto])

        case ("seed", "delete"):
            _ = try await client.deleteSeed(id: write.entityID)

        default:
            throw SeedkeepError(code: "unknown_pending_op", message: "Unknown pending write \(write.entityType)/\(write.operation)")
        }
    }

    // MARK: - Optimistic write entrypoints (called by views)

    public func enqueueCreateLocation(name: String, sortOrder: Int = 0, householdID: String) throws -> LocalLocation {
        let id = "loc_local_\(UUID().uuidString)"
        let now = Self.nowMs()
        let local = LocalLocation(id: id, householdID: householdID, name: name, sortOrder: sortOrder, createdAt: now, updatedAt: now)
        let payload = try JSONEncoder().encode(LocationCreate(name: name, sort_order: sortOrder))
        let pending = LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "location", entityID: id, operation: "create",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        )
        let context = ModelContext(container)
        context.insert(local)
        context.insert(pending)
        try context.save()
        return local
    }

    public func enqueueUpdateLocation(id: String, name: String?, sortOrder: Int?) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchLocation(id: id, in: context) {
            if let name { local.name = name }
            if let sortOrder { local.sortOrder = sortOrder }
            local.updatedAt = now
        }
        let payload = try JSONEncoder().encode(LocationUpdate(name: name, sort_order: sortOrder))
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "location", entityID: id, operation: "update",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        ))
        try context.save()
    }

    public func enqueueDeleteLocation(id: String) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchLocation(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "location", entityID: id, operation: "delete",
            payloadJSON: "{}",
            createdAt: now
        ))
        try context.save()
    }

    public func enqueueCreateTag(name: String, color: String?, householdID: String) throws -> LocalTag {
        let id = "tag_local_\(UUID().uuidString)"
        let now = Self.nowMs()
        let local = LocalTag(id: id, householdID: householdID, name: name, color: color, createdAt: now, updatedAt: now)
        let payload = try JSONEncoder().encode(TagCreate(name: name, color: color))
        let pending = LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "tag", entityID: id, operation: "create",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        )
        let context = ModelContext(container)
        context.insert(local)
        context.insert(pending)
        try context.save()
        return local
    }

    public func enqueueUpdateTag(id: String, name: String?, color: String??) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchTag(id: id, in: context) {
            if let name { local.name = name }
            if let color { local.color = color }
            local.updatedAt = now
        }
        let payload = try JSONEncoder().encode(TagUpdate(
            name: name,
            color: color.flatMap { $0 }
        ))
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "tag", entityID: id, operation: "update",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        ))
        try context.save()
    }

    public func enqueueDeleteTag(id: String) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchTag(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "tag", entityID: id, operation: "delete",
            payloadJSON: "{}",
            createdAt: now
        ))
        try context.save()
    }

    public func enqueueCreateSeed(_ input: SeedkeepClient.CreateSeedInput, householdID: String) throws -> LocalSeed {
        // Use the client-supplied id when present so the local row's id
        // matches what the server will store. Otherwise generate locally.
        let id = input.id ?? "seed_local_\(UUID().uuidString)"
        var input = input
        input.id = id
        let now = Self.nowMs()
        let local = LocalSeed(
            id: id,
            householdID: householdID,
            catalogID: input.catalog_id,
            state: input.state,
            packetCount: input.packet_count,
            locationID: input.location_id,
            yearPacked: input.year_packed,
            source: input.source,
            customName: input.custom_name,
            customVariety: input.custom_variety,
            customCompany: input.custom_company,
            notes: input.notes,
            tagIDs: input.tag_ids ?? [],
            createdAt: now,
            updatedAt: now
        )
        let payload = try JSONEncoder().encode(input)
        let pending = LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "seed", entityID: id, operation: "create",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        )
        let context = ModelContext(container)
        context.insert(local)
        context.insert(pending)
        try context.save()
        return local
    }

    public func enqueueUpdateSeed(id: String, _ patch: SeedkeepClient.UpdateSeedInput) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchSeed(id: id, in: context) {
            if let s = patch.state { local.state = s }
            if let n = patch.packet_count { local.packetCount = n }
            if let lid = patch.location_id { local.locationID = lid }
            if let y = patch.year_packed { local.yearPacked = y }
            if let s = patch.source { local.source = s }
            if let n = patch.custom_name { local.customName = n }
            if let v = patch.custom_variety { local.customVariety = v }
            if let c = patch.custom_company { local.customCompany = c }
            if let n = patch.notes { local.notes = n }
            if let ids = patch.tag_ids { local.tagIDs = ids }
            local.updatedAt = now
        }
        let payload = try JSONEncoder().encode(patch)
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "seed", entityID: id, operation: "update",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        ))
        try context.save()
    }

    public func enqueueDeleteSeed(id: String) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchSeed(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "seed", entityID: id, operation: "delete",
            payloadJSON: "{}",
            createdAt: now
        ))
        try context.save()
    }

    // MARK: - SwiftData helpers

    private func currentCursor(householdID: String, kind: String) -> Int64 {
        let context = ModelContext(container)
        let key = LocalSyncCursor.key(householdID: householdID, kind: kind)
        let descriptor = FetchDescriptor<LocalSyncCursor>(predicate: #Predicate { $0.id == key })
        return (try? context.fetch(descriptor).first?.cursor) ?? 0
    }

    private func saveCursor(householdID: String, kind: String, cursor: Int64) throws {
        let context = ModelContext(container)
        let key = LocalSyncCursor.key(householdID: householdID, kind: kind)
        let descriptor = FetchDescriptor<LocalSyncCursor>(predicate: #Predicate { $0.id == key })
        if let existing = try context.fetch(descriptor).first {
            existing.cursor = cursor
            existing.lastSyncedAt = Self.nowMs()
        } else {
            context.insert(LocalSyncCursor(
                householdID: householdID,
                kind: kind,
                cursor: cursor,
                lastSyncedAt: Self.nowMs()
            ))
        }
        try context.save()
    }

    private func upsertLocations(_ items: [LocationDTO]) throws {
        let context = ModelContext(container)
        for dto in items {
            let id = dto.id
            let descriptor = FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.id == id })
            if let existing = try context.fetch(descriptor).first {
                if dto.deleted_at != nil {
                    context.delete(existing)
                } else {
                    dto.apply(to: existing)
                }
            } else if dto.deleted_at == nil {
                context.insert(dto.makeLocal())
            }
        }
        try context.save()
    }

    private func upsertTags(_ items: [TagDTO]) throws {
        let context = ModelContext(container)
        for dto in items {
            let id = dto.id
            let descriptor = FetchDescriptor<LocalTag>(predicate: #Predicate { $0.id == id })
            if let existing = try context.fetch(descriptor).first {
                if dto.deleted_at != nil {
                    context.delete(existing)
                } else {
                    dto.apply(to: existing)
                }
            } else if dto.deleted_at == nil {
                context.insert(dto.makeLocal())
            }
        }
        try context.save()
    }

    private func upsertSeeds(_ items: [SeedDTO]) throws {
        let context = ModelContext(container)
        for dto in items {
            let id = dto.id
            let descriptor = FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id })
            if let existing = try context.fetch(descriptor).first {
                if dto.deleted_at != nil {
                    context.delete(existing)
                } else {
                    dto.apply(to: existing)
                }
            } else if dto.deleted_at == nil {
                context.insert(dto.makeLocal())
            }
        }
        try context.save()
    }

    private func fetchLocation(id: String, in context: ModelContext) throws -> LocalLocation? {
        let descriptor = FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func fetchTag(id: String, in context: ModelContext) throws -> LocalTag? {
        let descriptor = FetchDescriptor<LocalTag>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func fetchSeed(id: String, in context: ModelContext) throws -> LocalSeed? {
        let descriptor = FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func replaceLocalLocation(oldID: String, with dto: LocationDTO) throws {
        let context = ModelContext(container)
        if oldID != dto.id, let stale = try fetchLocation(id: oldID, in: context) {
            context.delete(stale)
        }
        try upsertLocations([dto])
    }

    private func replaceLocalTag(oldID: String, with dto: TagDTO) throws {
        let context = ModelContext(container)
        if oldID != dto.id, let stale = try fetchTag(id: oldID, in: context) {
            context.delete(stale)
        }
        try upsertTags([dto])
    }

    private func replaceLocalSeed(oldID: String, with dto: SeedDTO) throws {
        let context = ModelContext(container)
        if oldID != dto.id, let stale = try fetchSeed(id: oldID, in: context) {
            context.delete(stale)
        }
        try upsertSeeds([dto])
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Pending-write payload shapes

private struct LocationCreate: Codable, Sendable {
    let name: String
    let sort_order: Int?
}

private struct LocationUpdate: Codable, Sendable {
    let name: String?
    let sort_order: Int?
}

private struct TagCreate: Codable, Sendable {
    let name: String
    let color: String?
}

private struct TagUpdate: Codable, Sendable {
    let name: String?
    let color: String?
}
