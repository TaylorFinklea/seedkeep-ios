import Foundation
import Observation
import SeedkeepCloudKit

// N2-E §6: the guard runner. One per app, on the main actor, owns every guard transition: grant
// creation and abandonment, the gone handling, binding repair, and (G3) the journals. A keep, a discard
// and the silent re-home run here, single flight per garden, after the runner has quiesced the writers
// that could race them. The steps themselves are `GardenJournalExecutor`'s.
//
// Windows observe it; they never run it. Every window shares the one `AppEnvironment`, so one gone
// entry, one epoch and one placeholder serve all of them.

/// A garden that was found gone: what the coordinator tells the runner (contract §6, "On gone").
struct GardenGoneEvent: Equatable, Sendable {
    let accountKey: String
    let householdID: String
    let reason: GardenGoneRecord.Reason
}

/// The garden a write was started against, and the scope epoch it started in. A writer captures it
/// when it starts and re-checks it at its final mutation boundary; a nil or changed value stops it.
struct WritableGarden: Equatable, Sendable {
    /// nil while signed out (no garden is active, and nothing is gone).
    let householdID: String?
    let epoch: Int
}

@MainActor
@Observable
final class GardenGuardRunner {
    let store: GardenGuardStore
    @ObservationIgnored let rehomer: any GardenRehoming

    /// `gardenScopeEpoch`: bumped on gone, on every binding change and on every account transition.
    /// A writer that started in an earlier epoch does nothing at its final boundary.
    private(set) var scopeEpoch = 0

    /// Gardens (`account|household`) whose journal is running. While one runs the garden is not
    /// writable (`isBlocked`). A durable open journal remains fenced until it completes or is superseded.
    private(set) var runningJournals = Set<String>()

    /// G3: runs the steps. Set by `AppEnvironment`; nil in a runner with nothing to run (tests of the
    /// plain guard), where a journal then simply waits.
    @ObservationIgnored var executor: (any GardenJournalExecuting)?
    /// Why a journal's last run stopped (`account|household` to a message). The window offers Try again.
    private(set) var journalFailures: [String: String] = [:]
    /// Journals started in this process: a journal that finished here is confirmed by a LATER launch.
    @ObservationIgnored private var startedThisProcess = Set<String>()
    @ObservationIgnored private var journalTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var journalFollowups: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var discardTransitions = Set<String>()
    /// Whether a later launch has confirmed the identity cache and participant marker against the
    /// guard's latest binding for the account (`AuthController.launchDefaultsConfirmed`).
    @ObservationIgnored var defaultsConfirmed: ((String) -> Bool)?
    /// How many journals this process started (a test probe: repeated taps and two windows run one).
    @ObservationIgnored private(set) var journalStarts = 0

    /// True once launch resolution has finished and the runner has resumed. Until then a launch that
    /// found a journal or gone entry mutates nothing (contract §6, "Launch ordering").
    private(set) var hasResumed = false
    @ObservationIgnored private let startedWithEntries: Bool

    /// Fired in the gone step, after the entry is written, the coordinator is stopped and the scope
    /// epoch is bumped: `AppEnvironment` bumps `pendingShareEpoch`, cancels the garden's
    /// notifications and drops its pending shares here.
    @ObservationIgnored var onGardenLost: ((GardenGoneEvent) -> Void)?

    /// How many gone entries this process wrote (a test probe).
    @ObservationIgnored private(set) var goneCommits = 0
    /// Accounts whose launch resume has run, and the journals already handed to the re-home seam
    /// (`account|household`): a journal is handed over once per process, however often `resume` runs.
    @ObservationIgnored private var resumedAccounts = Set<String>()
    @ObservationIgnored private var handedOff = Set<String>()
    @ObservationIgnored private var journalCancellationInProgress = false
    /// Gardens fenced for the rest of the process because their gone entry could not be written
    /// (or no account was resolved to write it under), keyed by account and household: a failed
    /// commit for one account never blocks another account with access to the same shared garden.
    /// An unresolved account is the empty string, which blocks that household for any account.
    /// Detection repeats at the next launch.
    private(set) var memoryFenced = Set<String>()

    func isMemoryFenced(account: String, householdID: String) -> Bool {
        memoryFenced.contains(Self.journalKey(account, householdID))
            || memoryFenced.contains(Self.journalKey("", householdID))
    }

    func isDiscardResolutionPending(account: String, householdID: String) -> Bool {
        discardTransitions.contains(Self.journalKey(account, householdID))
    }

    init(store: GardenGuardStore, rehomer: any GardenRehoming) {
        self.store = store
        self.rehomer = rehomer
        self.startedWithEntries = store.hasUnresolvedEntries
        self.hasResumed = !store.hasUnresolvedEntries
    }

    /// Launch resolution is done: windows may show a garden and background services may start.
    var isLaunchResolved: Bool { hasResumed || !startedWithEntries }

    // MARK: - Scope

    func bumpScopeEpoch() { scopeEpoch &+= 1 }

