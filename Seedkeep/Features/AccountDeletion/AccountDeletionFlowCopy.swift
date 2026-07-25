import Foundation

/// The words a user sees while their account is being deleted, derived
/// from the durable checkpoint rather than from whatever the view happened
/// to be doing.
///
/// This is a pure function of (role, phase, waiting) for one reason: a
/// deletion is resumable, so the screen can be built from a file written
/// by a previous launch with nothing else in memory. Copy that lived in
/// view state would be copy that a relaunch cannot reconstruct — a spinner
/// with no explanation over a garden that may already be half-transferred.
///
/// The step lists come from the spec's UI section
/// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md` § "UI").
/// Every phase the coordinator can resume at maps to exactly one step, and
/// every phase it cannot maps to none — so an unreachable state cannot be
/// papered over with plausible-looking progress.
enum AccountDeletionFlowCopy {

    struct Step: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            /// Behind us, and it actually happened.
            case done
            /// Where the flow is right now.
            case active
            /// Not attempted. Never rendered as achieved.
            case upcoming
        }

        let id: String
        let title: String
        var state: State
    }

    /// Every step of `role`'s flow in order, with the one `phase` is on
    /// marked active. `nil` when the pair is unreachable — the caller has
    /// a checkpoint the state machine could never have produced, and
    /// inventing progress for it would be a lie.
    ///
    /// `waiting` distinguishes the two halves of the departing owner's
    /// first step: minting the link, and holding it out while nobody has
    /// opened it. They are the same durable phase and genuinely different
    /// things to say.
    static func steps(
        role: AccountDeletionCheckpoint.Role,
        phase: AccountDeletionCheckpoint.Phase,
        waiting: Bool
    ) -> [Step]? {
        let plan = self.plan(for: role)
        guard let active = index(of: phase, role: role, waiting: waiting) else { return nil }
        return plan.enumerated().map { offset, step in
            Step(id: step.id,
                 title: step.title,
                 state: offset < active ? .done : (offset == active ? .active : .upcoming))
        }
    }

    /// The title of the step `phase` is on, or `nil` when unreachable.
    static func activeTitle(
        role: AccountDeletionCheckpoint.Role,
        phase: AccountDeletionCheckpoint.Phase,
        waiting: Bool
    ) -> String? {
        steps(role: role, phase: phase, waiting: waiting)?.first { $0.state == .active }?.title
    }

    /// One line under the step list explaining who the flow is waiting on.
    /// Only the phases where the next move belongs to somebody else say
    /// anything; everywhere else the step title is already the whole truth.
    static func waitingDetail(
        role: AccountDeletionCheckpoint.Role,
        phase: AccountDeletionCheckpoint.Phase
    ) -> String? {
        switch (role, phase) {
        case (.sharedOwner, .transferPending):
            return "Send the link below. Nothing is deleted until someone takes the garden."
        case (.sharedOwner, .successorBound):
            return "They've accepted. Their device is preparing a garden to receive yours."
        case (.sharedOwner, .ownerVerified):
            return "Your copy is checked. Waiting for their device to check it too."
        case (.successor, .destinationReady):
            return "Waiting for the current owner to copy their garden across."
        default:
            return nil
        }
    }

    // MARK: - Plans

    private struct PlannedStep {
        let id: String
        let title: String
    }

    private static func plan(for role: AccountDeletionCheckpoint.Role) -> [PlannedStep] {
        switch role {
        case .noCloudKitGarden:
            return [PlannedStep(id: "account", title: "Deleting account")]
        case .participant:
            return [PlannedStep(id: "leave", title: "Leaving shared garden"),
                    PlannedStep(id: "account", title: "Deleting account")]
        case .soloOwner:
            return [PlannedStep(id: "zone", title: "Deleting iCloud garden"),
                    PlannedStep(id: "account", title: "Deleting account")]
        case .sharedOwner:
            return [PlannedStep(id: "invite", title: "Invite a successor"),
                    PlannedStep(id: "acceptance", title: "Waiting for acceptance"),
                    PlannedStep(id: "destination", title: "Preparing successor garden"),
                    PlannedStep(id: "copy", title: "Copying garden"),
                    PlannedStep(id: "verify", title: "Verifying both copies"),
                    PlannedStep(id: "source", title: "Deleting original garden"),
                    PlannedStep(id: "account", title: "Deleting account")]
        case .successor:
            return [PlannedStep(id: "destination", title: "Preparing your garden"),
                    PlannedStep(id: "receive", title: "Receiving the garden"),
                    PlannedStep(id: "verify", title: "Checking the copy"),
                    PlannedStep(id: "adopt", title: "Making it yours")]
        }
    }

    /// The one step `phase` belongs to, or `nil` if `role` can never be at
    /// `phase`. Mirrors the reachable pairs in
    /// `AccountDeletionCoordinator.step(_:)`.
    private static func index(
        of phase: AccountDeletionCheckpoint.Phase,
        role: AccountDeletionCheckpoint.Role,
        waiting: Bool
    ) -> Int? {
        switch role {
        case .noCloudKitGarden:
            return phase == .deletingAccount ? 0 : nil

        case .participant:
            switch phase {
            case .participantLeaving: return 0
            case .deletingAccount: return 1
            default: return nil
            }

        case .soloOwner:
            switch phase {
            case .ownerDeletingZone: return 0
            case .deletingAccount: return 1
            default: return nil
            }

        case .sharedOwner:
            switch phase {
            // Minting the link and holding it out are one durable phase
            // and two honest sentences.
            case .transferPending: return waiting ? 1 : 0
            case .successorBound: return 2
            case .destinationReady, .destinationShareAccepted: return 3
            case .copyComplete, .ownerVerified, .verified: return 4
            case .sourceZoneDeleting, .sourceZoneDeleted, .sourceDeleted: return 5
            case .deletingAccount: return 6
            default: return nil
            }

        case .successor:
            switch phase {
            case .successorBound, .destinationZoneCreated: return 0
            case .destinationReady: return 1
            case .ownerVerified: return 2
            // Server-verified is not the same as this device owning it.
            // The garden is only "yours" once the app has been cut over.
            case .verified, .sourceDeleted, .successorAdopting: return 3
            default: return nil
            }
        }
    }
}
