#if canImport(CloudKit)
import CloudKit
import Foundation

/// App-level account-change kind, mapped from `CKSyncEngine.Event.AccountChange.ChangeType`
/// at the engine seam so the coordinator (and its unit tests) never have to construct a
/// CloudKit framework enum value.
public enum HouseholdAccountChange: Sendable {
    case signIn, signOut, switchAccounts
}

/// The subset of `HouseholdSyncEngine` the live-engine coordinator depends on. Extracting it
/// as a protocol lets `HouseholdCloudCoordinator` (and the migration executor) be unit-tested
/// against a fake engine — no `CKContainer` / iCloud account required — while production wires
/// the real `HouseholdSyncEngine` (which conforms below).
///
/// `AnyObject` because the engine is a reference type the coordinator mutates (sets callbacks
/// + the merger on it) and holds for the app's lifetime.
public protocol HouseholdRecordSyncing: AnyObject, Sendable {
    /// The engine's local CKRecord mirror — the migration executor reads it to check for the
    /// idempotency receipt before importing.
    var store: HouseholdLocalStore { get }

    /// Field-merge resolver consulted at the fetch + serverRecordChanged seams.
    var merger: RecordMerger? { get set }

    /// Fired after a fetched batch is reconciled into the store, carrying the records that were
    /// actually applied this batch (post-merge; local-pending skips are excluded) and the
    /// deletion IDs. The coordinator decodes + projects these into SwiftData.
    var onFetchedChanges: (([CKRecord], [CKRecord.ID]) -> Void)? { get set }

    /// Fired on an iCloud account transition so the coordinator can wipe SwiftData (AC5).
    var onAccountChange: ((HouseholdAccountChange) -> Void)? { get set }

    func save(_ record: CKRecord)
    func delete(_ recordID: CKRecord.ID)
    /// Pull remote changes (fires `onFetchedChanges` as batches arrive).
    func fetchChanges() async throws
    /// Push staged changes, re-draining merged re-saves (G11).
    func sendUntilDrained(maxPasses: Int) async throws
}
#endif
