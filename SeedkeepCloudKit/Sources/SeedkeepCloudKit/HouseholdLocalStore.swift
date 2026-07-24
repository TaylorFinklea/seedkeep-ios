#if canImport(CloudKit)
import CloudKit
import Foundation

/// Local mirror of a household zone's records — the source of truth CKSyncEngine
/// uploads from and applies fetched changes into.
///
/// Thread-safe: every access to `records` is serialized by `lock`.
/// `@unchecked Sendable` is justified by that invariant and exercised by concurrent-access tests.
public final class HouseholdLocalStore: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord] = [:]

    public init() {}

    public func record(for id: CKRecord.ID) -> CKRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    public func allRecords() -> [CKRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.values)
    }

    public func records(ofType recordType: String) -> [CKRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter { $0.recordType == recordType }
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    public func setRecord(_ record: CKRecord) {
        lock.lock(); defer { lock.unlock() }
        records[record.recordID] = record
    }

    public func removeRecord(_ id: CKRecord.ID) {
        lock.lock(); defer { lock.unlock() }
        records[id] = nil
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
    }

    /// Record IDs of the local children that CASCADE off `parentName` (G5: client-side cascade sweep).
    /// Manifest-independent: the `.deleteSelf` action IS the marker.
    public func recordIDsCascadingFrom(_ parentName: String) -> [CKRecord.ID] {
        lock.lock(); defer { lock.unlock() }
        var result: [CKRecord.ID] = []
        for (id, record) in records {
            for key in record.allKeys() {
                if let reference = record[key] as? CKRecord.Reference,
                   reference.action == .deleteSelf,
                   reference.recordID.recordName == parentName {
                    result.append(id)
                    break
                }
            }
        }
        return result
    }

    /// Apply a record fetched from the server. Plain records are LWW pass-through;
    /// the merger plugs custom rules into HouseholdSyncEngine at the fetch seam.
    public func applyRemoteModification(_ record: CKRecord) {
        lock.lock(); defer { lock.unlock() }
        records[record.recordID] = record
    }
}
#endif
