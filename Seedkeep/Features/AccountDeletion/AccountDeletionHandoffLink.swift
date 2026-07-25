import CryptoKit
import Foundation

/// The universal link a departing owner sends to the person taking over
/// their shared garden.
///
/// The server never builds this URL — it hands back a transfer id and a
/// raw single-use token and holds only the token's hash
/// (`.docs/ai/phases/2026-07-23-cloudkit-account-deletion-spec.md`
/// § "Security and expiry"). The link shape is therefore entirely the
/// client's, and both halves of it live here so that minting and parsing
/// cannot drift apart: a link the app builds is by construction a link the
/// app can read back.
///
/// The token is a capability. It is carried in the query rather than the
/// path so it never lands in a path-shaped analytics key, and it is never
/// written to the checkpoint file, never logged, and never rendered
/// anywhere but the departing owner's own share sheet.
struct AccountDeletionHandoffLink: Equatable, Hashable, Identifiable, Sendable {
    let transferID: String
    let token: String

    /// An opaque fingerprint of the WHOLE link, transfer and token both.
    ///
    /// SwiftUI presents by identity: `.sheet(item:)` keeps the sheet it
    /// already has when the id is unchanged, and `.task(id:)` does not
    /// re-run. An owner may reissue a link without the transfer changing —
    /// rotation mints a new token against the same id — so identity keyed
    /// on the transfer alone would silently keep showing the dead token
    /// and never re-inspect. Hashing both makes a reissued link a
    /// different thing to present, which is what it is.
    ///
    /// It is a SHA-256, not the token, because an id ends up in view
    /// hierarchies, diagnostics and crash reports, and the token is a
    /// capability to take somebody's garden.
    var id: String {
        let digest = SHA256.hash(data: Data("\(transferID)\n\(token)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Distinct from `invite` so an old invite link and a handoff link can
    /// never be mistaken for one another by either router.
    static let pathSegment = "garden-handoff"
    static let host = "seedkeep.app"
    static let customScheme = "seedkeep"
    private static let tokenQueryItem = "token"

    init(transferID: String, token: String) {
        self.transferID = transferID
        self.token = token
    }

    /// Parses `https://seedkeep.app/garden-handoff/<id>?token=<token>` and
    /// the development-only `seedkeep://garden-handoff/<id>?token=<token>`.
    /// Anything else — including a handoff-shaped URL on a host we do not
    /// own — is `nil`.
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let transferID: String
        switch components.scheme {
        case "https" where components.host == Self.host:
            // ["/", "garden-handoff", "<id>"]
            let path = url.pathComponents
            guard path.count >= 3, path[1] == Self.pathSegment else { return nil }
            transferID = path[2]
        case Self.customScheme where url.host == Self.pathSegment:
            guard let first = url.pathComponents.dropFirst().first else { return nil }
            transferID = first
        default:
            return nil
        }
        guard !transferID.isEmpty,
              let token = components.queryItems?
                .first(where: { $0.name == Self.tokenQueryItem })?.value,
              !token.isEmpty else { return nil }
        self.transferID = transferID
        self.token = token
    }

    /// The link to hand to the successor. Owner-only: showing this to
    /// anyone else hands them the garden.
    var universalLink: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/\(Self.pathSegment)/\(transferID)"
        components.queryItems = [URLQueryItem(name: Self.tokenQueryItem, value: token)]
        // The transfer id is a nanoid and the token is base64url, so both
        // are already URL-safe; the fallback exists so a future id format
        // cannot silently produce a link that will not parse.
        return components.url ?? URL(string: "https://\(Self.host)/\(Self.pathSegment)")!
    }
}

/// What an incoming URL means to the app.
///
/// Both deep-link entry points — SwiftUI's `onOpenURL` /
/// `onContinueUserActivity` and `ShareSceneDelegate`, which replaces
/// SwiftUI's scene delegate and can suppress them — route through this one
/// type. Two call sites parsing URLs independently is how a link ends up
/// being handled twice, or by the wrong flow.
enum IncomingLink: Equatable {
    /// A retired household invite. Still routed so an old link lands on a
    /// deliberate notice rather than dead-ending.
    case invite(code: String)
    /// A shared-garden handoff from an owner deleting their account.
    case gardenHandoff(AccountDeletionHandoffLink)

    init?(url: URL) {
        // Handoff first. It is the live capability, and an invite link
        // cannot be handoff-shaped, so this ordering costs nothing and
        // guarantees a handoff is never swallowed by the retired flow.
        if let handoff = AccountDeletionHandoffLink(url: url) {
            self = .gardenHandoff(handoff)
        } else if let code = InviteURLRouter.invitationCode(from: url) {
            self = .invite(code: code)
        } else {
            return nil
        }
    }
}

/// What the app root should be presenting for a garden handoff.
///
/// Extracted from the view because the decision is the interesting part
/// and a SwiftUI body is not reachable from a test. Two rules it exists to
/// enforce:
///
///   1. **Never present over the sign-in screen.** A modal on top of
///      `SignInView` makes the very sign-in the link is waiting for
///      unreachable, and the only way out of it — dismissal — throws the
///      capability away. A link that arrives signed out is HELD by the
///      caller and presented the moment authentication lands.
///   2. **A spent link is not the only way back in.** Acceptance consumes
///      the token, so a successor who relaunches mid-handoff has nothing
///      to tap. A durable successor checkpoint therefore opens the same
///      surface with no token at all.
enum AccountDeletionRootRoute: Equatable {
    /// A freshly opened link, ready to be inspected.
    case acceptHandoff(AccountDeletionHandoffLink)
    /// A handoff already accepted on this device, resumed from disk.
    case resumeHandoff
    /// Nothing to present. A pending link is still held by the caller.
    case none

    /// The route as a `.sheet(item:)` value. `nil` for `.none`.
    struct Presentation: Identifiable, Equatable {
        /// `nil` means resume a handoff already accepted on this device;
        /// its single-use token is long gone and is not needed.
        let link: AccountDeletionHandoffLink?
        /// The id `.link == nil` presents as. Named so a dismissal
        /// handler can recognise it without constructing a `Presentation`.
        static let resumeID = "resume"
        /// Keyed on the link's fingerprint, so a reissued token presents
        /// as the new thing it is rather than reusing the live sheet.
        var id: String { link?.id ?? Self.resumeID }
    }

    var presentation: Presentation? {
        switch self {
        case .acceptHandoff(let link): return Presentation(link: link)
        case .resumeHandoff: return Presentation(link: nil)
        case .none: return nil
        }
    }

    static func decide(
        pendingLink: AccountDeletionHandoffLink?,
        isSignedIn: Bool,
        hasHandoffInProgress: Bool
    ) -> AccountDeletionRootRoute {
        guard isSignedIn else { return .none }
        if let pendingLink { return .acceptHandoff(pendingLink) }
        return hasHandoffInProgress ? .resumeHandoff : .none
    }
}

/// Whether dismissing the sheet identified by `dismissedID` should discard
/// `pendingLink`.
///
/// It should not when a newer link has already replaced the one being
/// dismissed: a rotated token can arrive while the old sheet is on screen,
/// and clearing on a stale dismissal would throw away the capability the
/// user just tapped.
extension AccountDeletionRootRoute {
    static func dismissalClearsPendingLink(
        dismissedID: String?,
        pendingLink: AccountDeletionHandoffLink?
    ) -> Bool {
        guard let dismissedID, let pendingLink else { return false }
        return dismissedID == pendingLink.id
    }
}
