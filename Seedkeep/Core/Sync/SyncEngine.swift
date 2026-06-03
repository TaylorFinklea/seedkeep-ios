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
    /// Cursor kind for the `GET /api/pets/departures` delta feed.
    /// Declared as a constant to prevent typo drift between the pull
    /// loop and any future cursor-reset / diagnostic surface.
    private static let petDeparturesKind = "pet_departures"

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
            try await pullBeds(householdID: householdID)
            try await pullPlantingEvents(householdID: householdID)
            try await pullPetDepartures(householdID: householdID)
            try await pullJournalEntries(householdID: householdID)
            try await pullAssistantThreads(householdID: householdID)
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

    private func pullBeds(householdID: String) async throws {
        let cursor = currentCursor(householdID: householdID, kind: "beds")
        var since = cursor
        repeat {
            let page = try await client.beds(since: since)
            try upsertBeds(page.items)
            since = page.cursor
            try saveCursor(householdID: householdID, kind: "beds", cursor: since)
            if !page.has_more { break }
        } while true
    }

    private func pullPlantingEvents(householdID: String) async throws {
        let cursor = currentCursor(householdID: householdID, kind: "planting_events")
        var since = cursor
        repeat {
            let page = try await client.plantingEvents(since: since)
            try upsertPlantingEvents(page.items)
            since = page.cursor
            try saveCursor(householdID: householdID, kind: "planting_events", cursor: since)
            if !page.has_more { break }
        } while true
    }

    /// Phase 5.1.2 — cross-device fan-out of `pet_departures` rows. Ordered
    /// **after** `pullPlantingEvents` so the parent planting (and its
    /// `pet_*` identity columns) is already present when a departure row
    /// for that planting arrives. The route returns tombstones on the
    /// same channel; `upsertPetDepartures` hard-deletes locally on a
    /// `deleted_at != nil` payload.
    private func pullPetDepartures(householdID: String) async throws {
        let cursor = currentCursor(
            householdID: householdID,
            kind: Self.petDeparturesKind
        )
        var since = cursor
        repeat {
            let page = try await client.petDepartures(since: since)
            try upsertPetDepartures(page.items)
            since = page.cursor
            try saveCursor(
                householdID: householdID,
                kind: Self.petDeparturesKind,
                cursor: since
            )
            if !page.has_more { break }
        } while true
    }

    private func pullJournalEntries(householdID: String) async throws {
        let cursor = currentCursor(householdID: householdID, kind: "journal_entries")
        var since = cursor
        repeat {
            let page = try await client.journalFeed(since: since)
            try upsertJournalEntries(page.items)
            since = page.cursor
            try saveCursor(householdID: householdID, kind: "journal_entries", cursor: since)
            if !page.has_more { break }
        } while true
    }

    private func pullAssistantThreads(householdID: String) async throws {
        let cursor = currentCursor(householdID: householdID, kind: "assistant_threads")
        var since = cursor
        repeat {
            let page = try await client.assistantThreads(since: since)
            try upsertAssistantThreads(page.items)
            since = page.cursor
            try saveCursor(householdID: householdID, kind: "assistant_threads", cursor: since)
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
        let now = Self.nowMs()
        for write in pending {
            // Skip dead-lettered rows and rows whose backoff window
            // hasn't elapsed.
            if write.isDeadLettered { continue }
            if write.nextAttemptAt > now { continue }

            do {
                try await dispatch(write)
                // On a successful create, wake any dead-lettered children
                // whose payloads reference this just-created entity id.
                // Without this, a planting_event.create that dead-lettered
                // because its seed_id hadn't synced yet stays dead even
                // after the seed.create lands — the user has to manually
                // retry every child.
                if write.operation == "create" {
                    wakeChildrenReferencing(
                        entityType: write.entityType,
                        entityID: write.entityID,
                        in: context)
                }
                context.delete(write)
                try context.save()
            } catch let err as SeedkeepError where write.operation == "delete" && err.code == "not_found" {
                // A delete that the server says doesn't exist is a no-op
                // success: the row is already gone (or never reached the
                // server because its create failed). Either way our local
                // intent — "this row should be deleted" — is satisfied.
                context.delete(write)
                try? context.save()
            } catch let err as SeedkeepError {
                handleFailure(write, message: "\(err.code): \(err.message)", in: context)
            } catch {
                handleFailure(write, message: error.localizedDescription, in: context)
            }
        }
    }

    /// Reset dead-lettered pending writes that reference an entity we
    /// just successfully created. The payload JSON is searched for the
    /// just-created id; matches get attemptCount=0 and nextAttemptAt=now
    /// so the next sync round picks them up.
    private func wakeChildrenReferencing(
        entityType: String,
        entityID: String,
        in context: ModelContext
    ) {
        // Only seeds + beds + planting_events appear as parent
        // references in other write payloads. Locations + tags are
        // referenced by id-array fields on seeds, also covered.
        guard ["seed", "bed", "planting_event", "location", "tag"].contains(entityType) else { return }
        let descriptor = FetchDescriptor<LocalPendingWrite>()
        guard let all = try? context.fetch(descriptor) else { return }
        for child in all where child.isDeadLettered {
            // Cheap textual check — the payload is JSON and the id is
            // sufficiently distinctive (UUID embedded in a prefix). A
            // false positive at worst causes one extra retry, which
            // will succeed or re-dead-letter cleanly.
            if child.payloadJSON.contains("\"\(entityID)\"") {
                child.isDeadLettered = false
                child.attemptCount = 0
                child.lastError = nil
                child.nextAttemptAt = Self.nowMs()
            }
        }
        try? context.save()
    }

    private func handleFailure(_ write: LocalPendingWrite, message: String, in context: ModelContext) {
        write.attemptCount += 1
        write.lastError = message
        if write.attemptCount >= LocalPendingWrite.maxAttempts {
            write.isDeadLettered = true
        } else {
            let backoff = LocalPendingWrite.backoffMillis(forAttempt: write.attemptCount)
            write.nextAttemptAt = Self.nowMs() + backoff
        }
        try? context.save()
    }

    /// Diagnostics view used by Settings → Pending writes.
    public struct PendingWriteSummary: Sendable, Equatable {
        public let total: Int
        public let active: Int
        public let deadLettered: Int
    }

    public func pendingWriteSummary() -> PendingWriteSummary {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalPendingWrite>()
        let rows = (try? context.fetch(descriptor)) ?? []
        let dead = rows.filter { $0.isDeadLettered }.count
        return PendingWriteSummary(
            total: rows.count,
            active: rows.count - dead,
            deadLettered: dead
        )
    }

    /// Resets a single dead-lettered row so it retries on the next sync.
    public func retryPendingWrite(id: String) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalPendingWrite>(predicate: #Predicate { $0.id == id })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.isDeadLettered = false
        row.attemptCount = 0
        row.lastError = nil
        row.nextAttemptAt = Self.nowMs()
        try? context.save()
    }

    /// Drops a pending write entirely. Used when the user decides a stuck
    /// write should be abandoned (the local optimistic state stays — only
    /// the queued push is dropped).
    public func forgetPendingWrite(id: String) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalPendingWrite>(predicate: #Predicate { $0.id == id })
        guard let row = try? context.fetch(descriptor).first else { return }
        context.delete(row)
        try? context.save()
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

        case ("bed", "create"):
            let body = try JSONDecoder().decode(SeedkeepClient.CreateBedInput.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.createBed(body)
            try replaceLocalBed(oldID: write.entityID, with: dto)

        case ("bed", "update"):
            let body = try JSONDecoder().decode(SeedkeepClient.UpdateBedInput.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.updateBed(id: write.entityID, body)
            try upsertBeds([dto])

        case ("bed", "delete"):
            _ = try await client.deleteBed(id: write.entityID)

        case ("planting_event", "create"):
            let body = try JSONDecoder().decode(SeedkeepClient.CreatePlantingEventInput.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.createPlantingEvent(body)
            try replaceLocalPlantingEvent(oldID: write.entityID, with: dto)

        case ("planting_event", "update"):
            let body = try JSONDecoder().decode(SeedkeepClient.UpdatePlantingEventInput.self, from: Data(write.payloadJSON.utf8))
            let dto = try await client.updatePlantingEvent(id: write.entityID, body)
            try upsertPlantingEvents([dto])

        case ("planting_event", "delete"):
            _ = try await client.deletePlantingEvent(id: write.entityID)

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

    /// Updates the local-only growing-info snapshot on a seed. Not sent to
    /// the server — the catalog remains the shared source of truth — but
    /// guarantees the user can always see the depth / temp / spacing they
    /// reviewed at save time, even offline or before the catalog row
    /// finishes processing.
    public func setLocalGrowingInfo(seedID: String, snapshot: GrowingInfoSnapshot?) throws {
        let context = ModelContext(container)
        guard let local = try fetchSeed(id: seedID, in: context) else { return }
        local.growingInfo = snapshot
        try context.save()
    }

    /// Updates the local-only `customType` (e.g. "Pepper", "Tomato") used
    /// to group/filter the Library. Not yet sent to the server — Phase 2
    /// adds a corresponding column so the value syncs across devices.
    public func setLocalCustomType(seedID: String, type: String?) throws {
        let context = ModelContext(container)
        guard let local = try fetchSeed(id: seedID, in: context) else { return }
        let trimmed = type?.trimmingCharacters(in: .whitespacesAndNewlines)
        local.customType = (trimmed?.isEmpty == false) ? trimmed : nil
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

    // MARK: - Beds (Phase 2)

    public func enqueueCreateBed(_ input: SeedkeepClient.CreateBedInput, householdID: String) throws -> LocalBed {
        let id = "bed_local_\(UUID().uuidString)"
        let now = Self.nowMs()
        let local = LocalBed(
            id: id,
            householdID: householdID,
            name: input.name,
            bedDescription: input.description,
            widthFeet: input.width_feet,
            lengthFeet: input.length_feet,
            sortOrder: input.sort_order ?? 0,
            createdAt: now,
            updatedAt: now
        )
        let payload = try JSONEncoder().encode(input)
        let context = ModelContext(container)
        context.insert(local)
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "bed", entityID: id, operation: "create",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        ))
        try context.save()
        return local
    }

    public func enqueueUpdateBed(id: String, _ patch: SeedkeepClient.UpdateBedInput) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchBed(id: id, in: context) {
            if let n = patch.name { local.name = n }
            if let d = patch.description { local.bedDescription = d }
            if let w = patch.width_feet { local.widthFeet = w }
            if let l = patch.length_feet { local.lengthFeet = l }
            if let o = patch.sort_order { local.sortOrder = o }
            local.updatedAt = now
        }
        let payload = try JSONEncoder().encode(patch)
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "bed", entityID: id, operation: "update",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        ))
        try context.save()
    }

    public func enqueueDeleteBed(id: String) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchBed(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "bed", entityID: id, operation: "delete",
            payloadJSON: "{}",
            createdAt: now
        ))
        try context.save()
    }

    // MARK: - Planting events (Phase 2)

    /// Schedule a local "planned for today" reminder for the event, but
    /// only when the user has the planting-reminders toggle on. The
    /// scheduling itself is silent on permission denial.
    private func scheduleEventReminder(_ event: LocalPlantingEvent) {
        guard UserDefaults.standard.bool(forKey: "seedkeep.notif.events") else { return }
        guard event.completedAt == nil, event.deletedAt == nil else { return }
        let eventID = event.id
        let plannedFor = event.plannedFor
        let kindLabel = event.kindRaw.replacingOccurrences(of: "_", with: " ").capitalized
        let seedName: String? = {
            guard let seedID = event.seedID else { return nil }
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == seedID })
            return (try? context.fetch(descriptor))?.first?.customName
        }()
        Task { @MainActor in
            await NotificationsCenter.shared.schedulePlantingEventReminder(
                eventID: eventID,
                plannedFor: plannedFor,
                kindLabel: kindLabel,
                seedName: seedName
            )
        }
    }

    public func enqueueCreatePlantingEvent(_ input: SeedkeepClient.CreatePlantingEventInput, householdID: String) throws -> LocalPlantingEvent {
        let id = "pe_local_\(UUID().uuidString)"
        let now = Self.nowMs()
        let local = LocalPlantingEvent(
            id: id,
            householdID: householdID,
            bedID: input.bed_id,
            seedID: input.seed_id,
            catalogSeedID: input.catalog_seed_id,
            kindRaw: input.kind,
            plannedFor: input.planned_for,
            completedAt: input.completed_at,
            notes: input.notes,
            xFeet: input.x_feet,
            yFeet: input.y_feet,
            createdAt: now,
            updatedAt: now
        )
        let payload = try JSONEncoder().encode(input)
        let context = ModelContext(container)
        context.insert(local)
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "planting_event", entityID: id, operation: "create",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        ))
        try context.save()
        // Phase 4 C — schedule a local "Planned for today" reminder. No-op
        // when the user has notifications off; permission check happens
        // inside the call.
        scheduleEventReminder(local)
        return local
    }

    public func enqueueUpdatePlantingEvent(id: String, _ patch: SeedkeepClient.UpdatePlantingEventInput) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchPlantingEvent(id: id, in: context) {
            if let b = patch.bed_id { local.bedID = b }
            if let s = patch.seed_id { local.seedID = s }
            if let c = patch.catalog_seed_id { local.catalogSeedID = c }
            if let k = patch.kind { local.kindRaw = k }
            if let p = patch.planned_for { local.plannedFor = p }
            if let done = patch.completed_at { local.completedAt = done }
            if let n = patch.notes { local.notes = n }
            if let x = patch.x_feet { local.xFeet = x }
            if let y = patch.y_feet { local.yFeet = y }
            local.updatedAt = now
        }
        let payload = try JSONEncoder().encode(patch)
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "planting_event", entityID: id, operation: "update",
            payloadJSON: String(decoding: payload, as: UTF8.self),
            createdAt: now
        ))
        try context.save()
        // Phase 4 C — reschedule (or cancel, if completed) the reminder.
        if let local = try fetchPlantingEvent(id: id, in: context) {
            if local.completedAt != nil {
                Task { @MainActor in
                    NotificationsCenter.shared.cancelPlantingEventReminder(eventID: id)
                }
            } else {
                scheduleEventReminder(local)
            }
        }
    }

    public func enqueueDeletePlantingEvent(id: String) throws {
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchPlantingEvent(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        context.insert(LocalPendingWrite(
            id: "pw_\(UUID().uuidString)",
            entityType: "planting_event", entityID: id, operation: "delete",
            payloadJSON: "{}",
            createdAt: now
        ))
        try context.save()
        // Phase 4 C — drop any pending reminder for this event.
        // Phase 5.1.4 — also drop any pet notifications for this event.
        Task { @MainActor in
            NotificationsCenter.shared.cancelPlantingEventReminder(eventID: id)
            NotificationsCenter.shared.cancelAllPetNotifications(eventID: id)
        }
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

    private func upsertBeds(_ items: [BedDTO]) throws {
        let context = ModelContext(container)
        for dto in items {
            let id = dto.id
            let descriptor = FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == id })
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

    private func upsertPlantingEvents(_ items: [PlantingEventDTO]) throws {
        let context = ModelContext(container)
        // Track ids whose pending UNUserNotification reminder should be
        // cancelled — either because the server marked the event
        // deleted, or because it's now completed. Without this, a
        // cross-device delete or "mark done" leaves a stale notification
        // queued on the local device.
        var idsToCancelReminder: [String] = []
        for dto in items {
            let id = dto.id
            let descriptor = FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id })
            if let existing = try context.fetch(descriptor).first {
                if dto.deleted_at != nil {
                    idsToCancelReminder.append(id)
                    // Phase 5.1.1 — soft-delete server-side fans out to
                    // a local hard-delete of the planting + cascade to
                    // its plant-pet children (departure row + mood
                    // snapshots). The server-side migration sets
                    // ON DELETE CASCADE so the cascade mirrors exactly.
                    cleanupPlantingEventChildren(eventID: id, context: context)
                    context.delete(existing)
                } else {
                    let wasCompleted = existing.completedAt != nil
                    dto.apply(to: existing)
                    if !wasCompleted && existing.completedAt != nil {
                        idsToCancelReminder.append(id)
                    }
                }
            } else if dto.deleted_at == nil {
                context.insert(dto.makeLocal())
            }
        }
        try context.save()
        if !idsToCancelReminder.isEmpty {
            Task { @MainActor in
                for id in idsToCancelReminder {
                    NotificationsCenter.shared.cancelPlantingEventReminder(eventID: id)
                    // Phase 5.1.4 — cascade pet notification cleanup
                    // alongside the existing event-reminder cleanup so
                    // tombstoned plantings don't leave ghost wilted /
                    // departed pings queued.
                    NotificationsCenter.shared.cancelAllPetNotifications(eventID: id)
                }
            }
        }
    }

    /// Phase 5.1.2 — pull-side upsert for the `pet_departures` delta feed.
    /// Mirrors `upsertJournalEntries`: tombstone (`deleted_at != nil`)
    /// hard-deletes the local row, populated rows insert-or-apply onto
    /// `LocalPetDeparture` keyed by `plantingEventID` (1:1 with the
    /// parent planting).
    private func upsertPetDepartures(_ items: [PetDepartureDTO]) throws {
        let context = ModelContext(container)
        for dto in items {
            let eventID = dto.planting_event_id
            let descriptor = FetchDescriptor<LocalPetDeparture>(
                predicate: #Predicate { $0.plantingEventID == eventID }
            )
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

    /// Hard-deletes the per-pet children of a planting whose parent is
    /// being tombstoned locally (because the server soft-deleted it).
    /// Mirrors the spec's `ON DELETE CASCADE` shape: `LocalPetDeparture`
    /// + every `LocalPetMoodSnapshot` for the event go away. Pet-scoped
    /// pending notifications (`seedkeep.notif.pet.*.<event_id>`) get
    /// cancelled too — Phase 5.1.4 wires the real helpers; for now we
    /// stub the call site so the cleanup contract is documented.
    private func cleanupPlantingEventChildren(eventID: String, context: ModelContext) {
        let depDescriptor = FetchDescriptor<LocalPetDeparture>(
            predicate: #Predicate { $0.plantingEventID == eventID }
        )
        for row in (try? context.fetch(depDescriptor)) ?? [] {
            context.delete(row)
        }
        let snapDescriptor = FetchDescriptor<LocalPetMoodSnapshot>(
            predicate: #Predicate { $0.plantingEventID == eventID }
        )
        for snap in (try? context.fetch(snapDescriptor)) ?? [] {
            context.delete(snap)
        }
        // Pet notification cancellation hook — Phase 5.1.4 wires
        // `NotificationsCenter.cancelPetNotifications(eventID:)`. No-op
        // today so the cleanup site is in place when those helpers land.
    }

    private func upsertJournalEntries(_ items: [JournalEntryDTO]) throws {
        let context = ModelContext(container)
        for dto in items {
            let id = dto.id
            let descriptor = FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == id })
            if let existing = try context.fetch(descriptor).first {
                if dto.deletedAt != nil {
                    // Soft-delete server-side → hard-delete locally + clean
                    // up orphaned children (photos + checklist items). Per
                    // spec decision #6, children are owned strictly by the
                    // parent and don't carry their own deleted_at — they
                    // go away with the parent on the client.
                    try cleanupJournalEntryChildren(entryID: existing.id, context: context)
                    context.delete(existing)
                } else {
                    dto.apply(to: existing)
                }
            } else if dto.deletedAt == nil {
                context.insert(dto.makeLocal())
            }
        }
        try context.save()
    }

    /// Hard-delete local journal photos + checklist items for an entry whose
    /// parent is going away. Called when a journal entry is soft-deleted on
    /// the server and we're hard-deleting it locally.
    private func cleanupJournalEntryChildren(entryID: String, context: ModelContext) throws {
        let photoDescriptor = FetchDescriptor<LocalJournalEntryPhoto>(
            predicate: #Predicate { $0.entryID == entryID })
        for photo in try context.fetch(photoDescriptor) {
            context.delete(photo)
        }
        let itemDescriptor = FetchDescriptor<LocalJournalChecklistItem>(
            predicate: #Predicate { $0.entryID == entryID })
        for item in try context.fetch(itemDescriptor) {
            context.delete(item)
        }
    }

    private func upsertAssistantThreads(_ items: [AssistantThreadDTO]) throws {
        let context = ModelContext(container)
        for dto in items {
            let id = dto.id
            let descriptor = FetchDescriptor<LocalAssistantThread>(predicate: #Predicate { $0.id == id })
            if let existing = try context.fetch(descriptor).first {
                if dto.deletedAt != nil {
                    // Soft-delete server-side → hard-delete locally + cascade
                    // children (messages, tool calls). Per spec, messages are
                    // append-only and tear down with the parent.
                    try cleanupAssistantThreadChildren(threadID: existing.id, context: context)
                    context.delete(existing)
                } else {
                    dto.apply(to: existing)
                }
            } else if dto.deletedAt == nil {
                context.insert(dto.makeLocal())
            }
        }
        try context.save()
    }

    /// Hard-delete local assistant messages + tool calls for a thread that's
    /// being soft-deleted server-side. Per the Phase 4 spec, messages are
    /// append-only and don't have their own deleted_at — they're owned by
    /// the thread.
    private func cleanupAssistantThreadChildren(threadID: String, context: ModelContext) throws {
        let messageDescriptor = FetchDescriptor<LocalAssistantMessage>(
            predicate: #Predicate { $0.threadID == threadID })
        for message in try context.fetch(messageDescriptor) {
            context.delete(message)
        }
        let toolDescriptor = FetchDescriptor<LocalAssistantToolCall>(
            predicate: #Predicate { $0.threadID == threadID })
        for tool in try context.fetch(toolDescriptor) {
            context.delete(tool)
        }
    }

    /// Refresh a single thread's messages + tool calls from the detail route.
    /// Called by AssistantThreadView on appear so cross-device updates land
    /// without waiting for the next syncAll sweep.
    public func refreshAssistantThread(_ threadID: String) async throws {
        let detail = try await client.assistantThread(id: threadID)
        let context = ModelContext(container)
        // Update the thread row too in case its updated_at changed.
        try upsertAssistantThreads([detail.thread])
        // Upsert every message + tool call we got. The server is the source
        // of truth for both; if a local row exists, apply; else insert.
        for dto in detail.messages {
            let id = dto.id
            let d = FetchDescriptor<LocalAssistantMessage>(predicate: #Predicate { $0.id == id })
            if let existing = try context.fetch(d).first { dto.apply(to: existing) }
            else { context.insert(dto.makeLocal()) }
        }
        for dto in detail.toolCalls {
            let id = dto.id
            let d = FetchDescriptor<LocalAssistantToolCall>(predicate: #Predicate { $0.id == id })
            if let existing = try context.fetch(d).first { dto.apply(to: existing) }
            else { context.insert(dto.makeLocal()) }
        }
        try context.save()
    }

    /// Refreshes a seed's photo rows from `GET /api/seeds/:id`. Used after
    /// a photo upload so the detail view sees the new entry. Cheap — the
    /// detail endpoint returns the seed plus its photos.
    public func refreshSeedPhotos(seedID: String, householdID: String) async throws {
        let detail = try await client.seed(id: seedID)
        let context = ModelContext(container)

        // Update the seed itself in case its updated_at changed.
        try upsertSeeds([detail.seed])

        // Replace the photo set for this seed: delete locals not in the
        // server response, upsert ones that are.
        let serverIDs = Set(detail.photos.map(\.id))
        let descriptor = FetchDescriptor<LocalSeedPhoto>(
            predicate: #Predicate { $0.seedID == seedID }
        )
        for local in (try? context.fetch(descriptor)) ?? [] {
            if !serverIDs.contains(local.id) {
                context.delete(local)
            }
        }
        for dto in detail.photos {
            let id = dto.id
            let descriptor = FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.id == id })
            if let existing = try? context.fetch(descriptor).first {
                existing.r2Key = dto.r2_key
                existing.role = dto.role
                existing.width = dto.width
                existing.height = dto.height
                existing.byteSize = dto.byte_size
                existing.capturedAt = dto.captured_at
            } else {
                context.insert(LocalSeedPhoto(
                    id: dto.id,
                    seedID: dto.seed_id,
                    householdID: dto.household_id,
                    r2Key: dto.r2_key,
                    role: dto.role,
                    width: dto.width,
                    height: dto.height,
                    byteSize: dto.byte_size,
                    capturedAt: dto.captured_at
                ))
            }
        }
        try context.save()
    }

    /// Convenience wrapper called by views: upload a photo and refresh
    /// the seed's photo list. Online-only in Phase 1; offline photo
    /// queueing is deferred (see `.docs/ai/roadmap.md`).
    public func uploadPhoto(seedID: String, role: PhotoRole, jpegData: Data, householdID: String) async throws {
        _ = try await client.uploadSeedPhoto(seedID: seedID, role: role, jpegData: jpegData)
        try await refreshSeedPhotos(seedID: seedID, householdID: householdID)
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

    private func fetchBed(id: String, in context: ModelContext) throws -> LocalBed? {
        let descriptor = FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func fetchPlantingEvent(id: String, in context: ModelContext) throws -> LocalPlantingEvent? {
        let descriptor = FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func replaceLocalBed(oldID: String, with dto: BedDTO) throws {
        let context = ModelContext(container)
        if oldID != dto.id, let stale = try fetchBed(id: oldID, in: context) {
            context.delete(stale)
        }
        try upsertBeds([dto])
    }

    private func replaceLocalPlantingEvent(oldID: String, with dto: PlantingEventDTO) throws {
        let context = ModelContext(container)
        if oldID != dto.id, let stale = try fetchPlantingEvent(id: oldID, in: context) {
            context.delete(stale)
        }
        try upsertPlantingEvents([dto])
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
