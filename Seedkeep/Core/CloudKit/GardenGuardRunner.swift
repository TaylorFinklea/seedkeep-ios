import Foundation
import Observation
import SeedkeepCloudKit

// N2-E (G2) §6: the guard runner. One per app, on the main actor, owns every guard transition: grant
// creation and abandonment, the gone handling, binding repair. Keep, discard and the silent re-home
// are G3: the runner calls the `GardenRehoming` seam for them and runs nothing itself.
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

    /// Gardens (`account|household`) whose journal is running. G3's journal runner sets these; G2
    /// never does, so a re-home journal that only waits for G3 does not stop the garden's local use.
    private(set) var runningJournals = Set<String>()

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
        store.isGone(account, householdID) || runningJournals.contains(Self.journalKey(account, householdID))
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
        guard resumedAccounts.insert(accountKey).inserted else { return }
        for (householdID, record) in store.account(accountKey).gone.sorted(by: { $0.key < $1.key })
        where record.phase == .journaled && record.action == .rehome {
            guard let replacement = record.replacementID,
                  handedOff.insert(Self.journalKey(accountKey, householdID)).inserted else { continue }
            rehomer.rehomeRequested(GardenRehomeRequest(
                accountKey: accountKey, fromHouseholdID: householdID,
                toHouseholdID: replacement, reason: record.reason))
        }
        bumpScopeEpoch()
    }
}
