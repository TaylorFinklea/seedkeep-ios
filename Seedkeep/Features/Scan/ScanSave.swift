import Foundation
import OSLog
import SwiftData
import SeedkeepKit

/// The local writes a packet save makes. `SyncEngine` conforms. Tests substitute doubles that fail
/// on purpose.
@MainActor
protocol ScanSaveWriter: AnyObject {
    func enqueueCreateSeed(_ input: SeedkeepClient.CreateSeedInput, householdID: String) throws -> LocalSeed
    func setLocalGrowingInfo(seedID: String, snapshot: GrowingInfoSnapshot?) throws
    func setLocalCustomType(seedID: String, type: String?) throws
    func uploadPhoto(
        seedID: String,
        role: PhotoRole,
        jpegData: Data,
        householdID: String,
        photoID: String?,
        capturedAt: Int64?
    ) async throws
    /// True when a seed photo with this ID is stored locally.
    func seedPhotoExists(id: String) throws -> Bool
}

extension SyncEngine: ScanSaveWriter {}

/// One sheet's save of a new seed (N2 slice D). The seed ID is chosen up front, the seed is created
/// at most once, and a retry after a partial save finishes that seed instead of creating a second.
///
/// For a scan, the order keeps every extracted detail recoverable:
///   1. link the staging to the chosen seed ID, with the details still to write;
///   2. create the seed;
///   3. write the growing info and custom type, even when a staging write failed;
///   4. attach the staged photos.
/// A staging error is reported after the seed and its details are written. A launch resume replays
/// whatever the manifest still lists.
///
/// The session is bound to the account, garden and scan epoch the sheet opened under (V1). If they
/// change, the save stops before writing anything more, discards the scan's staging and throws
/// `ScopeChanged`; every later call throws it too.
@MainActor
final class SeedSaveSession {
    /// The save stopped because the account or garden changed under the sheet.
    struct ScopeChanged: LocalizedError {
        var errorDescription: String? { ScanPhotoStaging.scopeChangedNotice }
    }

    /// The ID the seed is created under, chosen before anything is written.
    let seedID: String
    /// True once the seed row exists. The sheet then fixes its fields and offers Retry.
    private(set) var seedCreated = false
    /// True once a scan's staging was found missing: its photos are gone, so a retry skips them.
    private(set) var stagingLost = false
    /// The scope and epoch the sheet opened under.
    private(set) var binding: ScanPhotoStaging.ScanBinding?
    /// True once the scope changed under the session. Nothing more is written.
    private(set) var isInvalidated = false

    init(seedID: String = "seed_local_\(UUID().uuidString)") {
        self.seedID = seedID
    }

    /// Binds the session to the scope the sheet opens under. Only the first binding counts.
    func bind(_ binding: ScanPhotoStaging.ScanBinding?) {
        if self.binding == nil { self.binding = binding }
    }

