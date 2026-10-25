import CloudKit
import Foundation
import Observation
import SeedkeepCloudKit

// N2-E (G1): the garden guard store. One JSON file that records, per iCloud account, which garden
// is bound, which gardens this device is allowed to create (grants), which it has seen exist, and
// which it has retired or acknowledged. Contract: `.docs/ai/plans/2026-10-22-n2e-deleted-garden-guard.md`.

/// The latest binding for an account: the own household the identity cache holds, plus the shared
/// garden the participant marker names, when there is one. The defaults are rebuilt from it.
struct GardenGuardBinding: Codable, Equatable, Sendable {
    struct Household: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var createdAt: Int64
        var updatedAt: Int64
    }
    struct Participant: Codable, Equatable, Sendable {
        var zoneName: String
        var ownerName: String
    }

    var household: Household
    var participant: Participant?

    /// The garden whose data this device shows: the shared one for a participant.
    var gardenHouseholdID: String {
        participant.map { SeedkeepRecordNames.householdID(fromZoneName: $0.zoneName) } ?? household.id
    }
    var zoneName: String { participant?.zoneName ?? SeedkeepRecordNames.zoneName(householdID: household.id) }
    var ownerName: String { participant?.ownerName ?? CKCurrentUserDefaultName }
    var scope: GardenDatabaseScope { participant == nil ? .owned : .shared }
}

/// Permission for this device to create one brand-new garden zone. `pending` until a creation
/// request is about to be sent, `attempting` (durable) from then until the outcome is recorded.
struct GardenCreationGrant: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, attempting }
    var state: State
    var createdAt: Date
}

/// A garden this device has seen exist. `generation` is the server `creationDate` of its
/// `Household` root in milliseconds; nil for a garden that predates N2-E until a start check
/// records it (trust on first use, G2).
struct GardenSeenRecord: Codable, Equatable, Sendable {
    var generation: Int64?
}

/// A garden that is gone, or being re-homed. G1 writes only `.abandonedGrant` and
/// `.absentZone` entries, journaled for the silent re-home (G3 resumes them). G2 adds the gone
/// signals and G3 the keep and discard actions.
struct GardenGoneRecord: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// A creation grant was dispatched and not confirmed, or lost while `attempting`.
        case abandonedGrant
        /// The device's garden has no zone in iCloud, and the device keeps its rows.
        case absentZone
    }
    enum Action: String, Codable, Sendable { case rehome }
    enum Phase: String, Codable, Sendable {
        case journaled, done
        /// A newer binding replaced this journal's target in the same guard write. Never replayed.
        case superseded
    }

    var reason: Reason
    var action: Action
    var phase: Phase
    /// The fresh household ID the rows move to, with its `pending` grant written in the same guard write.
    var replacementID: String
    var createdAt: Date
}

struct GardenGuardAccount: Codable, Equatable, Sendable {
    var binding: GardenGuardBinding?
    var grants: [String: GardenCreationGrant] = [:]
    var seen: [String: GardenSeenRecord] = [:]
    var gone: [String: GardenGoneRecord] = [:]
    var retired: [String] = []
    var acknowledged: [String] = []
    /// False until the first N2-E resolution of this account has acknowledged the gardens that
    /// predate N2-E. After that, any unseen garden is offered once.
    var discoveryInitialized = false
    /// True once any binding has been written for this account, including a cleared one. An account
    /// that was never seeded (an install from before N2-E) is seeded from its defaults; a cleared
    /// binding clears the defaults and is never re-seeded.
    var bindingWritten = false
    /// Abandonment times inside the last 24 hours.
    var abandonments: [Date] = []
    var creationPaused = false
}

struct GardenGuardFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = GardenGuardFile.currentVersion
    var accounts: [String: GardenGuardAccount] = [:]
}

