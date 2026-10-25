import Foundation
import Testing
@testable import Seedkeep

/// N2-E (G1) §1: the guard file. Atomic replacement, fail closed, Reset, account entries.
@MainActor
@Suite("Garden guard store", .serialized)
struct GardenGuardStoreTests {
    private static let accountA = GardenGuardStore.accountKey(recordName: "_userA")
    private static let accountB = GardenGuardStore.accountKey(recordName: "_userB")

    private static func binding(_ id: String) -> GardenGuardBinding {
        GardenGuardBinding(household: .init(id: id, name: "G", createdAt: 1, updatedAt: 2), participant: nil)
    }

    @Test("the account key names the iCloud user and the CloudKit environment")
    func accountKeyShape() {
        #expect(Self.accountA == "_userA|production")
    }

    @Test("state round-trips through the file, with one file and no leftovers")
    func roundTrip() throws {
        let dir = GuardTestDirectory.make()
        let store = GardenGuardStore(directory: dir)
        try store.setBinding(Self.accountA, Self.binding("hhr_1"), newGrants: ["hhr_1"])
        try store.markAttempting(Self.accountA, "hhr_1")
        try store.consumeGrant(Self.accountA, "hhr_1", generation: 1234)
        try store.acknowledge(Self.accountA, ["old"])

        let reloaded = GardenGuardStore(directory: dir)
        #expect(reloaded.status == .ready)
        #expect(reloaded.latestBinding(Self.accountA) == Self.binding("hhr_1"))
        #expect(reloaded.seen(Self.accountA, "hhr_1")?.generation == 1234)
        #expect(reloaded.grant(Self.accountA, "hhr_1") == nil)
        #expect(reloaded.isAcknowledged(Self.accountA, "old"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == [GardenGuardStore.fileName])
    }

