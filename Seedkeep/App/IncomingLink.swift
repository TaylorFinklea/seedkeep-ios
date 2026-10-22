import Foundation

/// What an incoming URL means to the app.
///
/// Both deep-link entry points — SwiftUI's `onOpenURL` /
/// `onContinueUserActivity` and `ShareSceneDelegate`, which replaces
/// SwiftUI's scene delegate and can suppress them — route through this one
/// type, so a link is never handled twice or by the wrong flow.
///
/// N3: garden handoff links (`/garden-handoff`) belonged to the removed
/// account deletion and are no longer recognised; they route nowhere.
enum IncomingLink: Equatable {
    /// A retired household invite. Still routed so an old link lands on a
    /// deliberate notice rather than dead-ending.
    case invite(code: String)

    init?(url: URL) {
        guard let code = InviteURLRouter.invitationCode(from: url) else { return nil }
        self = .invite(code: code)
    }
}
