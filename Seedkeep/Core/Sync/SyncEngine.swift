import Foundation
import SwiftData
import SeedkeepKit
import SeedkeepCloudKit

/// The household garden's local write boundary.
///
/// Views call `enqueueCreate / enqueueUpdate / enqueueDelete` (and the photo
/// methods): each mutates SwiftData in one save, then signals
/// `onLocalHouseholdMutation` exactly once so the CloudKit coordinator pushes
/// the change. Nothing is queued for a server: N3 removed the server sync, and
/// `LocalPendingWrite` rows left by older builds stay untouched in the store.
@MainActor
public final class SyncEngine {
    private let container: ModelContainer
    public var onLocalHouseholdMutation: (() -> Void)?
    /// N2-E: the fence (contract §6). Every write is refused while the active garden is gone, awaiting
    /// a choice or under a running journal, and a write that began in an earlier garden scope does
    /// nothing. `AppEnvironment` sets it; nil (a bare engine in a unit test) is unfenced.
    var writeFence: GardenWriteFence?
    /// N2-E: where reminders are scheduled. A reminder scheduled after its garden scope went stale is
    /// cancelled again.
    var notifier: any GardenNotifying = LiveGardenNotifier()
    var cloudKitScopeIDProvider: (@MainActor () -> String?)?
    var onCloudKitPhotoCacheMiss: (@MainActor (String) async throws -> Data?)?

    public init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Local store wipe (Stabilization B3)

    /// Deletes every row of every `@Model` in the app schema. Generic
    /// over `SeedkeepSchema.all` — the authoritative model list — so a
    /// future model is automatically covered without touching this
    /// function. The list includes the `LocalPendingWrite` and
    /// `LocalSyncCursor` rows older builds left behind. Called on sign-out
    /// and when a different iCloud user resolves on a device that holds
    /// another account's store.
    public func eraseAllLocalData() throws {
        let context = ModelContext(container)
        for model in SeedkeepSchema.all {
            try eraseAllRows(of: model, in: context)
        }
        try context.save()
    }

    /// Fetch-and-delete (not `context.delete(model:)`) so in-memory test
    /// containers and live stores behave identically.
    private func eraseAllRows<T: PersistentModel>(of type: T.Type, in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }

    // MARK: - Local write entrypoints (called by views)

    /// Refuses the write when the fence says no garden is writable. Every entry point below calls it
    /// first; none awaits between this check and its save, so the scope cannot change in between.
    /// The re-check at an async writer's final mutation boundary: garden and epoch must still be the
    /// ones it began in.
    private func confirmWritable(_ captured: WritableGarden?) throws {
        if let captured { try writeFence?.confirm(captured) }
    }

    private func requireWritable() throws {
        _ = try writeFence?.begin()
    }

    private func noteLocalHouseholdMutation() {
        onLocalHouseholdMutation?()
    }

    public func enqueueCreateLocation(name: String, sortOrder: Int = 0, householdID: String) throws -> LocalLocation {
        try requireWritable()
        let id = "loc_local_\(UUID().uuidString)"
        let now = Self.nowMs()
        let local = LocalLocation(id: id, householdID: householdID, name: name, sortOrder: sortOrder, createdAt: now, updatedAt: now)
        let context = ModelContext(container)
        context.insert(local)
        try context.save()
        noteLocalHouseholdMutation()
        return local
    }