    @Test("a failed write leaves the file and the in-memory state unchanged")
    func failedWriteKeepsOldState() throws {
        struct Boom: Error {}
        let dir = GuardTestDirectory.make()
        var fail = false
        let store = GardenGuardStore(directory: dir, write: { data, url in
            if fail { throw Boom() }
            try GardenGuardStore.atomicWrite(data, to: url)
        })
        try store.setBinding(Self.accountA, Self.binding("hhr_1"), newGrants: ["hhr_1"])
        let before = try Data(contentsOf: store.fileURL!)
        fail = true
        #expect(throws: GardenGuardError.writeFailed) {
            try store.markAttempting(Self.accountA, "hhr_1")
        }
        #expect(store.grant(Self.accountA, "hhr_1")?.state == .pending)
        #expect(try Data(contentsOf: store.fileURL!) == before)
    }

    @Test("atomic replacement never exposes a partial file")
    func atomicReplacement() throws {
        let dir = GuardTestDirectory.make()
        let url = dir.appendingPathComponent(GardenGuardStore.fileName)
        try GardenGuardStore.atomicWrite(Data("first".utf8), to: url)
        try GardenGuardStore.atomicWrite(Data("second".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [GardenGuardStore.fileName])
    }

    @Test("a corrupt file fails closed: nothing can be written, Try again re-reads")
    func corruptFailsClosed() throws {
        let dir = GuardTestDirectory.make()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(GardenGuardStore.fileName)
        try Data("{ not json".utf8).write(to: url)
        let store = GardenGuardStore(directory: dir)
        guard case .unreadable = store.status else { Issue.record("expected unreadable"); return }
        #expect(!store.isReadable)
        #expect(throws: GardenGuardError.unreadable) {
            try store.setBinding(Self.accountA, Self.binding("hhr_1"))
        }
        // Still unreadable after Try again, and the bad file is untouched.
        store.tryAgain()
        #expect(!store.isReadable)
        #expect(try Data(contentsOf: url) == Data("{ not json".utf8))
    }

    @Test("a file from a newer version fails closed")
    func newerVersionFailsClosed() throws {
        let dir = GuardTestDirectory.make()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":99,"accounts":{}}"#.utf8).write(to: dir.appendingPathComponent(GardenGuardStore.fileName))
        #expect(!GardenGuardStore(directory: dir).isReadable)
    }

    @Test("Reset starts an empty record and every grant is gone with it")
    func resetEmptiesEverything() throws {
        let dir = GuardTestDirectory.make()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent(GardenGuardStore.fileName))
        let store = GardenGuardStore(directory: dir)
        #expect(!store.isReadable)
        try store.reset()
        #expect(store.isReadable)
        #expect(store.grant(Self.accountA, "hhr_1") == nil)
        #expect(GardenGuardStore(directory: dir).isReadable)
        try store.setBinding(Self.accountA, Self.binding("hhr_2"))   // writable again
    }

    @Test("other accounts' entries survive an identity switch")
    func accountEntriesKept() throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        try store.setBinding(Self.accountA, Self.binding("hhr_a"), newGrants: ["hhr_a"])
        try store.setBinding(Self.accountB, Self.binding("hhr_b"))
        try store.setBinding(Self.accountA, Self.binding("hhr_a2"))
        #expect(store.latestBinding(Self.accountB) == Self.binding("hhr_b"))
        #expect(store.latestBinding(Self.accountA) == Self.binding("hhr_a2"))
        #expect(store.grant(Self.accountA, "hhr_a")?.state == .pending)
    }

    @Test("abandonment retires the ID and writes the fresh ID, its pending grant and the journal together")
    func abandonmentWritesRehomeState() throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        try store.setBinding(Self.accountA, Self.binding("hhr_old"), newGrants: ["hhr_old"])
        try store.markAttempting(Self.accountA, "hhr_old")
        let result = try store.abandonGrant(Self.accountA, "hhr_old", freshID: "hhr_new")
        #expect(result.replacementID == "hhr_new")
        #expect(store.isRetired(Self.accountA, "hhr_old"))
        #expect(store.grant(Self.accountA, "hhr_old") == nil)
        #expect(store.grant(Self.accountA, "hhr_new")?.state == .pending)
        let journal = store.journal(Self.accountA, "hhr_old")
        #expect(journal?.replacementID == "hhr_new")
        #expect(journal?.action == .rehome)
        #expect(store.hasOpenJournal(Self.accountA, "hhr_old"))
        #expect(store.isCreationHeld(Self.accountA))
        // Survives a reload.
        let reloaded = GardenGuardStore(directory: store.directory)
        #expect(reloaded.grant(Self.accountA, "hhr_new")?.state == .pending)
    }

    @Test("the third abandonment inside 24 hours pauses creation; Try again resumes it")
    func abandonmentIsBounded() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = GardenGuardStore(directory: nil, now: { now })
        try store.setBinding(Self.accountA, Self.binding("h0"))
        var results: [Bool] = []
        for index in 0..<3 {
            try store.restoreOrCreate(Self.accountA, "h\(index)")
            results.append(try store.abandonGrant(Self.accountA, "h\(index)", freshID: "h\(index + 1)").pausedCreation)
            now += 60
        }
        #expect(results == [false, false, true])
        #expect(store.isCreationPaused(Self.accountA))
        try store.resumeCreation(Self.accountA)
        #expect(!store.isCreationPaused(Self.accountA))
        #expect(!store.isCreationHeld(Self.accountA))
    }

    @Test("abandonments older than 24 hours do not count")
    func oldAbandonmentsExpire() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = GardenGuardStore(directory: nil, now: { now })
        for index in 0..<3 {
            try store.restoreOrCreate(Self.accountA, "h\(index)")
            let result = try store.abandonGrant(Self.accountA, "h\(index)", freshID: "h\(index + 1)")
            #expect(!result.pausedCreation)
            now += 25 * 60 * 60
        }
        #expect(!store.isCreationPaused(Self.accountA))
    }

    @Test("an in-memory store never creates a file")
    func inMemoryIsInert() throws {
        let store = GardenGuardStore(directory: nil)
        try store.setBinding(Self.accountA, Self.binding("hhr_1"))
        #expect(store.fileURL == nil)
        #expect(store.latestBinding(Self.accountA) != nil)
    }
}

private extension GardenGuardStore {
    /// Test helper: makes sure `householdID` has a grant to abandon.
    func restoreOrCreate(_ key: String, _ householdID: String) throws {
        if grant(key, householdID) == nil {
            try setBinding(key, latestBinding(key), newGrants: [householdID])
        }
    }
}
