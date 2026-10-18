// Inline editing and writes for the Seeds table (redesign R1, slice B).
//
// Drafts live here, keyed by (seed id, field), so they survive re-sorting and cells being
// recreated. Every write goes through `SyncEngine` (`enqueueUpdateSeed`, `enqueueDeleteSeed`) with a
// patch that carries only the changed field, and registers the reciprocal patch on the window's
// `UndoManager` after the write succeeds. Failures are presented the same way whether they come from
// a forward edit, a delete, or an undo.
import Foundation
import Observation
import SwiftData
import SeedkeepKit

/// Fields that edit as text drafts in the table. Status and location are pickers and commit when
/// the choice is made, so they have no draft.
enum SeedDraftField: String, Hashable, Sendable {
    case packets, year
}

struct SeedDraftKey: Hashable, Sendable {
    let seedID: String
    let field: SeedDraftField
}

enum SeedEditError: Error, Equatable, Sendable {
    case packetsNotWholeNumber
    case yearOutOfRange(earliest: Int, latest: Int)

    var message: String {
        switch self {
        case .packetsNotWholeNumber:
            return "Enter a whole number, 0 or more."
        case let .yearOutOfRange(earliest, latest):
            return "Enter a year from \(earliest) to \(latest), or leave it empty."
        }
    }
}

enum SeedInputValidation {
    /// Packets: an integer of 0 or more.
    static func packets(_ text: String) -> Result<Int, SeedEditError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else {
            return .failure(.packetsNotWholeNumber)
        }
        return .success(value)
    }

    /// Year: empty (clears it) or an integer from 1900 to next year.
    static func year(_ text: String, currentYear: Int) -> Result<Int?, SeedEditError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        let latest = currentYear + 1
        guard let value = Int(trimmed), (1900...latest).contains(value) else {
            return .failure(.yearOutOfRange(earliest: 1900, latest: latest))
        }
        return .success(value)
    }
}

/// Draft text, per-cell errors and the Escape-suppression flag for one window's table.
@MainActor
@Observable
final class SeedEditing {
    private(set) var drafts: [SeedDraftKey: String] = [:]
    private(set) var errors: [SeedDraftKey: String] = [:]
    /// Set by Escape. The blur that follows the cancel must not commit.
    private var suppressedBlur: SeedDraftKey?

    func draft(for key: SeedDraftKey) -> String? {
        drafts[key]
    }

    /// The text a cell shows: the draft if there is one, otherwise the stored value.
    func text(for key: SeedDraftKey, shown: String) -> String {
        drafts[key] ?? shown
    }

    func setDraft(_ text: String, for key: SeedDraftKey) {
        drafts[key] = text
        errors[key] = nil
    }

    /// Escape: drop the draft and its error, and make sure the blur that follows does not commit.
    func cancel(_ key: SeedDraftKey) {
        drafts[key] = nil
        errors[key] = nil
        suppressedBlur = key
    }

    /// A commit that failed validation keeps the draft and shows the message.
    func fail(_ key: SeedDraftKey, message: String) {
        errors[key] = message
    }

    /// A commit that succeeded (or found nothing to change) clears the draft.
    func finish(_ key: SeedDraftKey) {
        drafts[key] = nil
        errors[key] = nil
    }

    /// True once for the blur that follows an Escape.
    func consumeSuppressedBlur(for key: SeedDraftKey) -> Bool {
        guard suppressedBlur == key else { return false }
        suppressedBlur = nil
        return true
    }

    func discardAll() {
        drafts = [:]
        errors = [:]
        suppressedBlur = nil
    }

    /// Drops drafts for seeds that are no longer live. Returns the dropped seed ids so the view can
    /// say what happened.
    @discardableResult
    func discardMissing(liveIDs: Set<String>) -> [String] {
        let missing = Set(drafts.keys.map(\.seedID)).subtracting(liveIDs)
        guard !missing.isEmpty else { return [] }
        drafts = drafts.filter { !missing.contains($0.key.seedID) }
        errors = errors.filter { !missing.contains($0.key.seedID) }
        return missing.sorted()
    }
}

// MARK: - Writes

/// One field change for a set of seeds. Bulk actions and inline edits both build one of these.
enum SeedFieldEdit: Equatable, Sendable {
    case status(SeedState)
    case location(String?)
    case packets(Int)
    case year(Int?)
    case addTag(String)

    var actionName: String {
        switch self {
        case .status: return "Set Status"
        case .location: return "Move to Location"
        case .packets: return "Edit Packets"
        case .year: return "Edit Year"
        case .addTag: return "Add Tag"
        }
    }
}

