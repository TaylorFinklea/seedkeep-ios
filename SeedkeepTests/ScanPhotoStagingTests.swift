import CoreGraphics
import Foundation
import Testing
@testable import Seedkeep

// N2 slice D: a scan's packet photos are staged durably under its scan ID, resized to the
// saved-photo budget, and removed when the scan never reached a saved seed. Every test uses its
// own temporary root, so nothing touches the app's real Application Support directory.
@Suite("Scan photo staging (N2)")
struct ScanPhotoStagingTests {

    private static let scope = ScanPhotoStaging.Scope(userRecordName: "_user", householdID: "hh-staging")

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-staging-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func solidJPEG(width: Int, height: Int) -> Data {
        let image = PlatformImageFixtures.solid(
            red: 0.2, green: 0.6, blue: 0.3, size: CGSize(width: width, height: height)
        )
        guard let data = PlatformImageCoding.jpegData(image, quality: 0.95) else {
            preconditionFailure("could not encode the \(width)x\(height) fixture")
        }
        return data
    }

    @Test("a captured photo is resized to the saved-photo budget")
    func resizedToPhotoBudget() throws {
        let capture = Self.solidJPEG(width: 4_000, height: 3_000)

        let resized = try ScanPhotoStaging.resizedPhoto(capture)

        let size = try #require(PhotoResizer.pixelDimensions(resized))
        #expect(max(size.width, size.height) <= PhotoResizer.photo.maxDimension)
        #expect(resized.count <= PhotoResizer.photo.targetBytes)
    }

    @Test("an undecodable capture throws and leaves nothing staged")
    func undecodableCaptureIsNotStaged() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()