    /// Whether writes to this garden are stopped: it is gone and awaiting a choice, or its journal runs.
    func isBlocked(account: String, householdID: String) -> Bool {
        store.isGone(account, householdID) || store.hasOpenJournal(account, householdID)
            || store.isRetired(account, householdID)
            || discardTransitions.contains(Self.journalKey(account, householdID))
            || runningJournals.contains(Self.journalKey(account, householdID))
            || isMemoryFenced(account: account, householdID: householdID)
    }

    /// G3 seam: a keep, discard or re-home journal starts or stops running for a garden. While it
    /// runs the garden is not writable (`isBlocked`), so no writer races the journal's own steps.
    func beginJournal(account: String, householdID: String) {
        runningJournals.insert(Self.journalKey(account, householdID))
        bumpScopeEpoch()
    }

    func endJournal(account: String, householdID: String) {
        runningJournals.remove(Self.journalKey(account, householdID))
        bumpScopeEpoch()
    }

    static func journalKey(_ account: String, _ householdID: String) -> String { "\(account)|\(householdID)" }

    // MARK: - Gone (contract §6, "On gone")

    /// Step 1, the commit point: writes the `gone` entry (phase `awaitingChoice`). Returns false when
    /// the guard can't be written; the coordinator then stays stopped and detection repeats at the
    /// next start. The caller does step 2 (coordinator epoch, engine retirement) and then
    /// `finishGone`, all in one main-actor step with no `await` between them.
    func commitGone(_ event: GardenGoneEvent) -> Bool {
        do {
            try store.markGone(event.accountKey, event.householdID, reason: event.reason)
            goneCommits += 1
            return true
        } catch {
            // The commit point failed: the garden is fenced for the rest of this process all the same.
            memoryFenced.insert(Self.journalKey(event.accountKey, event.householdID))
            return false
        }
    }

    /// Fences a garden in memory when no entry can be written for it (no account resolved).
    func fenceInMemory(account: String, householdID: String) {
        memoryFenced.insert(Self.journalKey(account, householdID))
    }

    /// Step 3: bumps `gardenScopeEpoch` (which clears `writableGarden` for every writer) and lets the
    /// environment bump `pendingShareEpoch` and cancel notifications.
    func finishGone(_ event: GardenGoneEvent) {
        bumpScopeEpoch()
        onGardenLost?(event)
    }

    // MARK: - Launch

    /// Runs once `restoreSession` has verified the iCloud account that owns the entries, and only
    /// then: with no verified account it does nothing and the launch gate stays closed, so windows
    /// and deferred services wait over an unverified garden that may hold a journal. Entries of
    /// another account stay untouched. The owning account's open journals are handed to the G3 seam,
    /// each once per process; a gone entry needs nothing here, because the placeholder and the fence
    /// derive from it. Repeated calls are no-ops.
    func resume(accountKey: String?) {
        guard let accountKey, store.isReadable else { return }
        defer { hasResumed = true }
        if resumedAccounts.insert(accountKey).inserted {
            // A verified bind may already have dispatched a silent re-home before launch resumes.
            // Do not invalidate that task here; real account/binding changes and journal starts
            // advance the epoch at their own transition points.
            var startedJournal = false
            for (householdID, record) in store.account(accountKey).gone.sorted(by: { $0.key < $1.key }) {
                let key = Self.journalKey(accountKey, householdID)
                switch (record.phase, record.action) {
                case (.journaled, .rehome?):
                    guard let replacement = record.replacementID, handedOff.insert(key).inserted else { continue }
                    rehomer.rehomeRequested(GardenRehomeRequest(
                        accountKey: accountKey, fromHouseholdID: householdID,
                        toHouseholdID: replacement, reason: record.reason))
                case (.journaled, .keep?), (.journaled, .discard?):
                    // A choice the user made before the app stopped: it continues at its checkpoint.
                    guard !startedJournal else { continue }  // one active journal owns the local store at a time
                    guard handedOff.insert(key).inserted else { continue }
                    startedJournal = true
                    startJournal(account: accountKey, householdID: householdID)
                case (.done, _), (.superseded, _):
                    removeClosedJournalIfConfirmed(accountKey, householdID, record)
                default:
                    break
                }
            }
        }
        // A completed discard whose identity verification was interrupted remains fenced until
        // this verified launch can safely resolve it. Repeated resume calls retry that follow-up.
        for key in discardTransitions where key.hasPrefix(accountKey + "|") {
            let householdID = String(key.dropFirst(accountKey.count + 1))
            startDiscardResolution(account: accountKey, householdID: householdID)
        }
    }

    /// A closed journal is removed only by a LATER launch (one that did not run it) that has confirmed
    /// the defaults against the latest binding, and, for a keep, only once the replacement's grant is
    /// consumed (the first sync created the zone). Never earlier (contract §1, §7).
    private func removeClosedJournalIfConfirmed(_ account: String, _ householdID: String, _ record: GardenGoneRecord) {
        let key = Self.journalKey(account, householdID)
        guard !startedThisProcess.contains(key), defaultsConfirmed?(account) == true else { return }
        if record.phase == .done, record.action != .discard, let replacement = record.replacementID,
           store.grant(account, replacement) != nil { return }
        try? store.removeJournal(account, householdID)
    }

