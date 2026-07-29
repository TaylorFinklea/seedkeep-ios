import Testing
import Foundation
import CryptoKit
@testable import Seedkeep

// Photos-on-CloudKit Stage B — the three-lifetime byte store (see
// seedkeep/.docs/ai/phases/2026-07-28-photos-on-cloudkit-spec.md D2/D6). Every test uses a
// fresh UUID householdID so runs never collide with each other or with a real device's data —
// same convention as `HouseholdCloudCoordinatorTests`. Each test cleans up after itself via
// `removeAll()` so a failure doesn't leave orphaned directories under Application Support.
struct PhotoByteStoreTests {

    // MARK: - Three lifetimes

    @Test("PendingUploads survives purging PhotoCache; PhotoCache does not survive its own purge")
    func lifetimesAreIndependent() throws {
        let hid = "hh-\(UUID().uuidString)"
        let pending = PhotoByteStore(lifetime: .pendingUploads, householdID: hid)
        let cache = PhotoByteStore(lifetime: .cache, householdID: hid)
        let pendingRef = try pending.write(Data("pending-bytes".utf8), for: "seedPhoto:p1")
        let cacheRef = try cache.write(Data("cache-bytes".utf8), for: "seedPhoto:p2")

        try cache.removeAll()

        #expect(FileManager.default.fileExists(atPath: pendingRef.url.path),
                "purging PhotoCache must never touch PendingUploads")
        #expect(!FileManager.default.fileExists(atPath: cacheRef.url.path))
        try pending.removeAll()
    }

    @Test("purgeHousehold clears all three lifetimes")
    func purgeHouseholdClearsAllThreeLifetimes() throws {
        let hid = "hh-\(UUID().uuidString)"
        var refs: [PhotoByteStore.Ref] = []
        for lifetime in PhotoByteStore.Lifetime.allCases {
            let store = PhotoByteStore(lifetime: lifetime, householdID: hid)
            refs.append(try store.write(Data("bytes-\(lifetime.rawValue)".utf8), for: "seedPhoto:p1"))
        }

        try PhotoByteStore.purgeHousehold(hid)

        for ref in refs {
            #expect(!FileManager.default.fileExists(atPath: ref.url.path))
        }
    }

    @Test("purgeRecord clears PendingUploads + PhotoCache but leaves TransferWorkspace untouched")
    func purgeRecordScopedToMutableStores() throws {
        let hid = "hh-\(UUID().uuidString)"
        let pending = PhotoByteStore(lifetime: .pendingUploads, householdID: hid)
        let cache = PhotoByteStore(lifetime: .cache, householdID: hid)
        let transfer = PhotoByteStore(lifetime: .transferWorkspace, householdID: hid)
        let pendingRef = try pending.write(Data("p".utf8), for: "journalEntryPhoto:j1")
        let cacheRef = try cache.write(Data("c".utf8), for: "journalEntryPhoto:j1")
        let transferRef = try transfer.write(Data("t".utf8), for: "journalEntryPhoto:j1")

        PhotoByteStore.purgeRecord("journalEntryPhoto:j1", householdID: hid)

        #expect(!FileManager.default.fileExists(atPath: pendingRef.url.path))
        #expect(!FileManager.default.fileExists(atPath: cacheRef.url.path))
        #expect(FileManager.default.fileExists(atPath: transferRef.url.path),
                "TransferWorkspace has no per-record delete concept — only wholesale purge")
        try transfer.removeAll()
    }

    // MARK: - Hash stability + the D2 "hashed after close" invariant

    @Test("identical bytes hash identically regardless of recordName; different bytes hash differently")
    func hashStability() throws {
        let hid = "hh-\(UUID().uuidString)"
        let store = PhotoByteStore(lifetime: .cache, householdID: hid)
        let bytes = Data("hello-photo-bytes".utf8)
        let ref1 = try store.write(bytes, for: "seedPhoto:a")
        let ref2 = try store.write(bytes, for: "seedPhoto:b")
        #expect(ref1.sha256 == ref2.sha256)

        let ref3 = try store.write(Data("different-bytes".utf8), for: "seedPhoto:c")
        #expect(ref3.sha256 != ref1.sha256)
        try store.removeAll()
    }

    @Test("the recorded hash matches an independent hash of the bytes actually readable on disk")
    func hashReflectsOnDiskBytes() throws {
        let hid = "hh-\(UUID().uuidString)"
        let store = PhotoByteStore(lifetime: .pendingUploads, householdID: hid)
        let bytes = Data((0..<5000).map { UInt8($0 % 256) })
        let ref = try store.write(bytes, for: "seedPhoto:p1")

        let onDisk = try Data(contentsOf: ref.url)
        let independentHash = SHA256.hash(data: onDisk).map { String(format: "%02x", $0) }.joined()
        #expect(ref.sha256 == independentHash)
        #expect(onDisk == bytes, "bytes on disk must be exactly what was written")
        try store.removeAll()
    }

    @Test("writing new bytes for an existing recordName supersedes the old file at a NEW path, never mutates it")
    func writeSupersedesPriorRefAtANewPath() throws {
        let hid = "hh-\(UUID().uuidString)"
        let store = PhotoByteStore(lifetime: .cache, householdID: hid)
        let first = try store.write(Data("v1".utf8), for: "seedPhoto:p1")
        let second = try store.write(Data("v2".utf8), for: "seedPhoto:p1")

        #expect(first.url != second.url, "content-addressed path must change when bytes change")
        #expect(!FileManager.default.fileExists(atPath: first.url.path),
                "the superseded file must be removed once the new one lands")
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        #expect(store.data(for: "seedPhoto:p1") == Data("v2".utf8))
        try store.removeAll()
    }

    @Test("re-writing identical bytes for the same recordName is idempotent (same content-addressed path)")
    func rewritingIdenticalBytesIsIdempotent() throws {
        let hid = "hh-\(UUID().uuidString)"
        let store = PhotoByteStore(lifetime: .cache, householdID: hid)
        let bytes = Data("same-bytes".utf8)
        let first = try store.write(bytes, for: "seedPhoto:p1")
        let second = try store.write(bytes, for: "seedPhoto:p1")

        #expect(first.url == second.url)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        try store.removeAll()
    }

    // MARK: - env + household namespacing

    @Test("directory namespaces by CloudKit environment tag, lifetime, and household id")
    func namespacedByEnvironmentAndHousehold() {
        let hid = "hh-\(UUID().uuidString)"
        let dir = PhotoByteStore.rootDirectory(lifetime: .cache, householdID: hid)
        let components = dir.pathComponents
        #expect(components.contains(HouseholdCloudCoordinator.cloudKitEnvironmentTag))
        #expect(components.contains(hid))
        #expect(components.contains("PhotoCache"))
        #expect(dir.path.contains("HouseholdSync"), "must live under the same root as HouseholdCloudCoordinator's durable state")
    }

    @Test("two households never collide, even with the same recordName")
    func householdsDoNotCollide() throws {
        let h1 = "hh-\(UUID().uuidString)"
        let h2 = "hh-\(UUID().uuidString)"
        let s1 = PhotoByteStore(lifetime: .cache, householdID: h1)
        let s2 = PhotoByteStore(lifetime: .cache, householdID: h2)
        try s1.write(Data("h1-bytes".utf8), for: "seedPhoto:shared-id")
        try s2.write(Data("h2-bytes".utf8), for: "seedPhoto:shared-id")

        #expect(s1.data(for: "seedPhoto:shared-id") == Data("h1-bytes".utf8))
        #expect(s2.data(for: "seedPhoto:shared-id") == Data("h2-bytes".utf8))
        #expect(s1.directory != s2.directory)

        try s1.removeAll()
        try s2.removeAll()
    }

    // MARK: - Basic read/remove semantics

    @Test("a missing record reads as absent, not an error")
    func missingRecordReadsAsAbsent() {
        let hid = "hh-\(UUID().uuidString)"
        let store = PhotoByteStore(lifetime: .cache, householdID: hid)
        #expect(store.ref(for: "seedPhoto:nope") == nil)
        #expect(store.data(for: "seedPhoto:nope") == nil)
        #expect(!store.contains("seedPhoto:nope"))
    }

    @Test("remove on an absent record is a harmless no-op")
    func removeAbsentRecordIsNoOp() throws {
        let hid = "hh-\(UUID().uuidString)"
        let store = PhotoByteStore(lifetime: .pendingUploads, householdID: hid)
        store.remove("seedPhoto:never-existed")   // must not throw / crash
        try store.removeAll()
    }
}