    /// Saves the seed in the bound garden, with its details and, for a scan, its photos. Safe to call
    /// again after a throw. Throws `ScopeChanged` when the scope moved; otherwise a detail or photo
    /// failure first, then a staging failure, after everything else was written.
    func save(
        _ input: SeedkeepClient.CreateSeedInput,
        scanID: UUID?,
        snapshot: GrowingInfoSnapshot?,
        customType: String?,
        writer: any ScanSaveWriter,
        current: @escaping @MainActor () -> ScanPhotoStaging.ScanBinding?,
        root: URL = ScanPhotoStaging.rootDirectory()
    ) async throws {
        try requireBinding(current: current, scanID: scanID, root: root)
        guard let binding else { throw ScopeChanged() }
        let householdID = binding.scope.householdID
        let growingInfo = snapshot.flatMap { $0.hasAny ? $0 : nil }
        var stagingError: Error?

        // 1. The link comes before the seed, so a stop between the two still names the seed and its
        //    details at the next launch.
        if let scanID, !stagingLost {
            do {
                try ScanPhotoStaging.link(
                    seedID: seedID,
                    scope: binding.scope,
                    details: ScanPhotoStaging.PendingDetails(growingInfo: growingInfo, customType: customType),
                    scanID: scanID,
                    root: root
                )
            } catch ScanPhotoStaging.StagingError.scopeMismatch {
                // The scan was captured in another garden: it never saves here.
                isInvalidated = true
                ScanPhotoStaging.discard(scanID: scanID, root: root)
                throw ScopeChanged()
            } catch ScanPhotoStaging.StagingError.missing {
                stagingLost = true
                // A save that already attached both photos removed its staging: nothing is lost (V2).
                if !(try photosAttached(scanID: scanID, writer: writer)) {
                    stagingError = ScanPhotoStaging.StagingError.missing
                }
            } catch {
                stagingError = error
            }
        }

        // 2. The seed, once.
        if !seedCreated {
            var input = input
            input.id = seedID
            _ = try writer.enqueueCreateSeed(input, householdID: householdID)
            seedCreated = true
        }

        // 3. The details, whatever happened to the staging.
        let linkedScan = (stagingError == nil && !stagingLost) ? scanID : nil
        if let growingInfo {
            try writer.setLocalGrowingInfo(seedID: seedID, snapshot: growingInfo)
            if let linkedScan {
                do { try ScanPhotoStaging.markApplied(.growingInfo, scanID: linkedScan, root: root) }
                catch { stagingError = stagingError ?? error }
            }
        }
        if let customType {
            try writer.setLocalCustomType(seedID: seedID, type: customType)
            if let linkedScan {
                do { try ScanPhotoStaging.markApplied(.customType, scanID: linkedScan, root: root) }
                catch { stagingError = stagingError ?? error }
            }
        }

        // 4. The photos, each only while the scope still holds.
        if let scanID, !stagingLost {
            do {
                try await ScanSave.attachStagedPhotos(
                    scanID: scanID, seedID: seedID, householdID: householdID, writer: writer, root: root,
                    beforeEachUpload: { [weak self] in
                        try self?.requireBinding(current: current, scanID: scanID, root: root)
                    }
                )
            } catch ScanPhotoStaging.StagingError.missing {
                stagingLost = true
                if !(try photosAttached(scanID: scanID, writer: writer)) {
                    stagingError = stagingError ?? ScanPhotoStaging.StagingError.missing
                }
            }
        }

        if let stagingError { throw stagingError }
    }

    /// Throws `ScopeChanged`, after discarding the scan's staging, unless the bound scope is still
    /// current.
    private func requireBinding(
        current: @MainActor () -> ScanPhotoStaging.ScanBinding?,
        scanID: UUID?,
        root: URL
    ) throws {
        if !isInvalidated, let binding, binding.matches(current()) { return }
        isInvalidated = true
        if let scanID { ScanPhotoStaging.discard(scanID: scanID, root: root) }
        throw ScopeChanged()
    }

    /// True when both of the scan's stable-ID photos are already stored.
    private func photosAttached(scanID: UUID, writer: any ScanSaveWriter) throws -> Bool {
        try ScanPhotoStaging.Side.allCases.allSatisfy {
            try writer.seedPhotoExists(id: ScanPhotoStaging.photoID(for: scanID, side: $0))
        }
    }
}

/// Saves a packet scan as a seed (N2 slice D). Each step is a local write. The photos attach under
/// stable IDs, so a retry or a relaunch can repeat any step without making a duplicate.
@MainActor
enum ScanSave {
    private static let logger = Logger(subsystem: "app.seedkeep", category: "ScanSave")

    /// Attaches the scan's staged photos to `seedID` under stable IDs. Each side is recorded as
    /// attached once its upload succeeds and is never attached again; a side with no staged photo is
    /// skipped. The staging is removed once no photo is left to attach and every detail is applied.
    static func attachStagedPhotos(
        scanID: UUID,
        seedID: String,
        householdID: String,
        writer: any ScanSaveWriter,
        root: URL = ScanPhotoStaging.rootDirectory(),
        beforeEachUpload: () throws -> Void = {}
    ) async throws {
        guard let manifest = ScanPhotoStaging.manifest(for: scanID, root: root) else {
            throw ScanPhotoStaging.StagingError.missing
        }
        for side in ScanPhotoStaging.Side.allCases where !manifest.isAttached(side) {
            guard let data = ScanPhotoStaging.photoData(side, scanID: scanID, root: root),
                  let capturedAt = manifest.capturedAt(side) else {
                logger.error("A scan's \(side.rawValue, privacy: .public) photo is not staged; it is skipped.")
                continue
            }
            try beforeEachUpload()
            try await writer.uploadPhoto(
                seedID: seedID,
                role: side.role,
                jpegData: data,
                householdID: householdID,
                photoID: ScanPhotoStaging.photoID(for: scanID, side: side),
                capturedAt: capturedAt
            )
            try ScanPhotoStaging.markAttached(side, scanID: scanID, root: root)
        }
        if ScanPhotoStaging.manifest(for: scanID, root: root)?.details?.isComplete ?? true {
            ScanPhotoStaging.discard(scanID: scanID, root: root)
        }
    }

