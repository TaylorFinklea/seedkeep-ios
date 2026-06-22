#if canImport(CloudKit)
import CloudKit
import Foundation

// R1 Phase-0 spike — LIVE CloudKit checks (require a signed build + an iCloud account; G6).
// Each returns a human-readable result string. Driven by the app's launch-arg spike harness.
// Adapted from SimmerSmith's CloudKitDebugView checks (reference), using SeedkeepCloudKit.
//
// Gate 1  (one sim):  roundtrip — provision a zone, write a Seed via the codec, read it back.
// Gate 1b (one sim):  merge     — two engines on one zone, concurrent packetCount decrements,
//                                 assert min() converges live (the thing a blanket LWW would lose).
// Gate 2  (two sims): share     — owner publishes a CKShare URL; a participant on a DIFFERENT
//                                 iCloud account fetches + accepts it + reads the owner's data.

public struct SpikeFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw SpikeFailure(message()) }
}

private func freshSeed(id: String, packetCount: Int, updatedAt: Int64) -> CloudKitRecordValue {
    SeedkeepRecordValues.seed(
        id: id, customName: "Brandywine", customVariety: nil, customCompany: nil, customType: nil,
        notes: nil, stateRaw: "active", sourceRaw: "store", packetCount: packetCount, yearPacked: nil,
        tagIDsJSON: "[]", growingInfoJSON: nil, catalogID: nil, locationID: nil,
        createdAt: 1, updatedAt: updatedAt, deletedAt: nil)
}

// MARK: - Gate 1: single-engine round-trip

public func runSeedkeepRoundtripCheck(containerID: String = "iCloud.app.seedkeep") async -> String {
    do {
        let provisioner = SeedkeepZoneProvisioner(containerIdentifier: containerID)
        let zone = try await provisioner.ensureZone(householdID: "spike-roundtrip")
        let db = CKContainer(identifier: containerID).privateCloudDatabase

        let sfx = String(UUID().uuidString.prefix(8))
        let value = freshSeed(id: "roundtrip-\(sfx)", packetCount: 10, updatedAt: 1)
        let record = SeedkeepRecordCodec.encode(value, zoneID: zone.zoneID)
        _ = try await db.modifyRecords(saving: [record], deleting: [])

        let fetched = try await db.record(for: record.recordID)
        let decoded = SeedkeepRecordCodec.decode(fetched, as: .seed)
        try expect(decoded.scalars["packetCount"] == .int(10), "packetCount mismatch: \(String(describing: decoded.scalars["packetCount"]))")
        try expect(decoded.scalars["customName"] == .string("Brandywine"), "customName mismatch")

        // cleanup
        _ = try? await db.modifyRecords(saving: [], deleting: [record.recordID])
        return "✅ Gate 1 roundtrip: zone provisioned + Seed written to CloudKit + read back (packetCount=10, codec round-trips)"
    } catch {
        return "❌ Gate 1 roundtrip failed: \(error)"
    }
}

// MARK: - Gate 1b: two-engine live merge (the min-merge a blanket LWW would lose)

public func runSeedkeepMergeCheck(containerID: String = "iCloud.app.seedkeep") async -> String {
    let zoneID = CKRecordZone.ID(zoneName: SeedkeepRecordNames.zoneName(householdID: "spike-merge"),
                                 ownerName: CKCurrentUserDefaultName)
    let db = CKContainer(identifier: containerID).privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let stateA = tmp.appendingPathComponent("sk-mergeA-\(UUID().uuidString).json")
    let stateB = tmp.appendingPathComponent("sk-mergeB-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: stateA); try? FileManager.default.removeItem(at: stateB) }
    let sfx = String(UUID().uuidString.prefix(8))
    let recordName = SeedkeepRecordNames.seed("merge-\(sfx)")

    do {
        _ = try await SeedkeepZoneProvisioner(containerIdentifier: containerID).ensureZone(householdID: "spike-merge")
        let merger = SeedkeepRecordMerger()
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeA, stateURL: stateA)
        engineA.merger = merger
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeB, stateURL: stateB)
        engineB.merger = merger

        func id() -> CKRecord.ID { CKRecord.ID(recordName: recordName, zoneID: zoneID) }
        func countInB() async throws -> Int? {
            for _ in 0...4 {
                try await engineB.fetchChanges()
                if let r = storeB.record(for: id()) { return r["packetCount"] as? Int }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return storeB.record(for: id())?["packetCount"] as? Int
        }
        func decrement(_ engine: HouseholdSyncEngine, _ store: HouseholdLocalStore, to count: Int, clock: Int) {
            guard let rec = store.record(for: id()) else { return }
            rec["packetCount"] = count as CKRecordValue   // mutate the server-tagged record in place
            rec["updatedAt"]   = clock as CKRecordValue
            engine.save(rec)
        }

        // A writes Seed(packetCount=10); B fetches the base.
        engineA.save(SeedkeepRecordCodec.encode(freshSeed(id: "merge-\(sfx)", packetCount: 10, updatedAt: 1), zoneID: zoneID))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await countInB()

        // Concurrent decrements: A 10→8 (clock 5), then B 10→9 from its STALE base (clock 6) → conflict → merge.
        decrement(engineA, storeA, to: 8, clock: 5)
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        decrement(engineB, storeB, to: 9, clock: 6)
        try await engineB.sendUntilDrained()

        guard let convB = try await countInB() else { throw SpikeFailure("merge seed missing in B") }
        try await engineA.fetchChanges()
        let convA = storeA.record(for: id())?["packetCount"] as? Int

        try expect(convB == 8, "B did not converge to min: \(convB) (a blanket LWW would give 9)")
        try expect(convA == 8, "A did not converge to min: \(String(describing: convA))")

        engineA.delete(id()); try? await engineA.sendUntilDrained()
        return "✅ Gate 1b live merge: concurrent decrements 10→8 (A) ∥ 10→9 (B) → BOTH converge packetCount=8 (min, not the LWW 9)"
    } catch {
        return "❌ Gate 1b merge failed: \(error)"
    }
}

