#if canImport(CloudKit)
import CloudKit

/// One-shot hand-off for a CKShare.Metadata captured by `ShareSceneDelegate` before `AppEnvironment`
/// is ready to act on it. Cold launch deposits in `scene(willConnectTo:)`; warm tap deposits +
/// immediately processes. `AppEnvironment` drains it on launch + on `userDidAcceptCloudKitShareWith`.
/// Ported from SimmerSmith's PendingShareInbox.
@MainActor
final class PendingShareInbox {
    static let shared = PendingShareInbox()
    private var metadata: CKShare.Metadata?

    func deposit(_ metadata: CKShare.Metadata) { self.metadata = metadata }
    func take() -> CKShare.Metadata? { defer { metadata = nil }; return metadata }
}
#endif
