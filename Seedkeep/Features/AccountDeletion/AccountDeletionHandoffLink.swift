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

    /// The transfer is the identity: two links for the same transfer are
    /// the same offer even when a rotation changed the token.
    var id: String { transferID }

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