        #expect(throws: PhotoResizer.Failure.self) {
            _ = try ScanPhotoStaging.resizedPhoto(Data("not a photo".utf8))
        }

        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
        #expect(ScanPhotoStaging.photoData(.front, scanID: scanID, root: root) == nil)
    }

    @Test("each side keeps its bytes and capture time, and the front is captured first")
    func sidesKeepBytesAndCaptureTimes() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()

        try ScanPhotoStaging.write(
            Data("front".utf8), side: .front, scanID: scanID, scope: Self.scope,
            capturedAt: Date(timeIntervalSince1970: 1_000), root: root
        )
        try ScanPhotoStaging.write(
            Data("back".utf8), side: .back, scanID: scanID, scope: Self.scope,
            capturedAt: Date(timeIntervalSince1970: 1_005), root: root
        )

        let manifest = try #require(ScanPhotoStaging.manifest(for: scanID, root: root))
        #expect(manifest.seedID == nil)
        #expect(manifest.capturedAt(.front) == 1_000_000)
        #expect(manifest.capturedAt(.back) == 1_005_000)
        #expect(ScanPhotoStaging.photoData(.front, scanID: scanID, root: root) == Data("front".utf8))
        #expect(ScanPhotoStaging.photoData(.back, scanID: scanID, root: root) == Data("back".utf8))
    }

    @Test("linking the seed records it with the scope and keeps both photos")
    func recordingSeedKeepsPhotos() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try ScanPhotoStaging.write(Data("front".utf8), side: .front, scanID: scanID, scope: Self.scope, root: root)
        try ScanPhotoStaging.write(Data("back".utf8), side: .back, scanID: scanID, scope: Self.scope, root: root)

        try ScanPhotoStaging.link(seedID: "seed_linked", scope: Self.scope, details: .init(), scanID: scanID, root: root)

        #expect(ScanPhotoStaging.manifest(for: scanID, root: root)?.seedID == "seed_linked")
        #expect(ScanPhotoStaging.manifest(for: scanID, root: root)?.scope == Self.scope)
        #expect(ScanPhotoStaging.photoData(.front, scanID: scanID, root: root) != nil)
        #expect(ScanPhotoStaging.photoData(.back, scanID: scanID, root: root) != nil)
    }

    @Test("stable photo IDs are derived from the scan ID and the side")
    func stablePhotoIDs() {
        let scanID = UUID()

        #expect(ScanPhotoStaging.photoID(for: scanID, side: .front) == "scan-\(scanID.uuidString)-front")
        #expect(ScanPhotoStaging.photoID(for: scanID, side: .back) == "scan-\(scanID.uuidString)-back")
        #expect(ScanPhotoStaging.photoID(for: scanID, side: .front) == ScanPhotoStaging.photoID(for: scanID, side: .front))
    }

    @Test("discard removes a scan's staging and can run again safely")
    func discardRemovesStaging() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try ScanPhotoStaging.write(Data("front".utf8), side: .front, scanID: scanID, scope: Self.scope, root: root)

        ScanPhotoStaging.discard(scanID: scanID, root: root)
        ScanPhotoStaging.discard(scanID: scanID, root: root)

        #expect(ScanPhotoStaging.manifest(for: scanID, root: root) == nil)
        #expect(ScanPhotoStaging.scanDirectories(root: root).isEmpty)
    }

    @Test("stale unsaved scans are removed after 24 hours; linked and recent scans stay")
    func staleUnsavedScansAreRemoved() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = now.addingTimeInterval(-ScanPhotoStaging.retention - 60)
        let stale = UUID()
        let linked = UUID()
        let recent = UUID()
        try ScanPhotoStaging.write(Data("a".utf8), side: .front, scanID: stale, scope: Self.scope, capturedAt: old, root: root)
        try ScanPhotoStaging.write(Data("b".utf8), side: .front, scanID: linked, scope: Self.scope, capturedAt: old, root: root)
        try ScanPhotoStaging.link(seedID: "seed_linked", scope: Self.scope, details: .init(), scanID: linked, root: root)
        try ScanPhotoStaging.write(
            Data("c".utf8), side: .front, scanID: recent, scope: Self.scope,
            capturedAt: now.addingTimeInterval(-60), root: root
        )

        ScanPhotoStaging.removeStaleUnsaved(now: now, root: root)

        #expect(ScanPhotoStaging.manifest(for: stale, root: root) == nil)
        #expect(ScanPhotoStaging.manifest(for: linked, root: root) != nil)
        #expect(ScanPhotoStaging.manifest(for: recent, root: root) != nil)
    }

    @Test("a manifest records the account and garden it was captured under")
    func manifestRecordsScope() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()

        try ScanPhotoStaging.write(Data("front".utf8), side: .front, scanID: scanID, scope: Self.scope, root: root)

        let manifest = try #require(ScanPhotoStaging.manifest(for: scanID, root: root))
        #expect(manifest.scope?.userRecordName == "_user")
        #expect(manifest.scope?.householdID == "hh-staging")
    }

    @Test("relinking the same seed keeps applied details and attached sides")
    func relinkKeepsProgress() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try ScanPhotoStaging.write(Data("front".utf8), side: .front, scanID: scanID, scope: Self.scope, root: root)
        let details = ScanPhotoStaging.PendingDetails(customType: "Tomato")
        try ScanPhotoStaging.link(seedID: "seed_a", scope: Self.scope, details: details, scanID: scanID, root: root)
        try ScanPhotoStaging.markApplied(.customType, scanID: scanID, root: root)
        try ScanPhotoStaging.markAttached(.front, scanID: scanID, root: root)

        try ScanPhotoStaging.link(seedID: "seed_a", scope: Self.scope, details: details, scanID: scanID, root: root)

        let manifest = try #require(ScanPhotoStaging.manifest(for: scanID, root: root))
        #expect(manifest.details?.customTypeApplied == true)
        #expect(manifest.details?.isComplete == true)
        #expect(manifest.isAttached(.front))
        #expect(!manifest.isAttached(.back))
    }

    @Test("purgeAll removes every scan and is safe when nothing is staged")
    func purgeAllRemovesEverything() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ScanPhotoStaging.write(Data("a".utf8), side: .front, scanID: UUID(), scope: Self.scope, root: root)
        try ScanPhotoStaging.write(Data("b".utf8), side: .front, scanID: UUID(), scope: Self.scope, root: root)

        try ScanPhotoStaging.purgeAll(root: root)
        try ScanPhotoStaging.purgeAll(root: root)

        #expect(ScanPhotoStaging.scanDirectories(root: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("linking never overwrites the captured scope; a link from another garden throws (V1)")
    func linkKeepsCapturedScope() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanID = UUID()
        try ScanPhotoStaging.write(Data("front".utf8), side: .front, scanID: scanID, scope: Self.scope, root: root)
        let otherGarden = ScanPhotoStaging.Scope(userRecordName: "_user", householdID: "hh-other")
        let rebound = ScanPhotoStaging.Scope(userRecordName: "_icloud_user", householdID: Self.scope.householdID)

        #expect(throws: ScanPhotoStaging.StagingError.self) {
            try ScanPhotoStaging.link(seedID: "seed_a", scope: otherGarden, details: .init(), scanID: scanID, root: root)
        }
        try ScanPhotoStaging.link(seedID: "seed_a", scope: rebound, details: .init(), scanID: scanID, root: root)

        let manifest = try #require(ScanPhotoStaging.manifest(for: scanID, root: root))
        #expect(manifest.scope == Self.scope, "the captured scope is kept")
        #expect(manifest.seedID == "seed_a")
    }
}
