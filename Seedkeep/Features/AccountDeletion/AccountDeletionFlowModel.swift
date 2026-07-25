import Foundation
import Observation
import SeedkeepKit

/// The observable state behind `AccountDeletionFlowView` and
/// `AccountDeletionHandoffAcceptView`.
///
/// Account deletion is a resumable state machine over irreversible
/// effects, and `AccountDeletionCoordinator` owns all of it. This type owns
/// exactly one thing the coordinator does not: what a person is allowed to
/// be told, and when. That separation matters because the two failure
/// modes are different. The coordinator's job is to never destroy
/// something it should not; this type's job is to never *claim* something
/// that has not happened.
///
/// Three rules, each pinned by tests:
///
///   1. **Opening is not consenting.** `prepare()` reads the checkpoint off
///      disk and nothing else. A user who taps "Delete account" and then
///      changes their mind at the confirmation has sent no request and
///      touched no zone.
///   2. **Success is reported, never inferred.** `.deleted` appears only
///      when the coordinator returns `.deleted`, which happens only after
///      `DELETE /api/me` is confirmed. Waiting, cancelled, refused and
///      failed are all distinct, and none of them look like done.
///   3. **Affordances follow the durable phase.** Retry appears exactly
///      after a failure; Cancel exactly while the original garden still
///      exists — the same `Phase.sourceIsGone` predicate `cancel()`
///      enforces, so the button cannot offer what the coordinator will
///      refuse.
@MainActor
@Observable
final class AccountDeletionFlowModel {

    enum Stage: Equatable {
        /// Not presented, or finished and dismissed.
        case dormant
        /// Asking before doing anything at all. Nothing has been sent.
        case confirming
        /// This device is working. `nil` while the role is still being
        /// decided and there is no phase to name yet.
        case working(AccountDeletionCheckpoint.Phase?)
        /// Everything this device can do is done; the next move belongs to
        /// the other device or to the person holding the link.
        case waiting(AccountDeletionCheckpoint.Phase)
        /// A handoff link arrived with nobody signed in. Held, not spent.
        case signInRequired
        /// A handoff link has been LOOKED AT. The token is still unspent
        /// and stays that way until the user accepts.
        case handoffOffered(AccountDeletionCoordinator.HandoffPreview)
        /// This device cannot take the handoff. The token was never spent,
        /// so the rightful successor can still use the link.
        case handoffRefused(String)
        /// A successor finished their half. Their own account is untouched.
        case handoffComplete
        /// The deletion was abandoned while the garden was still intact.
        case cancelled
        case failed(phase: AccountDeletionCheckpoint.Phase?, message: String)
        /// The account is gone and the session has been signed out. The
        /// only stage that may say so.
        case deleted
    }

    private let coordinator: AccountDeletionCoordinator

    private(set) var stage: Stage = .dormant

    /// The link this device is being asked to accept. Held out of
    /// observation: it carries a live capability and must never reach a
    /// view, a log, or a diagnostic dump.
    @ObservationIgnored private var pendingHandoff: AccountDeletionHandoffLink?

    /// True between starting an acceptance and proving it landed. While it
    /// is set, `pendingHandoff` is the only thing that can finish the
    /// transfer, so Retry must re-present the token rather than resume.
    @ObservationIgnored private var acceptanceUnfinished = false