enum GardenGuardError: Error, Equatable, LocalizedError {
    case unreadable
    case writeFailed
    case missingGrant

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Seedkeep can't read its iCloud safety record."
        case .writeFailed: return "Seedkeep couldn't save its iCloud safety record."
        case .missingGrant: return "This garden has no permission to be created."
        }
    }
}

/// How an abandoned creation grant ended (`GardenGuardStore.abandonGrant`).
struct GardenAbandonment: Equatable, Sendable {
    let abandonedID: String
    let replacementID: String
    /// True when this abandonment was the third inside 24 hours: creation is paused.
    let pausedCreation: Bool
}

/// The seam where the silent re-home (G3) will run. G1 only records what it needs in the guard
/// (a `gone` journal entry, the fresh ID and its `pending` grant) and calls this. G3 fills it in.
struct GardenRehomeRequest: Equatable, Sendable {
    let accountKey: String
    let fromHouseholdID: String
    let toHouseholdID: String
    let reason: GardenGoneRecord.Reason
}

@MainActor
protocol GardenRehoming: AnyObject {
    func rehomeRequested(_ request: GardenRehomeRequest)
}

/// G1's stand-in: the request is already durable in the guard's `gone` journal, which the G3 runner
/// will resume at launch. Until then the garden keeps working on the device and sends nothing.
@MainActor
final class DeferredGardenRehomer: GardenRehoming {
    func rehomeRequested(_ request: GardenRehomeRequest) {}
}

@MainActor
@Observable
final class GardenGuardStore {
    enum Status: Equatable {
        case ready
        /// The file exists and could not be read or decoded. Nothing is sent to iCloud.
        case unreadable(String)
    }

    static let fileName = "guard.json"
    static let maxAbandonments = 3
    static let abandonmentWindow: TimeInterval = 24 * 60 * 60

    private(set) var status: Status = .ready
    private(set) var file = GardenGuardFile()
    /// Bumped by every mutation, so views and the Settings notice observe the guard.
    private(set) var revision = 0

    /// nil: in memory only (unit tests, sample-garden mode). The real file is never touched.
    @ObservationIgnored let directory: URL?
    @ObservationIgnored private let write: (Data, URL) throws -> Void
    @ObservationIgnored private let now: () -> Date
    /// Accounts whose creation waits for the next launch or "Sync now" after an abandonment.
    @ObservationIgnored private var heldAccounts = Set<String>()

    init(
        directory: URL?,
        now: @escaping () -> Date = Date.init,
        write: @escaping (Data, URL) throws -> Void = GardenGuardStore.atomicWrite
    ) {
        self.directory = directory
        self.now = now
        self.write = write
        load()
    }

    /// The app's store: `Application Support/GardenGuard`. In-memory under XCTest, so a hosted test
    /// run never reads or writes the real app's file.
    static func live() -> GardenGuardStore {
        guard FeatureFlags.canRunLiveAppStartup else { return GardenGuardStore(directory: nil) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return GardenGuardStore(directory: support.appendingPathComponent("GardenGuard", isDirectory: true))
    }

    var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }
    var isReadable: Bool { status == .ready }

    static func accountKey(recordName: String) -> String {
        "\(recordName)|\(HouseholdCloudCoordinator.cloudKitEnvironmentTag)"
    }

    // MARK: - Loading

    /// Reads the file. Absent: an empty record. Present but unreadable, undecodable or from a newer
    /// version: `unreadable`, and nothing is sent to iCloud until Try again succeeds or Reset.
    func load() {
        guard let url = fileURL else { status = .ready; return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            file = GardenGuardFile()
            status = .ready
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let decoded = try decoder.decode(GardenGuardFile.self, from: data)
            guard decoded.version <= GardenGuardFile.currentVersion else {
                status = .unreadable("newer version \(decoded.version)")
                return
            }
            file = decoded
            status = .ready
        } catch {
            status = .unreadable(String(describing: error))
        }
        revision += 1
    }

    /// Try again on the blocking screen.
    func tryAgain() { load() }

