/// One-slot pending-share storage, generic so the deposit bookkeeping is testable without
/// `CKShare.Metadata`. Each deposit records whether it arrived under a resolved identity
/// (`.signedIn`): only those belong to that user and go on a different-user wipe. A share the
/// system delivered on a cold launch, before the identity resolved, is kept for whoever resolves.
@MainActor
final class PendingShareSlot<Element> {
    private var stored: (element: Element, underResolvedIdentity: Bool)?

    var isEmpty: Bool { stored == nil }

    func deposit(_ element: Element, underResolvedIdentity: Bool) {
        stored = (element, underResolvedIdentity)
    }
    func take() -> Element? { defer { stored = nil }; return stored?.element }
    /// N1: a different iCloud user must never adopt the previous user's pending share.
    func removeResolvedDeposits() {
        if stored?.underResolvedIdentity == true { stored = nil }
    }
}

#if canImport(CloudKit)
import CloudKit

/// One-shot hand-off for a CKShare.Metadata captured by `ShareSceneDelegate` before `AppEnvironment`
/// is ready to act on it. Cold launch deposits in `scene(willConnectTo:)`; warm tap deposits +
/// immediately processes. `AppEnvironment` drains it on launch + on `userDidAcceptCloudKitShareWith`.
/// Ported from SimmerSmith's PendingShareInbox.
@MainActor
final class PendingShareInbox {
    static let shared = PendingShareInbox()
    private let slot = PendingShareSlot<CKShare.Metadata>()

    func deposit(_ metadata: CKShare.Metadata, underResolvedIdentity: Bool) {
        slot.deposit(metadata, underResolvedIdentity: underResolvedIdentity)
    }
    func take() -> CKShare.Metadata? { slot.take() }
    /// N1: a different iCloud user must never adopt the previous user's pending share; one that
    /// arrived before any identity resolved stays.
    func removeResolvedDeposits() { slot.removeResolvedDeposits() }
}
#endif
