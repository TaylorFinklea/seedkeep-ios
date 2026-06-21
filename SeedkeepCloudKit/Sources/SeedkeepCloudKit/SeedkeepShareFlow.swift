#if canImport(CloudKit)
import CloudKit
import Foundation

/// The cross-account CKShare flow for the R1 Phase-0 spike. A household zone is shared
/// (day-one share, spec §4); a participant on a DIFFERENT iCloud account accepts and reads it.
/// The share URL hands off cross-account through the PUBLIC database (both accounts can read it),
/// so the owner→participant round-trip is fully automatable via CKFetchShareMetadataOperation +
/// CKAcceptSharesOperation — no UICloudSharingController tap required.
///
/// Adapted from SimmerSmith's HouseholdShareFlow (reference, validated independently): Seedkeep's
/// container, the `Household` root record type, and SeedkeepRecordNames for zone/record naming.
public struct SeedkeepShareFlow {
    public let container: CKContainer
    private let containerID: String

    public init(containerIdentifier: String = "iCloud.app.seedkeep") {
        self.containerID = containerIdentifier
        self.container = CKContainer(identifier: containerIdentifier)
    }

    public enum ShareError: Error, CustomStringConvertible {
        case noURL, noMetadata, noSharedRoot
        public var description: String {
            switch self {
            case .noURL: return "share produced no URL"
            case .noMetadata: return "could not fetch share metadata"
            case .noSharedRoot: return "shared root record not readable"
            }
        }
    }

    /// The signed-in account's CloudKit user record name (differs per iCloud account — used to
    /// PROVE the owner and participant are genuinely different accounts).
    public func currentUserRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    // MARK: Owner — create a shareable household + publish its URL

    public struct OwnerResult { public let url: URL; public let ownerStamp: String }

    public func createAndPublishShare(householdID: String, name: String) async throws -> OwnerResult {
        let ownerStamp = try await currentUserRecordName()
        let db = container.privateCloudDatabase
        let zone = try await SeedkeepZoneProvisioner(containerIdentifier: containerID)
            .ensureZone(householdID: householdID)
        let recordID = CKRecord.ID(recordName: SeedkeepRecordNames.household(householdID), zoneID: zone.zoneID)

        let root: CKRecord
        do {
            root = try await db.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            root = CKRecord(recordType: SeedkeepRecordType.household.recordTypeName, recordID: recordID)
            root["name"] = name as CKRecordValue
            root["createdAt"] = Int(Date().timeIntervalSince1970 * 1000) as CKRecordValue
            root["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000) as CKRecordValue
        }
        root["ownerStamp"] = ownerStamp as CKRecordValue   // so the participant can confirm whose data it sees

        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = name as CKRecordValue
        share.publicPermission = .readWrite   // anyone with the link can join (spike simplicity)

        // IDEMPOTENT: `CKShare(rootRecord:)` + save throws serverRecordAlreadyShared when the root is
        // already shared (every run after the first, since the zone persists). Catch it and reuse the
        // existing share instead of failing.
        let url: URL
        do {
            _ = try await db.modifyRecords(saving: [root, share], deleting: [])
            guard let u = share.url else { throw ShareError.noURL }
            url = u
        } catch let error as CKError where error.code == .alreadyShared {
            let freshRoot = try await db.record(for: recordID)
            guard let shareRef = freshRoot.share,
                  let existing = try await db.record(for: shareRef.recordID) as? CKShare,
                  let u = existing.url else { throw error }
            url = u
        }

        try await publishURL(url)
        return OwnerResult(url: url, ownerStamp: ownerStamp)
    }

    private static let handoffRecordName = "seedkeep-spike-share-handoff"

    private func publishURL(_ url: URL) async throws {
        // IDEMPOTENT: fetch the existing handoff record (so the save carries its server change tag);
        // a fresh CKRecord has no tag and the default save policy rejects it with serverRecordChanged
        // on the second run.
        let id = CKRecord.ID(recordName: Self.handoffRecordName)
        let record = (try? await container.publicCloudDatabase.record(for: id))
            ?? CKRecord(recordType: "ShareHandoff", recordID: id)
        record["url"] = url.absoluteString as CKRecordValue
        _ = try await container.publicCloudDatabase.modifyRecords(saving: [record], deleting: [])
    }

    public func fetchPublishedURL() async throws -> URL {
        let record = try await container.publicCloudDatabase
            .record(for: CKRecord.ID(recordName: Self.handoffRecordName))
        guard let string = record["url"] as? String, let url = URL(string: string) else {
            throw ShareError.noURL
        }
        return url
    }

    // MARK: Participant — accept the share + read the shared household

    public struct ParticipantResult {
        public let participantStamp: String
        public let ownerStamp: String
        public let householdName: String
    }

    public func acceptAndRead(url: URL) async throws -> ParticipantResult {
        let participantStamp = try await currentUserRecordName()
        let metadata = try await fetchShareMetadata(url: url)
        try await acceptShare(metadata)

        guard let rootID = metadata.hierarchicalRootRecordID else { throw ShareError.noSharedRoot }
        let shared = try await container.sharedCloudDatabase.record(for: rootID)
        return ParticipantResult(
            participantStamp: participantStamp,
            ownerStamp: shared["ownerStamp"] as? String ?? "",
            householdName: shared["name"] as? String ?? "")
    }

    private func fetchShareMetadata(url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            operation.shouldFetchRootRecord = true
            var fetched: CKShare.Metadata?
            operation.perShareMetadataResultBlock = { _, result in
                if case .success(let metadata) = result { fetched = metadata }
            }
            operation.fetchShareMetadataResultBlock = { result in
                switch result {
                case .success:
                    if let fetched { continuation.resume(returning: fetched) }
                    else { continuation.resume(throwing: ShareError.noMetadata) }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            container.add(operation)
        }
    }

    private func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            container.add(operation)
        }
    }
}
#endif