    // MARK: - Journals (G3)

    /// The user's answer on the choice screen. One guard write fixes the action, the replacement ID
    /// and its `pending` grant first; then the journal runs. Repeated taps and a second window find the
    /// journal already fixed (or running) and start nothing more. Returns false when the answer could
    /// not be recorded (the failure is shown, with Try again).
    @discardableResult
    func choose(account: String, householdID: String, action: GardenGoneRecord.Action, freshID: String) -> Bool {
        let key = Self.journalKey(account, householdID)
        if runningJournals.contains(key) { return true }
        do {
            if store.journal(account, householdID) == nil {
                // A garden fenced in memory only (its entry could not be written): record it now.
                try store.markGone(account, householdID, reason: .zoneMissing)
            }
            try store.chooseAction(account, householdID, action: action,
                                   replacementID: action == .discard ? nil : freshID)
        } catch {
            journalFailures[key] = GardenGuardError.writeFailed.errorDescription
            return false
        }
        startJournal(account: account, householdID: householdID)
        return true
    }

    /// Runs the open journal of a garden, single flight. The garden stops being writable at once
    /// (before any await); the scan resume and the weather refresh are cancelled and awaited; then the
    /// steps run. A failed step keeps its checkpoint and leaves a message for Try again.
    func startJournal(account: String, householdID: String) {
        let key = Self.journalKey(account, householdID)
        guard !journalCancellationInProgress, !runningJournals.contains(key), let executor, store.isReadable,
              let record = store.journal(account, householdID), record.phase == .journaled,
              record.action != nil else { return }
        journalStarts += 1
        startedThisProcess.insert(key)
        journalFailures[key] = nil
        beginJournal(account: account, householdID: householdID)
        let journalScopeEpoch = scopeEpoch
        journalTasks[key] = Task { @MainActor [weak self] in
            var failure: String?
            var cancelled = false
            do {
                await executor.quiesceWriters()
                try Task.checkCancellation()
                guard executor.isCurrent(account: account, householdID: householdID,
                                         scopeEpoch: journalScopeEpoch) else {
                    throw CancellationError()
                }
                try await executor.run(account: account, householdID: householdID,
                                       scopeEpoch: journalScopeEpoch)
                try Task.checkCancellation()
            } catch is CancellationError {
                // The durable journal remains open and fenced. A later launch or Try again resumes it.
                cancelled = true
            } catch {
                failure = Self.failureMessage(error)
            }
            guard let self else { return }
            let completedDiscard = !cancelled && failure == nil
                && self.store.journal(account, householdID)?.phase == .done
                && self.store.journal(account, householdID)?.action == .discard
            if cancelled {
                self.journalFailures[key] = "This garden change was paused while iCloud was checked. Try again."
                self.handedOff.remove(key)
                self.resumedAccounts.remove(account)
            }
            if let failure { self.journalFailures[key] = failure }
            self.journalTasks[key] = nil
            self.endJournal(account: account, householdID: householdID)
            if completedDiscard {
                // Retired IDs remain fenced. Resolve only after the journal task leaves its registry.
                self.discardTransitions.insert(key)
                self.startDiscardResolution(account: account, householdID: householdID)
            }
        }
    }

    /// Try again after a failed step: runs the same journal from its checkpoint.
    func retryJournal(account: String, householdID: String) {
        if isDiscardResolutionPending(account: account, householdID: householdID) {
            startDiscardResolution(account: account, householdID: householdID)
            return
        }
        startJournal(account: account, householdID: householdID)
    }

    /// Waits for a garden's running journal (tests and launch ordering).
    func awaitJournal(account: String, householdID: String) async {
        let key = Self.journalKey(account, householdID)
        await journalTasks[key]?.value
        await journalFollowups[key]?.value
        journalFollowups[key] = nil
    }

    private func startDiscardResolution(account: String, householdID: String) {
        let key = Self.journalKey(account, householdID)
        guard journalFollowups[key] == nil, let executor else { return }
        let epoch = scopeEpoch
        journalFailures[key] = nil
        journalFollowups[key] = Task { @MainActor [weak self] in
            let resolved = await executor.didDiscard(account: account, householdID: householdID, scopeEpoch: epoch)
            guard let self else { return }
            self.journalFollowups[key] = nil
            if resolved {
                self.journalFailures[key] = nil
                self.discardTransitions.remove(key)
                self.bumpScopeEpoch()
            } else {
                self.journalFailures[key] = "This garden change is waiting for iCloud account verification. Try again."
            }
        }
    }

    /// Identity/store erasers call this before touching local data. Cancellation is cooperative and
    /// every journal task is awaited, including an in-flight detached photo copy, before the wipe.
    func cancelAndWaitJournals() async {
        journalCancellationInProgress = true
        defer { journalCancellationInProgress = false }
        let tasks = Array(journalTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }

    func journalFailure(account: String, householdID: String) -> String? {
        journalFailures[Self.journalKey(account, householdID)]
    }

    static func failureMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Seedkeep couldn't finish this. Nothing was lost; try again."
    }
}