/// One seed's forward patch and its reciprocal. The reciprocal is what undo sends.
struct SeedPatchChange: Sendable {
    let seedID: String
    let forward: SeedkeepClient.UpdateSeedInput
    let inverse: SeedkeepClient.UpdateSeedInput
}

struct SeedWriteFailure: Equatable, Sendable {
    let seedID: String
    /// What a message may call the seed: its name when it is one of the household's own seeds, and
    /// "A seed" otherwise, so another household's name never reaches the screen.
    let name: String
    let message: String
}

struct SeedWriteReport: Equatable, Sendable {
    var changed: [String] = []
    /// Seeds already holding the value. Nothing was written and nothing is undoable.
    var unchanged: [String] = []
    var failures: [SeedWriteFailure] = []

    /// The sentence shown when some writes failed, or nil when none did.
    var issueMessage: String? {
        guard let first = failures.first else { return nil }
        let total = changed.count + failures.count
        let noun = total == 1 ? "seed" : "seeds"
        let names = failures.map(\.name).joined(separator: ", ")
        return "Couldn't change \(failures.count) of \(total) \(noun): \(names). \(first.message)"
    }
}

/// A pending delete. The initializer is private to this file, so the only way to get one is
/// `SeedWriter.requestDeletion`, and `confirmDeletion` is the only thing that deletes.
struct SeedDeletionRequest: Equatable, Sendable {
    let seedIDs: [String]

    fileprivate init(seedIDs: [String]) {
        self.seedIDs = seedIDs.sorted()
    }

    var count: Int { seedIDs.count }
}

/// Writes seed edits through `SyncEngine` and registers undo. Created per view evaluation; it holds
/// no state of its own, so the window's `UndoManager` is the only history.
@MainActor
struct SeedWriter {
    let sync: SyncEngine
    let container: ModelContainer
    /// Weak: registered undo actions capture this writer, and the manager owns those actions,
    /// so a strong reference would form a cycle that outlives the window.
    weak var undoManager: UndoManager?
    /// Read at write time, so an undo checks the household as it is now.
    let currentHouseholdID: @MainActor () -> String?
    /// Kicks off the push queue after a write (the views call `flushPending` the same way).
    let flush: @MainActor () -> Void
    /// Shows failed writes. Called for forward edits, deletes, and undo and redo alike.
    let presentIssues: @MainActor (SeedWriteReport) -> Void

    private static let unavailable = "No longer available."

    /// Applies one edit to each seed. Seeds that already hold the value are skipped. Values are read
    /// from the store so the reciprocal patch records what was there, not what the table showed.
    func apply(_ edit: SeedFieldEdit, to seedIDs: [String]) -> SeedWriteReport {
        var preFailures: [SeedWriteFailure] = []
        var unchanged: [String] = []
        var changes: [SeedPatchChange] = []
        let context = ModelContext(container)
        for seedID in Set(seedIDs).sorted() {
            guard let seed = liveSeed(seedID, in: context) else {
                preFailures.append(failure(for: seedID, in: context))
                continue
            }
            if let change = Self.change(for: edit, on: seed) {
                changes.append(change)
            } else {
                unchanged.append(seedID)
            }
        }
        var report = write(changes, actionName: edit.actionName)
        report.unchanged = unchanged
        report.failures = preFailures + report.failures
        present(report)
        return report
    }