// MARK: - Gate 2: cross-account CKShare

public func runSeedkeepShareOwnerCheck(containerID: String = "iCloud.app.seedkeep") async -> String {
    do {
        let flow = SeedkeepShareFlow(containerIdentifier: containerID)
        let result = try await flow.createAndPublishShare(householdID: "spike-share", name: "Spike Household")
        return """
        ✅ Gate 2 OWNER: zone + CKShare created (publicPermission .readWrite), URL published to the public DB
        owner userRecordID = \(result.ownerStamp)
        url = \(result.url.absoluteString)
        → now run PARTICIPANT on the OTHER sim (the second iCloud account)
        """
    } catch {
        return "❌ Gate 2 OWNER failed: \(error)"
    }
}

public func runSeedkeepShareParticipantCheck(containerID: String = "iCloud.app.seedkeep") async -> String {
    do {
        let flow = SeedkeepShareFlow(containerIdentifier: containerID)
        let url = try await flow.fetchPublishedURL()
        let result = try await flow.acceptAndRead(url: url)
        let crossAccount = !result.ownerStamp.isEmpty && result.participantStamp != result.ownerStamp
        try expect(crossAccount, "NOT cross-account: participant == owner (\(result.ownerStamp)). Both sims on the same iCloud account?")
        try expect(!result.householdName.isEmpty, "shared household unreadable (empty name)")
        return """
        ✅ Gate 2 PARTICIPANT: fetched the published URL + accepted the share + read the owner's household
        participant userRecordID = \(result.participantStamp)
        owner userRecordID (from shared record) = \(result.ownerStamp)
        shared household name = \(result.householdName)
        ✅ GENUINE CROSS-ACCOUNT: participant ≠ owner, owner's data read via sharedCloudDatabase
        """
    } catch {
        return "❌ Gate 2 PARTICIPANT failed: \(error)"
    }
}

// MARK: - Preflight + timeout (turn a CloudKit-auth hang into an actionable error)

private func describe(_ status: CKAccountStatus) -> String {
    switch status {
    case .available:             return "available"
    case .noAccount:             return "noAccount (not signed into iCloud)"
    case .restricted:            return "restricted"
    case .couldNotDetermine:     return "couldNotDetermine"
    case .temporarilyUnavailable: return "temporarilyUnavailable"
    @unknown default:            return "unknown(\(status.rawValue))"
    }
}

/// Race an async op against a deadline so a stuck CloudKit call REPORTS instead of hanging forever.
private func withTimeout(_ seconds: Double, _ op: @escaping () async -> String) async -> String {
    await withTaskGroup(of: String?.self) { group in
        group.addTask { await op() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil   // nil marks the timeout
        }
        let first = await group.next()!
        group.cancelAll()
        return first ?? "❌ TIMED OUT after \(Int(seconds))s — the CloudKit op never returned (auth token failing? see cloudd 'AuthTokenError'). Re-sign-in to iCloud on this sim + enable iCloud Drive."
    }
}

// MARK: - Dispatch

public func runSeedkeepSpike(mode: String, containerID: String = "iCloud.app.seedkeep") async -> String {
    // The ENTIRE flow (accountStatus preflight + the check body) runs inside withTimeout — when the
    // iCloud auth token is broken, even `accountStatus()` blocks on cloudd forever, so the preflight
    // must be bounded too (a prior run hung indefinitely here). A clean "TIMED OUT" beats a hang.
    await withTimeout(60) {
        let container = CKContainer(identifier: containerID)
        let status = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard status == .available else {
            return "❌ CloudKit account not usable: \(describe(status)). Sign into iCloud on this sim (Settings ▸ Apple ID ▸ iCloud) + enable iCloud Drive, then retry."
        }
        let result: String
        switch mode {
        case "roundtrip":   result = await runSeedkeepRoundtripCheck(containerID: containerID)
        case "merge":       result = await runSeedkeepMergeCheck(containerID: containerID)
        case "owner":       result = await runSeedkeepShareOwnerCheck(containerID: containerID)
        case "participant": result = await runSeedkeepShareParticipantCheck(containerID: containerID)
        default:            return "❌ unknown spike mode: \(mode) (expected roundtrip|merge|owner|participant)"
        }
        return result + "\n(accountStatus = available)"
    }
}
#endif