    public func enqueueUpdateLocation(id: String, name: String?, sortOrder: Int?) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchLocation(id: id, in: context) {
            if let name { local.name = name }
            if let sortOrder { local.sortOrder = sortOrder }
            local.updatedAt = now
        }
        try context.save()
        noteLocalHouseholdMutation()
    }

    public func enqueueDeleteLocation(id: String) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchLocation(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        try context.save()
        noteLocalHouseholdMutation()
    }

    public func enqueueCreateTag(name: String, color: String?, householdID: String) throws -> LocalTag {
        try requireWritable()
        let id = "tag_local_\(UUID().uuidString)"
        let now = Self.nowMs()
        let local = LocalTag(id: id, householdID: householdID, name: name, color: color, createdAt: now, updatedAt: now)
        let context = ModelContext(container)
        context.insert(local)
        try context.save()
        noteLocalHouseholdMutation()
        return local
    }

    public func enqueueUpdateTag(id: String, name: String?, color: String??) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchTag(id: id, in: context) {
            if let name { local.name = name }
            if let color { local.color = color }
            local.updatedAt = now
        }
        try context.save()
        noteLocalHouseholdMutation()
    }

    public func enqueueDeleteTag(id: String) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchTag(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        try context.save()
        noteLocalHouseholdMutation()
    }

    public func enqueueCreateSeed(_ input: CreateSeedInput, householdID: String) throws -> LocalSeed {
        try requireWritable()
        // Use the caller-supplied id when present (a scan's stable id); otherwise generate one.
        let id = input.id ?? "seed_local_\(UUID().uuidString)"
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
        let context = ModelContext(container)
        context.insert(local)
        try context.save()
        noteLocalHouseholdMutation()
        return local
    }

    public func enqueueUpdateSeed(id: String, _ patch: UpdateSeedInput) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchSeed(id: id, in: context) {
            // Nullable fields are double-optional (contract decision 8):
            // `if let` unwraps only the OUTER optional, so an omitted
            // field (nil) is left alone while an explicit clear
            // (.some(nil)) assigns nil through to the local row.
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
        try context.save()
        noteLocalHouseholdMutation()
    }

    /// Updates the growing-info snapshot stored in the CloudKit household record.
    /// Successful edits set `updatedAt` to max(now, previous + 1), then schedule a coordinator save.
    public func setLocalGrowingInfo(seedID: String, snapshot: GrowingInfoSnapshot?) throws {
        try requireWritable()
        let context = ModelContext(container)
        guard let local = try fetchSeed(id: seedID, in: context) else { return }
        local.growingInfo = snapshot
        local.updatedAt = max(Self.nowMs(), local.updatedAt + 1)
        try context.save()
        noteLocalHouseholdMutation()
    }

    /// Updates the custom type stored in the CloudKit household record.
    /// Successful edits set `updatedAt` to max(now, previous + 1), then schedule a coordinator save.
    public func setLocalCustomType(seedID: String, type: String?) throws {
        try requireWritable()
        let context = ModelContext(container)
        guard let local = try fetchSeed(id: seedID, in: context) else { return }
        let trimmed = type?.trimmingCharacters(in: .whitespacesAndNewlines)
        local.customType = (trimmed?.isEmpty == false) ? trimmed : nil
        local.updatedAt = max(Self.nowMs(), local.updatedAt + 1)
        try context.save()
        noteLocalHouseholdMutation()
    }

    public func enqueueDeleteSeed(id: String) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchSeed(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        try context.save()
        noteLocalHouseholdMutation()
    }

    // MARK: - Beds (Phase 2)

    public func enqueueCreateBed(_ input: CreateBedInput, householdID: String) throws -> LocalBed {
        try requireWritable()
        let id = input.id ?? "bed_local_\(UUID().uuidString)"
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
        let context = ModelContext(container)
        context.insert(local)
        try context.save()
        noteLocalHouseholdMutation()
        return local
    }

    public func enqueueUpdateBed(id: String, _ patch: UpdateBedInput) throws {
        try requireWritable()
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
        try context.save()
        noteLocalHouseholdMutation()
    }

    public func enqueueDeleteBed(id: String) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchBed(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        try context.save()
        noteLocalHouseholdMutation()
    }

    // MARK: - Planting events (Phase 2)

    /// Schedule a local "planned for today" reminder for the event, but
    /// only when the user has the planting-reminders toggle on. The
    /// scheduling itself is silent on permission denial.
    private func scheduleEventReminder(_ event: LocalPlantingEvent) {
        guard DevicePreferences.store.bool(forKey: "seedkeep.notif.events") else { return }
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
        let captured = try? writeFence?.begin()
        let fence = writeFence
        let notifier = notifier
        Task { @MainActor in
            await notifier.scheduleEventReminder(
                eventID: eventID,
                plannedFor: plannedFor,
                kindLabel: kindLabel,
                seedName: seedName
            )
            // The garden went stale (gone, a binding or account change) while the reminder was being
            // scheduled: take it back.
            if let fence, let captured, !fence.isStillValid(captured) {
                notifier.cancelEventReminder(eventID: eventID)
            }
        }
    }

    public func enqueueCreatePlantingEvent(_ input: CreatePlantingEventInput, householdID: String) throws -> LocalPlantingEvent {
        try requireWritable()
        // The "planned for today" reminder scheduled below is keyed by this id, so completing or
        // deleting the event can cancel it.
        let id = input.id ?? "pe_local_\(UUID().uuidString)"
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
        let context = ModelContext(container)
        context.insert(local)
        try context.save()
        noteLocalHouseholdMutation()
        // Phase 4 C — schedule a local "Planned for today" reminder. No-op
        // when the user has notifications off; permission check happens
        // inside the call.
        scheduleEventReminder(local)
        // Phase 4C — let WeatherWarningsService refresh its 0/active gate.
        NotificationCenter.default.post(name: .weatherWarningsActivePlantingsChanged, object: nil)
        return local
    }

    public func enqueueUpdatePlantingEvent(id: String, _ patch: UpdatePlantingEventInput) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchPlantingEvent(id: id, in: context) {
            if let b = patch.bed_id { local.bedID = b }
            if let s = patch.seed_id { local.seedID = s }
            if let c = patch.catalog_seed_id { local.catalogSeedID = c }
            if let k = patch.kind { local.kindRaw = k }
            if let p = patch.planned_for { local.plannedFor = p }
            // completed_at is double-optional: omitted leaves the local
            // value alone; .some(nil) (mark incomplete) clears it, which
            // also flows into the reminder reschedule branch below.
            if let done = patch.completed_at { local.completedAt = done }
            if let n = patch.notes { local.notes = n }
            if let x = patch.x_feet { local.xFeet = x }
            if let y = patch.y_feet { local.yFeet = y }
            local.updatedAt = now
        }
        try context.save()
        noteLocalHouseholdMutation()
        // Phase 4 C — reschedule (or cancel, if completed) the reminder.
        if let local = try fetchPlantingEvent(id: id, in: context) {
            if local.completedAt != nil {
                Task { @MainActor in
                    notifier.cancelEventReminder(eventID: id)
                }
            } else {
                scheduleEventReminder(local)
            }
        }
        // Phase 4C — let WeatherWarningsService re-evaluate (an update
        // may have toggled completedAt, changing the active count).
        NotificationCenter.default.post(name: .weatherWarningsActivePlantingsChanged, object: nil)
    }

    public func enqueueDeletePlantingEvent(id: String) throws {
        try requireWritable()
        let now = Self.nowMs()
        let context = ModelContext(container)
        if let local = try fetchPlantingEvent(id: id, in: context) {
            local.deletedAt = now
            local.updatedAt = now
        }
        try context.save()
        noteLocalHouseholdMutation()
        // Phase 4 C — drop any pending reminder for this event.
        // Phase 5.1.4 — also drop any pet notifications for this event.
        Task { @MainActor in
            NotificationsCenter.shared.cancelPlantingEventReminder(eventID: id)
            NotificationsCenter.shared.cancelAllPetNotifications(eventID: id)
        }
        // Phase 4C — let WeatherWarningsService re-evaluate (a delete
        // may drop the active count to 0).
        NotificationCenter.default.post(name: .weatherWarningsActivePlantingsChanged, object: nil)
    }

    /// True when a seed photo row with this ID is stored locally (a scan's stable-ID photo, N2).
    public func seedPhotoExists(id: String) throws -> Bool {
        try ModelContext(container).fetchCount(
            FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.id == id })
        ) > 0
    }

    /// Creates a seed photo through the active storage path and persists its local row. A caller
    /// that passes `photoID` (a scan's photo, N2) gets a stable ID: a row that already exists is
    /// left as it is, so a retry or relaunch never adds a second photo.
    public func uploadPhoto(
        seedID: String,
        role: PhotoRole,
        jpegData: Data,
        householdID: String,
        photoID: String? = nil,
        capturedAt: Int64? = nil
    ) async throws {
        let captured = try writeFence?.begin()
        guard !householdID.isEmpty else {
            throw SeedkeepError(
                code: "missing_active_garden",
                message: "The active garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        let context = ModelContext(container)
        guard let seed = try fetchSeed(id: seedID, in: context),
              seed.householdID == householdID,
              seed.deletedAt == nil else {
            throw SeedkeepError(
                code: "inactive_garden_seed",
                message: "This seed belongs to a different garden. Reopen the active garden and try again."
            )
        }
        let id = photoID ?? "seed_photo_local_\(UUID().uuidString)"
        let existing = try context.fetch(
            FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.id == id })
        ).first
        if existing != nil { return }
        let recordName = SeedkeepRecordNames.seedPhoto(id)
        let pending = PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
        try pending.write(jpegData, for: recordName)
        let photo = LocalSeedPhoto(
            id: id,
            seedID: seedID,
            householdID: householdID,
            r2Key: nil,
            role: role,
            byteSize: jpegData.count,
            capturedAt: capturedAt ?? Int64(Date().timeIntervalSince1970 * 1_000)
        )
        context.insert(photo)
        do {
            try confirmWritable(captured)
            try context.save()
        } catch {
            pending.remove(recordName)
            throw error
        }
        onLocalHouseholdMutation?()
    }

    public func fetchSeedPhotoData(
        photoID: String,
        householdID: String? = nil
    ) async throws -> Data? {
        guard let householdID, !householdID.isEmpty else {
            throw SeedkeepError(
                code: "missing_active_garden",
                message: "The active garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        let context = ModelContext(container)
        let id = photoID
        guard let photo = try context.fetch(
            FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.id == id })
        ).first else { return nil }
        guard photo.householdID == householdID else {
            throw SeedkeepError(
                code: "inactive_garden_photo",
                message: "This photo belongs to a different garden. Reopen the active garden and try again."
            )
        }
        let recordName = SeedkeepRecordNames.seedPhoto(photoID)
        let pending = PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
        let cache = PhotoByteStore(lifetime: .cache, householdID: householdID)
        if let data = pending.data(for: recordName) ?? cache.data(for: recordName) {
            return data
        }
        return try await onCloudKitPhotoCacheMiss?(recordName)
    }

    func deleteSeedPhoto(_ photoID: String, householdID: String) async throws {
        let captured = try writeFence?.begin()
        guard !householdID.isEmpty else {
            throw SeedkeepError(
                code: "missing_active_garden",
                message: "The active garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        guard let scopeID = cloudKitScopeIDProvider?(), !scopeID.isEmpty else {
            throw SeedkeepError(
                code: "missing_cloudkit_scope",
                message: "The active iCloud garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        let context = ModelContext(container)
        let id = photoID
        guard let photo = try context.fetch(
            FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        guard photo.householdID == householdID else {
            throw SeedkeepError(
                code: "inactive_garden_photo",
                message: "This photo belongs to a different garden. Reopen the active garden and try again."
            )
        }
        let recordName = SeedkeepRecordNames.seedPhoto(photo.id)
        let deletionID = "\(scopeID)|\(recordName)"
        let existingIntent = try context.fetch(
            FetchDescriptor<LocalCloudKitDeletion>(predicate: #Predicate { $0.id == deletionID })
        ).first
        if existingIntent == nil {
            context.insert(LocalCloudKitDeletion(
                scopeID: scopeID,
                householdID: householdID,
                recordName: recordName,
                createdAt: Int64(Date().timeIntervalSince1970 * 1_000)
            ))
        }
        context.delete(photo)
        try confirmWritable(captured)
        try context.save()
        PhotoByteStore.purgeRecord(recordName, householdID: householdID)
        onLocalHouseholdMutation?()
    }

    func uploadJournalPhoto(
        entryId: String,
        jpegData: Data,
        width: Int? = nil,
        height: Int? = nil,
        householdID: String? = nil
    ) async throws -> LocalJournalEntryPhoto {
        let captured = try writeFence?.begin()
        guard let householdID, !householdID.isEmpty else {
            throw SeedkeepError(
                code: "missing_active_garden",
                message: "The active garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        let context = ModelContext(container)
        let entryID = entryId
        guard let entry = try context.fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == entryID })
        ).first, entry.deletedAt == nil, entry.householdID == householdID else {
            throw SeedkeepError(
                code: "inactive_garden_entry",
                message: "This entry belongs to a different garden. Reopen the active garden and try again."
            )
        }
        let existing = try context.fetch(
            FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.entryID == entryID })
        )
        let id = "journal_photo_local_\(UUID().uuidString)"
        let recordName = SeedkeepRecordNames.journalEntryPhoto(id)
        let pending = PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
        try pending.write(jpegData, for: recordName)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let photo = LocalJournalEntryPhoto(
            id: id,
            entryID: entryId,
            storageKey: nil,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1,
            width: width,
            height: height,
            createdAt: now,
            updatedAt: now
        )
        context.insert(photo)
        do {
            try confirmWritable(captured)
            try context.save()
        } catch {
            pending.remove(recordName)
            throw error
        }
        onLocalHouseholdMutation?()
        return photo
    }

    func deleteJournalPhoto(_ photoID: String, householdID: String? = nil) async throws {
        let captured = try writeFence?.begin()
        guard let householdID, !householdID.isEmpty else {
            throw SeedkeepError(
                code: "missing_active_garden",
                message: "The active garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        guard let scopeID = cloudKitScopeIDProvider?(), !scopeID.isEmpty else {
            throw SeedkeepError(
                code: "missing_cloudkit_scope",
                message: "The active iCloud garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        let context = ModelContext(container)
        let id = photoID
        guard let photo = try context.fetch(
            FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        let entryID = photo.entryID
        guard let entry = try context.fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == entryID })
        ).first, entry.householdID == householdID else {
            throw SeedkeepError(
                code: "inactive_garden_photo",
                message: "This photo belongs to a different garden. Reopen the active garden and try again."
            )
        }
        let recordName = SeedkeepRecordNames.journalEntryPhoto(photo.id)
        let deletionID = "\(scopeID)|\(recordName)"
        let existingIntent = try context.fetch(
            FetchDescriptor<LocalCloudKitDeletion>(predicate: #Predicate { $0.id == deletionID })
        ).first
        if existingIntent == nil {
            context.insert(LocalCloudKitDeletion(
                scopeID: scopeID,
                householdID: householdID,
                recordName: recordName,
                createdAt: Int64(Date().timeIntervalSince1970 * 1_000)
            ))
        }
        context.delete(photo)
        try confirmWritable(captured)
        try context.save()
        PhotoByteStore.purgeRecord(recordName, householdID: householdID)
        onLocalHouseholdMutation?()
    }

    public func journalPhotoData(
        photoId: String,
        householdID: String? = nil
    ) async throws -> Data? {
        guard let householdID, !householdID.isEmpty else {
            throw SeedkeepError(
                code: "missing_active_garden",
                message: "The active garden is unavailable. Sync or reopen the garden and try again."
            )
        }
        let context = ModelContext(container)
        let id = photoId
        guard let photo = try context.fetch(
            FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.id == id })
        ).first else { return nil }
        let entryID = photo.entryID
        guard let entry = try context.fetch(
            FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == entryID })
        ).first, entry.householdID == householdID else {
            throw SeedkeepError(
                code: "inactive_garden_photo",
                message: "This photo belongs to a different garden. Reopen the active garden and try again."
            )
        }
        let recordName = SeedkeepRecordNames.journalEntryPhoto(photoId)
        let pending = PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
        let cache = PhotoByteStore(lifetime: .cache, householdID: householdID)
        if let data = pending.data(for: recordName) ?? cache.data(for: recordName) {
            return data
        }
        return try await onCloudKitPhotoCacheMiss?(recordName)
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

    private func fetchBed(id: String, in context: ModelContext) throws -> LocalBed? {
        let descriptor = FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func fetchPlantingEvent(id: String, in context: ModelContext) throws -> LocalPlantingEvent? {
        let descriptor = FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