    /// Inline commit from a text draft. A validation failure writes nothing and returns the error,
    /// so the caller keeps the draft.
    func commitDraft(
        _ key: SeedDraftKey,
        text: String,
        currentYear: Int
    ) -> Result<SeedWriteReport, SeedEditError> {
        switch key.field {
        case .packets:
            switch SeedInputValidation.packets(text) {
            case .success(let count):
                return .success(apply(.packets(count), to: [key.seedID]))
            case .failure(let error):
                return .failure(error)
            }
        case .year:
            switch SeedInputValidation.year(text, currentYear: currentYear) {
            case .success(let year):
                return .success(apply(.year(year), to: [key.seedID]))
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Asks before deleting. Nothing is removed until `confirmDeletion` gets the request back.
    func requestDeletion(_ seedIDs: [String]) -> SeedDeletionRequest {
        SeedDeletionRequest(seedIDs: Array(Set(seedIDs)))
    }

    func confirmDeletion(_ request: SeedDeletionRequest) -> SeedWriteReport {
        var report = SeedWriteReport()
        let context = ModelContext(container)
        for seedID in request.seedIDs {
            guard liveSeed(seedID, in: context) != nil else {
                report.failures.append(failure(for: seedID, in: context))
                continue
            }
            do {
                try sync.enqueueDeleteSeed(id: seedID)
                report.changed.append(seedID)
            } catch {
                report.failures.append(SeedWriteFailure(
                    seedID: seedID, name: name(for: seedID, in: context), message: humanizeError(error)
                ))
            }
        }
        if !report.changed.isEmpty { flush() }
        present(report)
        return report
    }

    /// Writes the patches and registers their reciprocals as one undo step, then presents any
    /// failure. Undo and redo come through here, so their failures are shown too.
    @discardableResult
    func perform(_ changes: [SeedPatchChange], actionName: String) -> SeedWriteReport {
        let report = write(changes, actionName: actionName)
        present(report)
        return report
    }

    /// The writes themselves, without presenting. Liveness is checked here, at write time, so an undo
    /// never writes to a seed that has since been deleted or moved to another household. Only the
    /// writes that succeeded are registered for undo.
    private func write(_ changes: [SeedPatchChange], actionName: String) -> SeedWriteReport {
        var report = SeedWriteReport()
        var applied: [SeedPatchChange] = []
        let context = ModelContext(container)
        for change in changes {
            guard liveSeed(change.seedID, in: context) != nil else {
                report.failures.append(failure(for: change.seedID, in: context))
                continue
            }
            do {
                try sync.enqueueUpdateSeed(id: change.seedID, change.forward)
                applied.append(change)
                report.changed.append(change.seedID)
            } catch {
                report.failures.append(SeedWriteFailure(
                    seedID: change.seedID,
                    name: name(for: change.seedID, in: context),
                    message: humanizeError(error)
                ))
            }
        }
        guard !applied.isEmpty else { return report }

        // During an undo, UndoManager files this registration on the redo stack, and the reverse.
        // An explicit group makes the batch one undo step whatever `groupsByEvent` is set to.
        let reciprocal = applied.map {
            SeedPatchChange(seedID: $0.seedID, forward: $0.inverse, inverse: $0.forward)
        }
        let writer = self
        if let undoManager {
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: sync) { _ in
                _ = writer.perform(reciprocal, actionName: actionName)
            }
            undoManager.setActionName(actionName)
            undoManager.endUndoGrouping()
        }
        flush()
        return report
    }

    private func present(_ report: SeedWriteReport) {
        guard !report.failures.isEmpty else { return }
        presentIssues(report)
    }

    /// The patch that moves one seed to the edit's value, with its reciprocal. Nil when the seed
    /// already holds that value.
    static func change(for edit: SeedFieldEdit, on seed: LocalSeed) -> SeedPatchChange? {
        let seedID = seed.id
        switch edit {
        case .status(let state):
            guard seed.state != state else { return nil }
            return SeedPatchChange(
                seedID: seedID,
                forward: .init(state: state),
                inverse: .init(state: seed.state)
            )
        case .location(let locationID):
            guard seed.locationID != locationID else { return nil }
            return SeedPatchChange(
                seedID: seedID,
                forward: .init(location_id: .some(locationID)),
                inverse: .init(location_id: .some(seed.locationID))
            )
        case .packets(let count):
            guard seed.packetCount != count else { return nil }
            return SeedPatchChange(
                seedID: seedID,
                forward: .init(packet_count: count),
                inverse: .init(packet_count: seed.packetCount)
            )
        case .year(let year):
            guard seed.yearPacked != year else { return nil }
            return SeedPatchChange(
                seedID: seedID,
                forward: .init(year_packed: .some(year)),
                inverse: .init(year_packed: .some(seed.yearPacked))
            )
        case .addTag(let tagID):
            let current = seed.tagIDs
            guard !current.contains(tagID) else { return nil }
            return SeedPatchChange(
                seedID: seedID,
                forward: .init(tag_ids: current + [tagID]),
                inverse: .init(tag_ids: current)
            )
        }
    }

    /// The seed if it exists, is not deleted, and belongs to the current household.
    private func liveSeed(_ seedID: String, in context: ModelContext) -> LocalSeed? {
        let id = seedID
        let descriptor = FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id })
        guard let seed = try? context.fetch(descriptor).first, seed.deletedAt == nil else { return nil }
        guard let household = currentHouseholdID(), seed.householdID == household else { return nil }
        return seed
    }

    private func failure(for seedID: String, in context: ModelContext) -> SeedWriteFailure {
        SeedWriteFailure(seedID: seedID, name: name(for: seedID, in: context), message: Self.unavailable)
    }

    /// The name a message may show: the seed's own name for a household seed (deleted or not), and
    /// "A seed" for anything else, including seeds that belong to another household.
    private func name(for seedID: String, in context: ModelContext) -> String {
        let id = seedID
        let descriptor = FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id })
        guard let seed = try? context.fetch(descriptor).first,
              let household = currentHouseholdID(),
              seed.householdID == household
        else { return "A seed" }
        return seed.displayName
    }
}
