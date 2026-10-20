import Foundation
import OSLog
import SeedkeepKit

/// Durable staging for the packet photos a scan captures (N2 slice D). A scan's bytes stay here
/// from capture until both photos are attached to the seed the scan saved as, so a save that is
/// cut short can finish at the next launch.
///
/// Staged photos use the saved-photo budget (`PhotoResizer.photo`), not the extraction budget, and
/// a photo that cannot be decoded is an error: the original bytes are never staged.
///
/// Layout: `Application Support/ScanStaging/<scanID>/` holds `front.jpg`, `back.jpg` and
/// `manifest.json`. The manifest records the account and garden the scan belongs to, the seed once
/// it is chosen, the details still to write, each photo's capture time and which photos are
/// attached, so a retry or a launch finishes only what is left, under the same stable IDs.
///
/// Staged photos belong to one account and garden: every local-data eraser purges the whole root
/// (`purgeAll`), and a launch resume discards a manifest from another scope.
enum ScanPhotoStaging {
    enum Side: String, CaseIterable, Codable, Sendable {
        case front
        case back

        var role: PhotoRole {
            switch self {
            case .front: return .front
            case .back: return .back
            }
        }
    }

    /// The iCloud user and the garden a scan was made under. Staging is matched on the garden only:
    /// every account or garden change purges staging and bumps the scan epoch (`ScanBinding`), and a
    /// legacy identity's user ID becomes the iCloud record name at its rebind without either. The
    /// user is kept for diagnostics.
    struct Scope: Codable, Equatable, Sendable {
        let userRecordName: String
        let householdID: String
    }

    /// What a scan or save sheet is bound to when it starts: the scope and the scan epoch, which every
    /// local-data eraser bumps (`AppEnvironment.scanBinding`). A sheet whose binding no longer
    /// matches the current one stops and discards its scan.
    struct ScanBinding: Equatable, Sendable {
        let scope: Scope
        let epoch: Int

        /// True while `current` is the same garden in the same epoch.
        func matches(_ current: ScanBinding?) -> Bool {
            guard let current else { return false }
            return current.epoch == epoch && current.scope.householdID == scope.householdID
        }
    }

    /// The notice a sheet shows when it closes because the scope changed under it.
    static let scopeChangedNotice = "Your iCloud account or garden changed, so Seedkeep stopped saving this seed."

    /// The details a save writes after the seed, kept until each is applied so a launch can replay
    /// any that a cut-short save missed.
    struct PendingDetails: Codable, Equatable, Sendable {
        var growingInfo: GrowingInfoSnapshot?
        var customType: String?
        var growingInfoApplied = false
        var customTypeApplied = false

        var isComplete: Bool {
            (growingInfo == nil || growingInfoApplied) && (customType == nil || customTypeApplied)
        }
    }

    /// Contents of `manifest.json`. Times are Unix milliseconds.
    struct Manifest: Codable, Equatable, Sendable {
        let scanID: UUID
        let createdAt: Int64
        var scope: Scope?
        var seedID: String?
        var details: PendingDetails?
        var frontCapturedAt: Int64?
        var backCapturedAt: Int64?
        /// Sides whose upload succeeded. A recorded side is never attached again.
        var attachedSides: [Side] = []

        func capturedAt(_ side: Side) -> Int64? {
            switch side {
            case .front: return frontCapturedAt
            case .back: return backCapturedAt
            }
        }

        func isAttached(_ side: Side) -> Bool {
            attachedSides.contains(side)
        }
    }

    enum StagingError: Error, LocalizedError {
        case missing
        /// The scan was captured in another garden.
        case scopeMismatch

        var errorDescription: String? {
            switch self {
            case .missing: return "The scan's packet photos are no longer on this device."
            case .scopeMismatch: return "This scan belongs to another garden."
            }
        }
    }

    /// A scan that never reached a saved seed is removed once it is this old.
    static let retention: TimeInterval = 24 * 60 * 60

    /// A scan linked to a seed is retried at launch for this long, then dropped, so a seed that never
    /// appears cannot keep its staging forever.
    static let linkedRetention: TimeInterval = 7 * 24 * 60 * 60

    private static let logger = Logger(subsystem: "app.seedkeep", category: "ScanStaging")

