import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

// N2 slice D: a packet scan saves locally and never reaches the server. Stable photo IDs make a
// retry or a relaunch a no-op, the front is the cover, a failed detail write surfaces, and a
// launch resume finishes a save that was cut short. Each test uses its own household, so the
// photo bytes it writes are purged at the end.
@MainActor
@Suite("Scan save (N2)", .serialized)
struct ScanSaveTests {

    /// Writes seeds and details through a real `SyncEngine` (local rows; no CloudKit flag needed),
    /// records photo uploads in memory under their stable IDs, and fails the writes a test chooses.
    @MainActor
    final class RecordingWriter: ScanSaveWriter {
        struct Injected: Error {}

        let engine: SyncEngine
        var failCreate = false
        var failDetails = false
        var failPhotos = false
        /// Every upload call, in order (a repeat would show up twice).
        private(set) var uploadCalls: [String] = []
        /// Distinct photos stored, like the engine's stable-ID check.
        private(set) var storedPhotoIDs: Set<String> = []
        private(set) var createCount = 0
        /// Runs before each upload is recorded, so a test can change the scope mid-save.
        var onUpload: () -> Void = {}

        init(engine: SyncEngine) { self.engine = engine }

        func enqueueCreateSeed(_ input: SeedkeepClient.CreateSeedInput, householdID: String) throws -> LocalSeed {
            if failCreate { throw Injected() }
            createCount += 1
            return try engine.enqueueCreateSeed(input, householdID: householdID)
        }

        func setLocalGrowingInfo(seedID: String, snapshot: GrowingInfoSnapshot?) throws {
            if failDetails { throw Injected() }
            try engine.setLocalGrowingInfo(seedID: seedID, snapshot: snapshot)
        }

        func setLocalCustomType(seedID: String, type: String?) throws {
            if failDetails { throw Injected() }
            try engine.setLocalCustomType(seedID: seedID, type: type)
        }

        func uploadPhoto(
            seedID: String,
            role: PhotoRole,
            jpegData: Data,
            householdID: String,
            photoID: String?,
            capturedAt: Int64?
        ) async throws {
            if failPhotos { throw Injected() }
            onUpload()
            let id = photoID ?? UUID().uuidString
            uploadCalls.append(id)
            storedPhotoIDs.insert(id)
        }

        func seedPhotoExists(id: String) throws -> Bool {
            storedPhotoIDs.contains(id)
        }
    }

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-save-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeHousehold() -> String {
        "hh-scan-\(UUID().uuidString)"
    }