    /// Launch work (N2 slice D), run once the iCloud identity is confirmed. Removes staging from
    /// scans that never saved, discards staging from another account or garden, then finishes each
    /// scan linked to a seed in `scope`: details first, then the photos not yet attached.
    ///
    /// A seed that is not found yet (still syncing, or its create never landed) keeps its staging
    /// for a later launch, until `linkedRetention`. A deleted seed's staging is discarded, as is any
    /// linked staging older than `linkedRetention`. A failed step keeps the staging for the next
    /// launch.
    static func resumeStagedScans(
        writer: any ScanSaveWriter,
        container: ModelContainer,
        scope: ScanPhotoStaging.Scope,
        now: Date = Date(),
        root: URL = ScanPhotoStaging.rootDirectory()
    ) async {
        ScanPhotoStaging.removeStaleUnsaved(now: now, root: root)
        for directory in ScanPhotoStaging.scanDirectories(root: root) {
            guard let scanID = ScanPhotoStaging.scanID(in: directory),
                  let manifest = ScanPhotoStaging.manifest(for: scanID, root: root) else { continue }
            // Another garden's photos never attach here. Matched on the garden only (V3): a legacy
            // identity's scan keeps its server user ID after the rebind to the iCloud record name.
            guard manifest.scope?.householdID == scope.householdID else {
                ScanPhotoStaging.discard(scanID: scanID, root: root)
                continue
            }
            guard let seedID = manifest.seedID else { continue }
            guard now.timeIntervalSince(ScanPhotoStaging.createdDate(manifest)) <= ScanPhotoStaging.linkedRetention else {
                ScanPhotoStaging.discard(scanID: scanID, root: root)
                continue
            }

            let seed: LocalSeed?
            do {
                let id = seedID
                seed = try ModelContext(container)
                    .fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id }))
                    .first
            } catch {
                logger.error("Could not look up a scan's seed; its photos stay staged: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let seed else { continue }   // not here yet: kept until `linkedRetention`
            guard seed.deletedAt == nil else {
                ScanPhotoStaging.discard(scanID: scanID, root: root)
                continue
            }
            do {
                try replayDetails(manifest, seed: seed, writer: writer, root: root)
                try await attachStagedPhotos(
                    scanID: scanID, seedID: seedID, householdID: seed.householdID,
                    writer: writer, root: root
                )
            } catch {
                logger.error("Could not finish a scan's save at launch; it stays staged: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writes the details a cut-short save did not apply, recording each one as it lands.
    /// A field the seed already has (the user, or another device, set it since) is kept, never
    /// overwritten; it counts as applied (V4).
    private static func replayDetails(
        _ manifest: ScanPhotoStaging.Manifest,
        seed: LocalSeed,
        writer: any ScanSaveWriter,
        root: URL
    ) throws {
        guard let details = manifest.details else { return }
        if let growingInfo = details.growingInfo, !details.growingInfoApplied {
            if seed.growingInfo == nil {
                try writer.setLocalGrowingInfo(seedID: seed.id, snapshot: growingInfo)
            }
            try ScanPhotoStaging.markApplied(.growingInfo, scanID: manifest.scanID, root: root)
        }
        if let customType = details.customType, !details.customTypeApplied {
            if seed.customType == nil {
                try writer.setLocalCustomType(seedID: seed.id, type: customType)
            }
            try ScanPhotoStaging.markApplied(.customType, scanID: manifest.scanID, root: root)
        }
    }
}