    /// `Application Support/ScanStaging`, without creating it.
    static func rootURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ScanStaging", isDirectory: true)
    }

    /// `Application Support/ScanStaging`, created on demand and excluded from device backups (staged
    /// photos are temporary and belong to one account).
    static func rootDirectory() -> URL {
        var dir = rootURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// The stable ID a scan's photo is stored under. A retry or relaunch reuses it, so the same
    /// photo is never attached twice.
    static func photoID(for scanID: UUID, side: Side) -> String {
        "scan-\(scanID.uuidString)-\(side.rawValue)"
    }

    /// Resizes a captured photo to the saved-photo budget. Runs off the main actor (a 12 MP capture
    /// takes seconds). Throws on undecodable input, and never returns the original bytes.
    nonisolated static func resizedPhoto(_ capture: Data) throws -> Data {
        try PhotoResizer.resizedPhotoJPEG(capture)
    }

    /// Writes one resized photo and records when it was captured and under which scope. The write is
    /// small and synchronous, so it runs on the main actor. Callers check the scan is still active
    /// first, so a cancelled scan cannot recreate its directory.
    static func write(
        _ photo: Data,
        side: Side,
        scanID: UUID,
        scope: Scope,
        capturedAt: Date = Date(),
        root: URL = rootDirectory()
    ) throws {
        let dir = directory(for: scanID, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try photo.write(to: dir.appendingPathComponent("\(side.rawValue).jpg"), options: .atomic)

        let millis = milliseconds(capturedAt)
        var manifest = readManifest(in: dir) ?? Manifest(scanID: scanID, createdAt: millis)
        manifest.scope = scope
        switch side {
        case .front: manifest.frontCapturedAt = millis
        case .back: manifest.backCapturedAt = millis
        }
        try writeManifest(manifest, in: dir)
    }

    /// Links a scan to the seed it will save as, before the seed is created, with the details still
    /// to write. Linking the same seed again keeps what is already applied or attached. The scope the
    /// scan was captured under is kept: a link from another garden throws `scopeMismatch`.
    static func link(
        seedID: String,
        scope: Scope,
        details: PendingDetails,
        scanID: UUID,
        root: URL = rootDirectory()
    ) throws {
        let dir = directory(for: scanID, root: root)
        guard var manifest = readManifest(in: dir) else { throw StagingError.missing }
        if let captured = manifest.scope {
            guard captured.householdID == scope.householdID else { throw StagingError.scopeMismatch }
        } else {
            manifest.scope = scope
        }
        if manifest.seedID != seedID || manifest.details == nil {
            manifest.details = details
            manifest.attachedSides = []
        }
        manifest.seedID = seedID
        try writeManifest(manifest, in: dir)
    }

    /// Which detail a save applied.
    enum Detail: Sendable {
        case growingInfo
        case customType
    }

    /// Records that a detail was written to the seed, so a launch does not replay it.
    static func markApplied(_ detail: Detail, scanID: UUID, root: URL = rootDirectory()) throws {
        let dir = directory(for: scanID, root: root)
        guard var manifest = readManifest(in: dir) else { throw StagingError.missing }
        switch detail {
        case .growingInfo: manifest.details?.growingInfoApplied = true
        case .customType: manifest.details?.customTypeApplied = true
        }
        try writeManifest(manifest, in: dir)
    }

    /// Records that a side's upload succeeded, so it is never attached again.
    static func markAttached(_ side: Side, scanID: UUID, root: URL = rootDirectory()) throws {
        let dir = directory(for: scanID, root: root)
        guard var manifest = readManifest(in: dir) else { throw StagingError.missing }
        if !manifest.attachedSides.contains(side) { manifest.attachedSides.append(side) }
        try writeManifest(manifest, in: dir)
    }

    static func manifest(for scanID: UUID, root: URL = rootDirectory()) -> Manifest? {
        readManifest(in: directory(for: scanID, root: root))
    }

    static func photoData(_ side: Side, scanID: UUID, root: URL = rootDirectory()) -> Data? {
        try? Data(contentsOf: directory(for: scanID, root: root).appendingPathComponent("\(side.rawValue).jpg"))
    }

    /// Deletes a scan's staging. Idempotent.
    static func discard(scanID: UUID, root: URL = rootDirectory()) {
        remove(directory(for: scanID, root: root))
    }

    /// Deletes every scan's staging (N2 + N1 erasers). Throws when the root cannot be removed, so the
    /// eraser fails and is retried rather than leaving another account's photos behind.
    static func purgeAll(root: URL = rootURL()) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// Removes staging for scans that never reached a saved seed and are older than `retention`.
    /// A scan linked to a seed stays until its photos are attached.
    static func removeStaleUnsaved(now: Date = Date(), root: URL = rootDirectory()) {
        for dir in scanDirectories(root: root) {
            let manifest = readManifest(in: dir)
            guard manifest?.seedID == nil else { continue }
            let created = manifest.map(createdDate) ?? modificationDate(of: dir)
            guard let created, now.timeIntervalSince(created) > retention else { continue }
            remove(dir)
        }
    }

    /// When the scan's first photo was captured.
    static func createdDate(_ manifest: Manifest) -> Date {
        Date(timeIntervalSince1970: Double(manifest.createdAt) / 1_000)
    }

    /// The scan staged in `directory`, read from its name.
    static func scanID(in directory: URL) -> UUID? {
        UUID(uuidString: directory.lastPathComponent)
    }

    /// Every scan directory under `root`.
    static func scanDirectories(root: URL = rootDirectory()) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { scanID(in: $0) != nil }
    }

    // MARK: - Private

    private static func directory(for scanID: UUID, root: URL) -> URL {
        root.appendingPathComponent(scanID.uuidString, isDirectory: true)
    }

    private static func readManifest(in dir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func writeManifest(_ manifest: Manifest, in dir: URL) throws {
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func remove(_ dir: URL) {
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            logger.error("Could not delete scan staging: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func modificationDate(of dir: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}