    init(coordinator: AccountDeletionCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - What the screen shows

    /// The durable record driving the display, if there is one.
    var checkpoint: AccountDeletionCheckpoint? { coordinator.checkpoint }

    /// The ordered step list, or `nil` when there is nothing under way.
    var steps: [AccountDeletionFlowCopy.Step]? {
        guard let checkpoint else { return nil }
        return AccountDeletionFlowCopy.steps(role: checkpoint.role,
                                             phase: checkpoint.phase,
                                             waiting: isWaiting)
    }

    /// One line naming what is happening, always derived from the durable
    /// phase so a relaunch says the same thing this session did.
    var statusLine: String {
        switch stage {
        case .dormant:
            return ""
        case .confirming:
            return "This permanently deletes your account and everything in it."
        case .working(let phase):
            guard let checkpoint, let phase else { return "Working…" }
            return AccountDeletionFlowCopy.activeTitle(
                role: checkpoint.role, phase: phase, waiting: false) ?? "Working…"
        case .waiting(let phase):
            guard let checkpoint else { return "Waiting…" }
            return AccountDeletionFlowCopy.waitingDetail(role: checkpoint.role, phase: phase)
                ?? AccountDeletionFlowCopy.activeTitle(
                    role: checkpoint.role, phase: phase, waiting: true)
                ?? "Waiting…"
        case .signInRequired:
            return "Sign in to Seedkeep to take over this garden."
        case .handoffOffered:
            return "You've been asked to take over this shared garden."
        case .handoffRefused(let message):
            return message
        case .handoffComplete:
            return "The garden is yours. Your own account is untouched."
        case .cancelled:
            return "Deletion cancelled. Nothing was removed."
        case .failed(_, let message):
            return message
        case .deleted:
            return "Your account and its garden have been deleted."
        }
    }

    /// True only once BOTH the CloudKit work and the server deletion have
    /// completed. Nothing else in this type may report completion.
    var isComplete: Bool { stage == .deleted }

    /// Retry is a response to a failure and nothing else. A flow that is
    /// merely waiting on another device has nothing to retry — that is
    /// `canCheckAgain`.
    var canRetry: Bool {
        if case .failed = stage { return true }
        return false
    }

    /// Poll the other device. The coordinator never polls on its own, so a
    /// successor sitting at `destinationReady` while the owner copies —
    /// and an owner waiting on the successor's verification — need a way
    /// to ask again that is not an error-recovery affordance.
    var canCheckAgain: Bool {
        if case .waiting = stage { return true }
        return false
    }

    /// Cancel is legal only for a departing SHARED OWNER, and only while
    /// the original garden is still there.
    ///
    /// Deliberately not offered to a participant or solo owner: their
    /// checkpoint is written before the irreversible CloudKit step and
    /// stays put if that step lands but its verification does not, so
    /// "nothing has happened yet" and "the share is already left" look
    /// identical from here. Offering Cancel there would throw away the
    /// only resumable record and then tell the user nothing was removed.
    /// A successor has no deletion of their own to abandon.
    var canCancel: Bool {
        guard let checkpoint else { return false }
        guard checkpoint.role == .sharedOwner, !checkpoint.phase.sourceIsGone else { return false }
        if case .working = stage { return false }
        return true
    }

    /// True when this device is part-way through receiving somebody else's
    /// garden. Lets the app root offer a token-free way back into a
    /// handoff whose single-use link has already been spent.
    var hasHandoffInProgress: Bool { checkpoint?.role == .successor }

    /// The shareable handoff link, or `nil`.
    ///
    /// Guarded four ways on purpose: only a shared owner, only while a
    /// successor has yet to accept, only when this process actually holds
    /// the raw token, and only while that token is still live. The token
    /// is a capability to take the garden, so anything less would put it
    /// on the wrong screen — or hand out a link the server will reject.
    var handoffLink: URL? {
        guard let checkpoint,
              checkpoint.role == .sharedOwner,
              checkpoint.phase == .transferPending,
              let handoff = coordinator.liveHandoff,
              handoff.transferID == checkpoint.transferID else { return nil }
        return AccountDeletionHandoffLink(transferID: handoff.transferID,
                                          token: handoff.token).universalLink
    }

    // MARK: - Actions

    /// Called when the surface appears. Reads the durable record and
    /// nothing else: either there is a deletion to pick up, or there is a
    /// question to ask.
    func prepare() async {
        if pendingHandoff != nil {
            await resolvePendingHandoff()
            return
        }
        do {
            guard try coordinator.refreshCheckpoint() != nil else {
                stage = .confirming
                return
            }
        } catch {
            stage = .failed(phase: nil, message: humanizeDeletionError(error))
            return
        }
        await drive { try await self.coordinator.resume() }
    }

    /// Re-read the durable record without doing any external work. Lets a
    /// view that was handed a coordinator mid-flow render the right
    /// affordances before anything is driven.
    func reload() {
        _ = try? coordinator.refreshCheckpoint()
    }

    /// The You ▸ Delete account button, as behaviour rather than as view
    /// code.
    ///
    /// It reads the durable record and does nothing else — no CloudKit, no
    /// server, no checkpoint write. Tapping the button is not consent, and
    /// a person who opens this and changes their mind must leave no trace.
    /// The button body is one call to this method so that everything the
    /// tap can do is reachable from a test; a SwiftUI body is not.
    func presentFromYou() {
        reload()
        stage = checkpoint == nil ? .confirming : .working(checkpoint?.phase)
    }

    /// The user said yes at the confirmation.
    func confirm() async {
        await drive { try await self.coordinator.start() }
    }

    /// Re-attempt whatever failed.
    ///
    /// Acceptance is special: if the accept call is what failed, the
    /// server may have bound this device as successor and lost the reply.
    /// There is no checkpoint to resume in that case, so a generic
    /// `resume()` would return `.idle` and quietly abandon a transfer that
    /// is already half-committed. Re-presenting the retained token to the
    /// idempotent accept route is the only thing that recovers it.
    func retry() async {
        if acceptanceUnfinished, let link = pendingHandoff {
            await performAcceptance(link)
            return
        }
        await drive { try await self.coordinator.resume() }
    }

    /// Ask the other device's half of the transfer for news. Same
    /// idempotent resume as `retry`, offered for a different reason.
    func checkAgain() async {
        await drive { try await self.coordinator.resume() }
    }

    /// Whichever of the two is legal right now — used by surfaces that
    /// show a single "get this moving again" affordance.
    func retryOrRefresh() async {
        if canRetry { await retry() } else { await checkAgain() }
    }

    /// Abandon the deletion. Refused by the coordinator once the original
    /// garden is gone; the refusal is surfaced rather than swallowed,
    /// because at that point the deletion genuinely has to finish.
    func cancel() async {
        do {
            try await coordinator.cancel()
            stage = .cancelled
        } catch {
            stage = .failed(phase: coordinator.checkpoint?.phase, message: humanizeDeletionError(error))
        }
    }

    /// Return the surface to its resting state after the user dismisses a
    /// finished or refused flow.
    func dismiss() {
        pendingHandoff = nil
        stage = .dormant
    }

    // MARK: - Successor handoff

    /// A handoff link was opened. Looks, and only looks.
    func open(_ link: AccountDeletionHandoffLink) async {
        pendingHandoff = link
        await resolvePendingHandoff()
    }

    /// The user consented to take the garden. This is the call that spends
    /// the single-use token.
    func acceptOffer() async {
        guard case .handoffOffered = stage, let link = pendingHandoff else { return }
        await performAcceptance(link)
    }

    /// Runs the accept and decides whether the link may finally be
    /// forgotten. It may not be forgotten just because the call returned:
    /// only a durable successor checkpoint, or a terminal outcome, proves
    /// the token is no longer the one thing that can finish this.
    private func performAcceptance(_ link: AccountDeletionHandoffLink) async {
        acceptanceUnfinished = true
        await drive {
            try await self.coordinator.acceptHandoff(transferID: link.transferID,
                                                     token: link.token)
        }
        if coordinator.checkpoint?.role == .successor || stageIsTerminal {
            pendingHandoff = nil
            acceptanceUnfinished = false
        }
    }

    /// Decline without spending anything. The link stays valid for whoever
    /// it was meant for.
    func declineOffer() {
        pendingHandoff = nil
        stage = .dormant
    }

    private func resolvePendingHandoff() async {
        guard let link = pendingHandoff else { return }

        // A handoff this device already accepted has no token left to
        // inspect — the accept consumed it. Resuming is the only correct
        // answer, and asking the server to inspect a spent token would
        // turn a recoverable crash into a refusal.
        if let existing = try? coordinator.refreshCheckpoint(),
           existing.role == .successor,
           existing.transferID == link.transferID {
            pendingHandoff = nil
            await drive { try await self.coordinator.resume() }
            return
        }

        stage = .working(nil)
        do {
            stage = .handoffOffered(
                try await coordinator.previewHandoff(transferID: link.transferID,
                                                     token: link.token))
        } catch AccountDeletionCoordinatorError.notSignedIn {
            // Held, not spent: the link stays pending so signing in
            // finishes what tapping it started.
            stage = .signInRequired
        } catch AccountDeletionCoordinatorError.handoffExpired {
            // An expired PREVIEW is ambiguous on purpose: inspection
            // cannot tell "nobody ever used this" from "somebody used it,
            // days ago, and the reply never arrived" — only `/accept`'s
            // idempotent replay can, because the server keeps honouring a
            // BOUND successor past the token's expiry. Refusing here on
            // inspection's answer would strand exactly the person this
            // exists for, so an expired preview is a reason to try the
            // real thing, not a reason to stop. If the replay ALSO fails —
            // this device was never the bound party — that failure is a
            // refusal (the offer is dead), not a retryable working step.
            await recoverFromExpiredPreview(link)
        } catch {
            pendingHandoff = nil
            stage = .handoffRefused(humanizeDeletionError(error))
        }
    }

    // MARK: - Driving

    /// Runs the accept replay that an expired preview's ambiguity calls
    /// for, entirely separately from `performAcceptance`. The distinction
    /// matters for what a subsequent failure means: `performAcceptance`
    /// (via `retry()`) is recovering a step that is known to be in
    /// progress, so its failure stays `.failed` and retryable. Here there
    /// is no such guarantee — the preview never confirmed there is
    /// anything to recover — so a failed replay is a dead offer, reported
    /// as `.handoffRefused` rather than offered another retry.
    private func recoverFromExpiredPreview(_ link: AccountDeletionHandoffLink) async {
        acceptanceUnfinished = true
        stage = .working(nil)
        do {
            let outcome = try await coordinator.acceptHandoff(transferID: link.transferID,
                                                              token: link.token)
            pendingHandoff = nil
            acceptanceUnfinished = false
            apply(outcome)
        } catch {
            pendingHandoff = nil
            acceptanceUnfinished = false
            stage = .handoffRefused(humanizeDeletionError(error))
        }
    }

    private func drive(
        _ operation: @MainActor () async throws -> AccountDeletionCoordinator.Outcome
    ) async {
        stage = .working(coordinator.checkpoint?.phase)
        do {
            apply(try await operation())
        } catch {
            // The checkpoint records which step failed; prefer it over the
            // phase we happened to start from.
            let failed = coordinator.checkpoint?.lastFailure?.phase ?? coordinator.checkpoint?.phase
            stage = .failed(phase: failed, message: humanizeDeletionError(error))
        }
    }

    private func apply(_ outcome: AccountDeletionCoordinator.Outcome) {
        switch outcome {
        case .idle:
            // The transfer was withdrawn from elsewhere before anything
            // irreversible happened, so there is nothing left to show.
            stage = coordinator.checkpoint == nil ? .cancelled : .confirming
        case .waiting(let phase):
            stage = .waiting(phase)
        case .handoffComplete:
            stage = .handoffComplete
        case .deleted:
            stage = .deleted
        }
    }

    private var isWaiting: Bool {
        if case .waiting = stage { return true }
        return false
    }

    /// A stage nothing else follows. An acceptance that reaches one of
    /// these has no further use for the token.
    private var stageIsTerminal: Bool {
        switch stage {
        case .deleted, .handoffComplete, .cancelled, .handoffRefused: return true
        default: return false
        }
    }
}