    private static func makeEngine() -> (engine: SyncEngine, container: ModelContainer) {
        let container = makeTestContainer(name: "scanSave-\(UUID().uuidString)")
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: ServerRetirement.makeRefusingSession()
            ),
            bearerToken: "test_token"
        )
        return (SyncEngine(client: client, container: container), container)
    }

    /// Runs `body` with the CloudKit household path on, then restores the stored setting.
    private static func withCloudKitSync<T>(_ body: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let key = FeatureFlags.cloudKitHouseholdSyncKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        FeatureFlags.setCloudKitHouseholdSync(true)
        return try await body()
    }

    private static func input(_ name: String) -> SeedkeepClient.CreateSeedInput {
        SeedkeepClient.CreateSeedInput(state: .active, custom_name: name)
    }

    private static let userA = "_userA"

    private static func scope(_ householdID: String, user: String = userA) -> ScanPhotoStaging.Scope {
        ScanPhotoStaging.Scope(userRecordName: user, householdID: householdID)
    }

    /// Stages the front and back photos for `scanID`, as the camera flow does.
    private static func stagePair(
        _ scanID: UUID,
        scope: ScanPhotoStaging.Scope,
        root: URL,
        capturedAt: Date = Date()
    ) throws {
        try ScanPhotoStaging.write(
            Data("front-bytes".utf8), side: .front, scanID: scanID, scope: scope,
            capturedAt: capturedAt, root: root
        )
        try ScanPhotoStaging.write(
            Data("back-bytes".utf8), side: .back, scanID: scanID, scope: scope,
            capturedAt: capturedAt.addingTimeInterval(5), root: root
        )
    }

    private static func photos(in container: ModelContainer) throws -> [LocalSeedPhoto] {
        try ModelContext(container).fetch(FetchDescriptor<LocalSeedPhoto>())
    }

    /// Links a staged scan to a new seed ID with `details`, then creates the seed: the state a save
    /// cut short right after step 2 leaves behind.
    private static func createLinkedSeed(
        _ name: String,
        householdID: String,
        scanID: UUID,
        details: ScanPhotoStaging.PendingDetails = .init(),
        writer: any ScanSaveWriter,
        root: URL
    ) throws -> String {
        let seedID = "seed_local_\(UUID().uuidString)"
        try ScanPhotoStaging.link(
            seedID: seedID, scope: Self.scope(householdID), details: details, scanID: scanID, root: root
        )
        var input = Self.input(name)
        input.id = seedID
        _ = try writer.enqueueCreateSeed(input, householdID: householdID)
        return seedID
    }

    private static func seeds(in container: ModelContainer) throws -> [LocalSeed] {
        try ModelContext(container).fetch(FetchDescriptor<LocalSeed>())
    }

    @Test("the save writes the seed, its growing info and both photos locally, with no server request")
    func saveStaysLocal() async throws {
        try await Self.withCloudKitSync {
            let (engine, container) = Self.makeEngine()
            let householdID = Self.makeHousehold()
            defer { try? PhotoByteStore.purgeHousehold(householdID) }
            let root = Self.makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let scanID = UUID()
            let scope = Self.scope(householdID)
            try Self.stagePair(scanID, scope: scope, root: root)
            let refusalsBefore = ServerRetirement.refusals.count

            let session = SeedSaveSession()
            try await session.save(
                Self.input("Cherokee Purple"),
                householdID: householdID,
                scan: (scanID, scope),
                snapshot: GrowingInfoSnapshot(scientific_name: "Solanum lycopersicum", days_to_maturity_min: 75),
                customType: "Tomato",
                writer: engine,
                root: root
            )

            let seed = try #require(try ModelContext(container).fetch(FetchDescriptor<LocalSeed>()).first)
            #expect(seed.id == session.seedID, "the seed is created under the ID chosen up front")
            #expect(seed.growingInfo?.scientific_name == "Solanum lycopersicum")
            #expect(seed.customType == "Tomato")
            #expect(try Self.photos(in: container).count == 2)
            #expect(ServerRetirement.refusals.count == refusalsBefore)
            #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
        }
    }

    @Test("a retried photo keeps its stable ID and is not stored twice")
    func retriedPhotoIsNotDuplicated() async throws {
        try await Self.withCloudKitSync {
            let (engine, container) = Self.makeEngine()
            let householdID = Self.makeHousehold()
            defer { try? PhotoByteStore.purgeHousehold(householdID) }
            let seedID = try engine.enqueueCreateSeed(Self.input("Basil"), householdID: householdID).id
            let photoID = ScanPhotoStaging.photoID(for: UUID(), side: .front)

            for _ in 0..<2 {
                try await engine.uploadPhoto(
                    seedID: seedID, role: .front, jpegData: Data("front".utf8),
                    householdID: householdID, photoID: photoID, capturedAt: 1_000_000
                )
            }

            let stored = try Self.photos(in: container)
            #expect(stored.map(\.id) == [photoID])
            #expect(stored.first?.capturedAt == 1_000_000)
        }
    }

    @Test("the front is the cover even when the back is attached first")
    func frontIsCover() async throws {
        try await Self.withCloudKitSync {
            let (engine, container) = Self.makeEngine()
            let householdID = Self.makeHousehold()
            defer { try? PhotoByteStore.purgeHousehold(householdID) }
            let seedID = try engine.enqueueCreateSeed(Self.input("Dill"), householdID: householdID).id
            let scanID = UUID()
            let front = ScanPhotoStaging.photoID(for: scanID, side: .front)
            let back = ScanPhotoStaging.photoID(for: scanID, side: .back)

            try await engine.uploadPhoto(
                seedID: seedID, role: .back, jpegData: Data("back".utf8),
                householdID: householdID, photoID: back, capturedAt: 1_005_000
            )
            try await engine.uploadPhoto(
                seedID: seedID, role: .front, jpegData: Data("front".utf8),
                householdID: householdID, photoID: front, capturedAt: 1_000_000
            )

            let sid = seedID
            let ordered = try ModelContext(container).fetch(FetchDescriptor<LocalSeedPhoto>(
                predicate: #Predicate<LocalSeedPhoto> { $0.seedID == sid },
                sortBy: SeedDetailView.photoSort
            ))
            #expect(ordered.map(\.id) == [front, back])
        }
    }

    @Test("photos with equal capture times sort by photo ID, so the order is stable")
    func equalCaptureTimesSortByID() async throws {
        try await Self.withCloudKitSync {
            let (engine, container) = Self.makeEngine()
            let householdID = Self.makeHousehold()
            defer { try? PhotoByteStore.purgeHousehold(householdID) }
            let seedID = try engine.enqueueCreateSeed(Self.input("Sage"), householdID: householdID).id
            let scanID = UUID()
            let front = ScanPhotoStaging.photoID(for: scanID, side: .front)
            let back = ScanPhotoStaging.photoID(for: scanID, side: .back)
            for photoID in [front, back] {
                try await engine.uploadPhoto(
                    seedID: seedID, role: .front, jpegData: Data("x".utf8),
                    householdID: householdID, photoID: photoID, capturedAt: 1_000_000
                )
            }

            let sid = seedID
            let ordered = try ModelContext(container).fetch(FetchDescriptor<LocalSeedPhoto>(
                predicate: #Predicate<LocalSeedPhoto> { $0.seedID == sid },
                sortBy: SeedDetailView.photoSort
            ))
            #expect(ordered.map(\.id) == [front, back].sorted())
        }
    }

    // MARK: - Save session (S3, O9)

    @Test("a failed detail write throws, and the retry finishes the same seed instead of creating another")
    func detailFailureRetryReusesSeed() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let writer = RecordingWriter(engine: engine)
        writer.failDetails = true
        let session = SeedSaveSession()
        let snapshot = GrowingInfoSnapshot(scientific_name: "Anethum graveolens")

        await #expect(throws: RecordingWriter.Injected.self) {
            try await session.save(
                Self.input("Dill"), householdID: householdID, scan: nil,
                snapshot: snapshot, customType: "Herb", writer: writer
            )
        }
        #expect(session.seedCreated)

        writer.failDetails = false
        try await session.save(
            Self.input("Dill"), householdID: householdID, scan: nil,
            snapshot: snapshot, customType: "Herb", writer: writer
        )

        let seeds = try Self.seeds(in: container)
        #expect(seeds.map(\.id) == [session.seedID])
        #expect(writer.createCount == 1)
        #expect(seeds.first?.growingInfo?.scientific_name == "Anethum graveolens")
        #expect(seeds.first?.customType == "Herb")
    }

    @Test("a failed photo attach keeps the seed, and the retry attaches without a second seed or photo")
    func photoFailureRetryReusesSeed() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let scope = Self.scope(householdID)
        try Self.stagePair(scanID, scope: scope, root: root)
        let writer = RecordingWriter(engine: engine)
        writer.failPhotos = true
        let session = SeedSaveSession()

        await #expect(throws: RecordingWriter.Injected.self) {
            try await session.save(
                Self.input("Basil"), householdID: householdID, scan: (scanID, scope),
                snapshot: nil, customType: "Basil", writer: writer, root: root
            )
        }
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root)?.seedID == session.seedID)

        writer.failPhotos = false
        try await session.save(
            Self.input("Basil"), householdID: householdID, scan: (scanID, scope),
            snapshot: nil, customType: "Basil", writer: writer, root: root
        )

        #expect(try Self.seeds(in: container).count == 1)
        #expect(writer.uploadCalls.count == 2)
        #expect(writer.storedPhotoIDs == [
            ScanPhotoStaging.photoID(for: scanID, side: .front),
            ScanPhotoStaging.photoID(for: scanID, side: .back),
        ])
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
    }

    @Test("the manifest names the seed and its pending details before the seed is created")
    func linkIsWrittenBeforeTheSeed() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let scope = Self.scope(householdID)
        try Self.stagePair(scanID, scope: scope, root: root)
        let writer = RecordingWriter(engine: engine)
        writer.failCreate = true
        let session = SeedSaveSession()
        let snapshot = GrowingInfoSnapshot(days_to_maturity_min: 60)

        await #expect(throws: RecordingWriter.Injected.self) {
            try await session.save(
                Self.input("Pea"), householdID: householdID, scan: (scanID, scope),
                snapshot: snapshot, customType: "Pea", writer: writer, root: root
            )
        }

        #expect(!session.seedCreated)
        #expect(try Self.seeds(in: container).isEmpty)
        let manifest = try #require(ScanPhotoStaging.manifest(for: scanID, root: root))
        #expect(manifest.seedID == session.seedID)
        #expect(manifest.scope == scope)
        #expect(manifest.details?.growingInfo == snapshot)
        #expect(manifest.details?.customType == "Pea")
        #expect(manifest.details?.isComplete == false)
    }

    @Test("lost staging still saves the seed and its details, reports once, and the retry succeeds")
    func lostStagingStillSavesDetails() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = RecordingWriter(engine: engine)
        let session = SeedSaveSession()
        let scan = (scanID: UUID(), scope: Self.scope(householdID))   // never staged

        await #expect(throws: ScanPhotoStaging.StagingError.self) {
            try await session.save(
                Self.input("Kale"), householdID: householdID, scan: scan,
                snapshot: GrowingInfoSnapshot(frost_tolerance: "hardy"), customType: "Kale",
                writer: writer, root: root
            )
        }

        let seed = try #require(try Self.seeds(in: container).first)
        #expect(seed.growingInfo?.frost_tolerance == "hardy")
        #expect(seed.customType == "Kale")

        try await session.save(
            Self.input("Kale"), householdID: householdID, scan: scan,
            snapshot: GrowingInfoSnapshot(frost_tolerance: "hardy"), customType: "Kale",
            writer: writer, root: root
        )
        #expect(try Self.seeds(in: container).count == 1)
    }

    // MARK: - Launch resume (S1, S3, O5, O6)

    @Test("launch resume attaches the back photo that a cut-short save missed, and never the front again")
    func resumeAttachesOnlyUnattachedSide() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try Self.stagePair(scanID, scope: Self.scope(householdID), root: root)
        let writer = RecordingWriter(engine: engine)
        _ = try Self.createLinkedSeed("Basil", householdID: householdID, scanID: scanID, writer: writer, root: root)
        // The front reached the seed before the app stopped; the back did not.
        try ScanPhotoStaging.markAttached(.front, scanID: scanID, root: root)

        await ScanSave.resumeStagedScans(
            writer: writer, container: container, scope: Self.scope(householdID), root: root
        )

        #expect(writer.uploadCalls == [ScanPhotoStaging.photoID(for: scanID, side: .back)])
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
    }

    @Test("each side is recorded as attached once its upload succeeds")
    func attachedSidesAreRecorded() async throws {
        let (engine, _) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try Self.stagePair(scanID, scope: Self.scope(householdID), root: root)
        let writer = RecordingWriter(engine: engine)
        // Pending details keep the staging after the photos attach, so the flags can be read.
        let seedID = try Self.createLinkedSeed(
            "Basil", householdID: householdID, scanID: scanID,
            details: .init(customType: "Basil"), writer: writer, root: root
        )

        try await ScanSave.attachStagedPhotos(
            scanID: scanID, seedID: seedID, householdID: householdID, writer: writer, root: root
        )

        let manifest = try #require(ScanPhotoStaging.manifest(for: scanID, root: root))
        #expect(manifest.isAttached(.front))
        #expect(manifest.isAttached(.back))

        try await ScanSave.attachStagedPhotos(
            scanID: scanID, seedID: seedID, householdID: householdID, writer: writer, root: root
        )
        #expect(writer.uploadCalls.count == 2, "a recorded side is never attached again")
    }

    @Test("launch resume replays the details a cut-short save never applied, then attaches the photos")
    func resumeReplaysDetails() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try Self.stagePair(scanID, scope: Self.scope(householdID), root: root)
        let writer = RecordingWriter(engine: engine)
        let snapshot = GrowingInfoSnapshot(scientific_name: "Ocimum basilicum", sow_method: "transplant")
        _ = try Self.createLinkedSeed(
            "Basil", householdID: householdID, scanID: scanID,
            details: .init(growingInfo: snapshot, customType: "Basil"), writer: writer, root: root
        )

        await ScanSave.resumeStagedScans(
            writer: writer, container: container, scope: Self.scope(householdID), root: root
        )

        let seed = try #require(try Self.seeds(in: container).first)
        #expect(seed.growingInfo?.scientific_name == "Ocimum basilicum")
        #expect(seed.customType == "Basil")
        #expect(writer.storedPhotoIDs.count == 2)
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
    }

    @Test("an applied detail is not replayed")
    func appliedDetailIsNotReplayed() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try Self.stagePair(scanID, scope: Self.scope(householdID), root: root)
        let writer = RecordingWriter(engine: engine)
        let seedID = try Self.createLinkedSeed(
            "Basil", householdID: householdID, scanID: scanID,
            details: .init(customType: "Basil"), writer: writer, root: root
        )
        try ScanPhotoStaging.markApplied(.customType, scanID: scanID, root: root)
        // The user renamed the type after the save; a replay would undo it.
        try engine.setLocalCustomType(seedID: seedID, type: "Sweet basil")

        await ScanSave.resumeStagedScans(
            writer: writer, container: container, scope: Self.scope(householdID), root: root
        )

        #expect(try Self.seeds(in: container).first?.customType == "Sweet basil")
    }

    @Test("a side with no staged photo is skipped; the other attaches and the staging is removed")
    func missingSideIsSkipped() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try ScanPhotoStaging.write(
            Data("front-bytes".utf8), side: .front, scanID: scanID, scope: Self.scope(householdID), root: root
        )
        let writer = RecordingWriter(engine: engine)
        _ = try Self.createLinkedSeed("Basil", householdID: householdID, scanID: scanID, writer: writer, root: root)

        await ScanSave.resumeStagedScans(
            writer: writer, container: container, scope: Self.scope(householdID), root: root
        )

        #expect(writer.uploadCalls == [ScanPhotoStaging.photoID(for: scanID, side: .front)])
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
    }

    @Test("a failed attach keeps the staging, and the next launch finishes it")
    func failedAttachIsRetriedAtNextLaunch() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try Self.stagePair(scanID, scope: Self.scope(householdID), root: root)
        let writer = RecordingWriter(engine: engine)
        let seedID = try Self.createLinkedSeed("Basil", householdID: householdID, scanID: scanID, writer: writer, root: root)
        writer.failPhotos = true

        await ScanSave.resumeStagedScans(writer: writer, container: container, scope: Self.scope(householdID), root: root)

        #expect(ScanPhotoStaging.manifest(for: scanID, root: root)?.seedID == seedID)
        #expect(writer.storedPhotoIDs.isEmpty)

        writer.failPhotos = false
        await ScanSave.resumeStagedScans(writer: writer, container: container, scope: Self.scope(householdID), root: root)

        #expect(writer.storedPhotoIDs.count == 2)
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
    }

    @Test("a seed not found yet keeps its staging for a later launch")
    func missingSeedIsKept() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let created = Date(timeIntervalSince1970: 1_000_000)
        try Self.stagePair(scanID, scope: Self.scope(householdID), root: root, capturedAt: created)
        try ScanPhotoStaging.link(
            seedID: "seed_not_here_yet", scope: Self.scope(householdID), details: .init(), scanID: scanID, root: root
        )
        let writer = RecordingWriter(engine: engine)

        await ScanSave.resumeStagedScans(
            writer: writer, container: container, scope: Self.scope(householdID),
            now: created.addingTimeInterval(2 * 24 * 60 * 60), root: root
        )

        #expect(ScanPhotoStaging.manifest(for: scanID, root: root)?.seedID == "seed_not_here_yet")
        #expect(writer.uploadCalls.isEmpty)
    }

    @Test("a linked scan older than the retention period is discarded, found or not")
    func oldLinkedScanIsDiscarded() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_000_000)
        let later = created.addingTimeInterval(ScanPhotoStaging.linkedRetention + 60)
        let missing = UUID()
        try Self.stagePair(missing, scope: Self.scope(householdID), root: root, capturedAt: created)
        try ScanPhotoStaging.link(
            seedID: "seed_never", scope: Self.scope(householdID), details: .init(), scanID: missing, root: root
        )
        let found = UUID()
        try Self.stagePair(found, scope: Self.scope(householdID), root: root, capturedAt: created)
        let writer = RecordingWriter(engine: engine)
        _ = try Self.createLinkedSeed("Basil", householdID: householdID, scanID: found, writer: writer, root: root)

        await ScanSave.resumeStagedScans(
            writer: writer, container: container, scope: Self.scope(householdID), now: later, root: root
        )

        #expect(ScanPhotoStaging.manifest(for: missing, root: root) == nil)
        #expect(ScanPhotoStaging.manifest(for: found, root: root) == nil)
        #expect(writer.uploadCalls.isEmpty, "no endless retries past the retention period")
    }

    @Test("launch resume discards the staging of a seed that was deleted")
    func resumeDropsDeletedSeed() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try Self.stagePair(scanID, scope: Self.scope(householdID), root: root)
        let writer = RecordingWriter(engine: engine)
        let seedID = try Self.createLinkedSeed("Mint", householdID: householdID, scanID: scanID, writer: writer, root: root)
        try engine.enqueueDeleteSeed(id: seedID)

        await ScanSave.resumeStagedScans(writer: writer, container: container, scope: Self.scope(householdID), root: root)

        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
        #expect(writer.uploadCalls.isEmpty)
    }

    @Test("staging from another garden is discarded, never attached")
    func mismatchedScopeIsDiscarded() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = RecordingWriter(engine: engine)
        let otherGarden = UUID()
        try Self.stagePair(otherGarden, scope: Self.scope("hh-other"), root: root)
        try ScanPhotoStaging.link(
            seedID: "seed_other", scope: Self.scope("hh-other"), details: .init(), scanID: otherGarden, root: root
        )
        let mine = UUID()
        try Self.stagePair(mine, scope: Self.scope(householdID), root: root)

        await ScanSave.resumeStagedScans(writer: writer, container: container, scope: Self.scope(householdID), root: root)

        #expect(ScanPhotoStaging.manifest(for: otherGarden, root: root) == nil)
        #expect(ScanPhotoStaging.manifest(for: mine, root: root) != nil, "a recent unsaved scan in scope stays")
        #expect(writer.uploadCalls.isEmpty)
    }

    @Test("a scan made under a legacy user ID resumes after the rebind to the iCloud record name (V3)")
    func legacyUserScanResumes() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let legacy = Self.scope(householdID, user: "u_server_legacy")
        try Self.stagePair(scanID, scope: legacy, root: root)
        let writer = RecordingWriter(engine: engine)
        let seedID = "seed_local_\(UUID().uuidString)"
        try ScanPhotoStaging.link(seedID: seedID, scope: legacy, details: .init(), scanID: scanID, root: root)
        var input = Self.input("Basil")
        input.id = seedID
        _ = try writer.enqueueCreateSeed(input, householdID: householdID)

        await ScanSave.resumeStagedScans(writer: writer, container: container, scope: Self.scope(householdID), root: root)

        #expect(writer.storedPhotoIDs.count == 2)
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
    }

    @Test("a replay never overwrites a field the seed already has (V4)")
    func replayKeepsManualEdits() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try Self.stagePair(scanID, scope: Self.scope(householdID), root: root)
        let writer = RecordingWriter(engine: engine)
        let seedID = try Self.createLinkedSeed(
            "Basil", householdID: householdID, scanID: scanID,
            details: .init(growingInfo: GrowingInfoSnapshot(sow_method: "direct"), customType: "Basil"),
            writer: writer, root: root
        )
        // Not yet applied by the save, but edited by the user before the relaunch.
        try engine.setLocalCustomType(seedID: seedID, type: "Sweet basil")
        try engine.setLocalGrowingInfo(seedID: seedID, snapshot: GrowingInfoSnapshot(sow_method: "transplant"))

        await ScanSave.resumeStagedScans(writer: writer, container: container, scope: Self.scope(householdID), root: root)

        let seed = try #require(try Self.seeds(in: container).first)
        #expect(seed.customType == "Sweet basil")
        #expect(seed.growingInfo?.sow_method == "transplant")
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil, "the details count as applied")
    }

    // MARK: - Scope binding (V1) and attached-photo check (V2)

    @Test("a scan handed over without a binding never saves, even into the current garden")
    func unboundScanNeverSaves() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let scope = Self.scope(householdID)
        try Self.stagePair(scanID, scope: scope, root: root)
        let writer = RecordingWriter(engine: engine)
        let session = SeedSaveSession()
        // The confirm sheet binds to the scan's own binding; a scan that had none passes nil, and the
        // current scope must not stand in for it.
        session.bind(nil)
        let current = MovableBinding(ScanPhotoStaging.ScanBinding(scope: scope, epoch: 0))

        await #expect(throws: SeedSaveSession.ScopeChanged.self) {
            try await session.save(
                Self.input("Basil"), scanID: scanID, snapshot: nil, customType: "Basil",
                writer: writer, current: { current.value }, root: root
            )
        }

        #expect(try Self.seeds(in: container).isEmpty)
        #expect(writer.uploadCalls.isEmpty)
    }

    @Test("a save after a scope change neither creates a seed nor attaches, and discards the staging")
    func saveAfterScopeChangeStops() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let scope = Self.scope(householdID)
        try Self.stagePair(scanID, scope: scope, root: root)
        let writer = RecordingWriter(engine: engine)
        let session = SeedSaveSession()
        session.bind(ScanPhotoStaging.ScanBinding(scope: scope, epoch: 0))
        // An eraser ran while the sheet was open.
        let current = MovableBinding(ScanPhotoStaging.ScanBinding(scope: scope, epoch: 1))

        await #expect(throws: SeedSaveSession.ScopeChanged.self) {
            try await session.save(
                Self.input("Basil"), scanID: scanID, snapshot: nil, customType: "Basil",
                writer: writer, current: { current.value }, root: root
            )
        }

        #expect(try Self.seeds(in: container).isEmpty)
        #expect(writer.uploadCalls.isEmpty)
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
        #expect(session.isInvalidated)

        // The scope coming back does not revive the session.
        current.value = ScanPhotoStaging.ScanBinding(scope: scope, epoch: 0)
        await #expect(throws: SeedSaveSession.ScopeChanged.self) {
            try await session.save(
                Self.input("Basil"), scanID: scanID, snapshot: nil, customType: nil,
                writer: writer, current: { current.value }, root: root
            )
        }
        #expect(try Self.seeds(in: container).isEmpty)
    }

    @Test("a garden change in the middle of attaching stops before the next photo")
    func scopeChangeMidAttachStops() async throws {
        let (engine, _) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let scope = Self.scope(householdID)
        try Self.stagePair(scanID, scope: scope, root: root)
        let writer = RecordingWriter(engine: engine)
        let session = SeedSaveSession()
        session.bind(ScanPhotoStaging.ScanBinding(scope: scope, epoch: 0))
        let current = MovableBinding(ScanPhotoStaging.ScanBinding(scope: scope, epoch: 0))
        writer.onUpload = { current.value = ScanPhotoStaging.ScanBinding(scope: Self.scope("hh-elsewhere"), epoch: 0) }

        await #expect(throws: SeedSaveSession.ScopeChanged.self) {
            try await session.save(
                Self.input("Basil"), scanID: scanID, snapshot: nil, customType: nil,
                writer: writer, current: { current.value }, root: root
            )
        }

        #expect(writer.uploadCalls == [ScanPhotoStaging.photoID(for: scanID, side: .front)])
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
    }

    @Test("missing staging with both stable-ID photos stored is a complete save, not a failure (V2)")
    func missingStagingWithAttachedPhotosSucceeds() async throws {
        let (engine, container) = Self.makeEngine()
        let householdID = Self.makeHousehold()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        let writer = RecordingWriter(engine: engine)
        // An earlier pass (the launch resume) attached both photos and removed the staging.
        for side in ScanPhotoStaging.Side.allCases {
            try await writer.uploadPhoto(
                seedID: "seed_x", role: side.role, jpegData: Data(), householdID: householdID,
                photoID: ScanPhotoStaging.photoID(for: scanID, side: side), capturedAt: 1
            )
        }
        let session = SeedSaveSession()

        try await session.save(
            Self.input("Basil"), householdID: householdID, scan: (scanID, Self.scope(householdID)),
            snapshot: nil, customType: "Basil", writer: writer, root: root
        )

        #expect(try Self.seeds(in: container).count == 1)
    }


    @Test("attaching with no staging throws instead of attaching nothing")
    func missingStagingThrows() async {
        let (engine, _) = Self.makeEngine()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: ScanPhotoStaging.StagingError.self) {
            try await ScanSave.attachStagedPhotos(
                scanID: UUID(), seedID: "seed_none", householdID: Self.makeHousehold(),
                writer: RecordingWriter(engine: engine), root: root
            )
        }
    }
}

extension SeedSaveSession {
    /// Binds to the scan's scope (or `householdID`) at epoch 0 and saves, as the sheet does in a garden
    /// that does not change.
    func save(
        _ input: SeedkeepClient.CreateSeedInput,
        householdID: String,
        scan: (scanID: UUID, scope: ScanPhotoStaging.Scope)?,
        snapshot: GrowingInfoSnapshot?,
        customType: String?,
        writer: any ScanSaveWriter,
        root: URL = ScanPhotoStaging.rootDirectory()
    ) async throws {
        let binding = ScanPhotoStaging.ScanBinding(
            scope: scan?.scope ?? ScanPhotoStaging.Scope(userRecordName: "_userA", householdID: householdID),
            epoch: 0
        )
        bind(binding)
        try await save(
            input, scanID: scan?.scanID, snapshot: snapshot, customType: customType,
            writer: writer, current: { binding }, root: root
        )
    }
}

/// A scan binding a test can move, as an eraser or garden switch would.
@MainActor
final class MovableBinding {
    var value: ScanPhotoStaging.ScanBinding?
    init(_ value: ScanPhotoStaging.ScanBinding?) { self.value = value }
}