    /// Reset (confirmed on the blocking screen): an empty record. Every grant is gone with it, so a
    /// bound creation candidate has no zone and is never created; the start checks (G2) treat it as gone.
    func reset() throws {
        let empty = GardenGuardFile()
        try persist(empty)
        file = empty
        status = .ready
        heldAccounts.removeAll()
        revision += 1
    }

    // MARK: - Reads

    func account(_ key: String) -> GardenGuardAccount { file.accounts[key] ?? GardenGuardAccount() }
    func latestBinding(_ key: String) -> GardenGuardBinding? { account(key).binding }
    func grant(_ key: String, _ householdID: String) -> GardenCreationGrant? { account(key).grants[householdID] }
    func isSeen(_ key: String, _ householdID: String) -> Bool { account(key).seen[householdID] != nil }
    func seen(_ key: String, _ householdID: String) -> GardenSeenRecord? { account(key).seen[householdID] }
    func isRetired(_ key: String, _ householdID: String) -> Bool { account(key).retired.contains(householdID) }
    func isAcknowledged(_ key: String, _ householdID: String) -> Bool { account(key).acknowledged.contains(householdID) }
    func journal(_ key: String, _ householdID: String) -> GardenGoneRecord? { account(key).gone[householdID] }
    /// A garden with an open `gone` journal sends nothing. Done and superseded journals are closed.
    func hasOpenJournal(_ key: String, _ householdID: String) -> Bool {
        account(key).gone[householdID].map { $0.phase == .journaled } ?? false
    }
    func isBindingWritten(_ key: String) -> Bool { account(key).bindingWritten }
    func isCreationPaused(_ key: String) -> Bool { account(key).creationPaused }
    func isCreationHeld(_ key: String) -> Bool { heldAccounts.contains(key) }

    // MARK: - Mutations (each one atomic guard write)

    /// Records the latest binding. `newGrants` are `pending` grants for gardens this device is
    /// about to create, written in the same guard write. `journals` are re-home journal entries
    /// written in the same write. `acknowledging` marks gardens the user has been shown.
    func setBinding(
        _ key: String, _ binding: GardenGuardBinding?,
        newGrants: [String] = [], journals: [String: GardenGoneRecord] = [:],
        acknowledging: [String] = [], initializeDiscovery: Bool = false
    ) throws {
        try mutate(key) { account in
            // A newer binding supersedes any open journal's target in the same write, except a
            // journal whose replacement is the garden now being bound (its completion) and the
            // journals written by this very call. An unchanged binding supersedes nothing.
            if account.binding != binding {
                for (id, record) in account.gone where record.phase == .journaled
                    && record.replacementID != binding?.household.id {
                    var closed = record
                    closed.phase = .superseded
                    account.gone[id] = closed
                }
            }
            account.binding = binding
            account.bindingWritten = true
            if initializeDiscovery { account.discoveryInitialized = true }
            for id in newGrants where account.grants[id] == nil && !account.retired.contains(id) {
                account.grants[id] = GardenCreationGrant(state: .pending, createdAt: self.now())
            }
            for (id, record) in journals { account.gone[id] = record }
            for id in acknowledging where !account.acknowledged.contains(id) { account.acknowledged.append(id) }
        }
    }

    /// `pending` → `attempting`, durable before any zone request.
    func markAttempting(_ key: String, _ householdID: String) throws {
        try mutate(key) { account in
            guard var grant = account.grants[householdID], grant.state == .pending else {
                throw GardenGuardError.missingGrant
            }
            grant.state = .attempting
            account.grants[householdID] = grant
        }
    }

    /// An undispatched request: the grant goes back to `pending`.
    func restorePending(_ key: String, _ householdID: String) throws {
        try mutate(key) { account in
            guard var grant = account.grants[householdID] else { throw GardenGuardError.missingGrant }
            grant.state = .pending
            account.grants[householdID] = grant
        }
    }

