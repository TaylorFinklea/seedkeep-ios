import Foundation

// Seedkeep merge core — pure Swift, no CloudKit import.
// Adapted from SimmerSmith's GroceryMerge/Models.swift (Mergeable, SyncClock, CheckState).
// The protocol surface is identical; the type names are shared (app-agnostic).
//
// SimmerSmith note: SyncClock as Int works well for updatedAt-as-millis; Seedkeep's
// updatedAt is an Int64 unix-millis. Using Int here (64-bit on Apple Silicon/iOS) is
// safe — Int is 64-bit on all Apple platforms we target.

// MARK: - Sync clock

/// Logical clock: higher = later. Seedkeep stores updatedAt as Int64 unix milliseconds;
/// on 64-bit Apple platforms Int == Int64, so this is the same wire type.
public typealias SyncClock = Int

// MARK: - Mergeable protocol

/// Common surface every synced record exposes for conflict resolution.
public protocol Mergeable {
    var recordName: String { get }
    var modifiedAt: SyncClock { get }
}

// MARK: - CheckState (JournalChecklistItem)

/// The (completed, updatedAt) pair for a JournalChecklistItem — resolved as a UNIT
/// (prevents torn check-state: completed=true with an old updatedAt from one device
/// can't beat completed=false with a newer updatedAt from another).
///
/// Mirrors SimmerSmith's CheckState exactly. SimmerSmith's `by` field (checker identity)
/// doesn't exist in Seedkeep's schema, so it's omitted here.
public struct CheckState: Equatable {
    public var isCompleted: Bool
    public var at: SyncClock       // the updatedAt of the last completion-state mutation
    public init(isCompleted: Bool = false, at: SyncClock = 0) {
        self.isCompleted = isCompleted; self.at = at
    }
}

// MARK: - MergeResult (RecordMerger protocol output)

/// Output of a RecordMerger resolve call.
/// `record` carries the remote's system fields (change tag) so a re-save matches
/// the server version it merged against.
/// `needsResave` is true when the merged value differs from remote — the local
/// device holds sticky state the server lacks and must push it back.
public struct MergeResult {
    public let record: Any            // CKRecord — typed as Any to keep this file CloudKit-free
    public let needsResave: Bool
    public init(record: Any, needsResave: Bool) {
        self.record = record; self.needsResave = needsResave
    }
}