    /// A confirmed creation: the grant is consumed and the garden is `seen` with the server-returned
    /// root's `creationDate` as its generation, in one guard write.
    func consumeGrant(_ key: String, _ householdID: String, generation: Int64) throws {
        try mutate(key) { account in
            guard account.grants[householdID] != nil else { throw GardenGuardError.missingGrant }
            account.grants[householdID] = nil
            account.seen[householdID] = GardenSeenRecord(generation: generation)
        }
    }

    /// Abandons a dispatched, unconfirmed (or lost `attempting`) creation: the ID is retired, a
    /// fresh ID with a `pending` grant and the re-home journal are written in the same guard write,
    /// and the abandonment is counted. The third inside 24 hours pauses creation.
    func abandonGrant(_ key: String, _ householdID: String, freshID: String) throws -> GardenAbandonment {
        var paused = false
        try mutate(key) { account in
            let at = self.now()
            account.grants[householdID] = nil
            if !account.retired.contains(householdID) { account.retired.append(householdID) }
            account.grants[freshID] = GardenCreationGrant(state: .pending, createdAt: at)
            account.gone[householdID] = GardenGoneRecord(reason: .abandonedGrant, action: .rehome, phase: .journaled,
                                                         replacementID: freshID, createdAt: at)
            account.abandonments = account.abandonments.filter { at.timeIntervalSince($0) < Self.abandonmentWindow } + [at]
            if account.abandonments.count >= Self.maxAbandonments { account.creationPaused = true }
            paused = account.creationPaused
        }
        heldAccounts.insert(key)
        return GardenAbandonment(abandonedID: householdID, replacementID: freshID, pausedCreation: paused)
    }

    /// Records a garden known to exist. A recorded generation is never overwritten; a missing one
    /// is filled in (trust on first use).
    func recordSeen(_ key: String, _ householdID: String, generation: Int64?) throws {
        if let existing = seen(key, householdID), existing.generation != nil || generation == nil { return }
        try mutate(key) { account in
            account.seen[householdID] = GardenSeenRecord(generation: generation)
        }
    }

    func acknowledge(_ key: String, _ householdIDs: [String]) throws {
        let fresh = householdIDs.filter { !isAcknowledged(key, $0) }
        guard !fresh.isEmpty else { return }
        try mutate(key) { account in account.acknowledged.append(contentsOf: fresh) }
    }

    func markDiscoveryInitialized(_ key: String, acknowledging ids: [String]) throws {
        try mutate(key) { account in
            account.discoveryInitialized = true
            for id in ids where !account.acknowledged.contains(id) { account.acknowledged.append(id) }
        }
    }

    /// Settings "Try again" after the pause: clears the abandonment count and lets creation run.
    func resumeCreation(_ key: String) throws {
        try mutate(key) { account in
            account.creationPaused = false
            account.abandonments = []
        }
        heldAccounts.remove(key)
    }

    /// "Sync now" ends the wait that follows an abandonment (a pause still needs Try again).
    func releaseCreationHolds() {
        heldAccounts.removeAll()
        revision += 1
    }

    // MARK: - Persistence

    private func mutate(_ key: String, _ change: (inout GardenGuardAccount) throws -> Void) throws {
        guard isReadable else { throw GardenGuardError.unreadable }
        var next = file
        var account = next.accounts[key] ?? GardenGuardAccount()
        try change(&account)
        next.accounts[key] = account
        try persist(next)
        file = next
        revision += 1
    }

    private func persist(_ file: GardenGuardFile) throws {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try write(try encoder.encode(file), url)
        } catch {
            throw GardenGuardError.writeFailed
        }
    }

    /// Temp file in the same directory, `fsync`, then an atomic replace. There is no fallback copy:
    /// an older copy could roll an `attempting` grant back to `pending`, which is a resurrection path.
    nonisolated static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".guard-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
