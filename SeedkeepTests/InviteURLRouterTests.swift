import Testing
import Foundation
@testable import Seedkeep

/// Pure-function tests for `InviteURLRouter.invitationCode(from:)`.
///
/// No mocks needed — the function takes a `URL` and returns `String?`.
///
/// Parser shape (from InviteAcceptView.swift):
///   Custom scheme:  seedkeep://invite/<code>     host="invite", path component
///                   seedkeep://invite?code=<code> host="invite", query param
///   Universal link: https://seedkeep.app/invite/<code>  pathComponents[1]=="invite"
@Suite("InviteURLRouter — URL parsing")
struct InviteURLRouterTests {

    // MARK: - Custom scheme: path component

    @Test("seedkeep://invite/<code> returns the code")
    func customSchemePathComponent() {
        let url = URL(string: "seedkeep://invite/abc123")!
        #expect(InviteURLRouter.invitationCode(from: url) == "abc123")
    }

    @Test("seedkeep://invite/<code> preserves mixed-case and hyphens")
    func customSchemePathPreservesCase() {
        let url = URL(string: "seedkeep://invite/Xk9-Hello-World")!
        #expect(InviteURLRouter.invitationCode(from: url) == "Xk9-Hello-World")
    }

    // MARK: - Custom scheme: query parameter

    @Test("seedkeep://invite?code=<code> returns the code from query string")
    func customSchemeQueryParam() {
        let url = URL(string: "seedkeep://invite?code=qpcode42")!
        #expect(InviteURLRouter.invitationCode(from: url) == "qpcode42")
    }

    // MARK: - Universal link

    @Test("https://seedkeep.app/invite/<code> returns the code")
    func universalLinkPathComponent() {
        let url = URL(string: "https://seedkeep.app/invite/univCode99")!
        #expect(InviteURLRouter.invitationCode(from: url) == "univCode99")
    }

    @Test("https://seedkeep.app/invite/<code> preserves hyphens and underscores")
    func universalLinkPreservesFormat() {
        let url = URL(string: "https://seedkeep.app/invite/invite_code-2024")!
        #expect(InviteURLRouter.invitationCode(from: url) == "invite_code-2024")
    }

    // MARK: - Negative cases

    @Test("wrong custom scheme returns nil")
    func wrongScheme() {
        let url = URL(string: "seedkeeper://invite/abc")!
        #expect(InviteURLRouter.invitationCode(from: url) == nil)
    }

    @Test("wrong host on seedkeep scheme returns nil")
    func wrongHost() {
        let url = URL(string: "seedkeep://join/abc")!
        #expect(InviteURLRouter.invitationCode(from: url) == nil)
    }

    @Test("https on wrong host returns nil")
    func wrongUniversalHost() {
        let url = URL(string: "https://seedkeep.io/invite/abc")!
        #expect(InviteURLRouter.invitationCode(from: url) == nil)
    }

    @Test("universal link with wrong path segment returns nil")
    func universalLinkWrongPath() {
        let url = URL(string: "https://seedkeep.app/join/abc")!
        #expect(InviteURLRouter.invitationCode(from: url) == nil)
    }

    @Test("universal link with no code component returns nil")
    func universalLinkMissingCode() {
        // Only /invite with no further path component — pathComponents.count < 3
        let url = URL(string: "https://seedkeep.app/invite")!
        #expect(InviteURLRouter.invitationCode(from: url) == nil)
    }

    @Test("empty custom scheme path with no query returns nil")
    func emptyCustomSchemePath() {
        // seedkeep://invite with empty path and no query
        let url = URL(string: "seedkeep://invite")!
        #expect(InviteURLRouter.invitationCode(from: url) == nil)
    }

    @Test("http (not https) universal link returns nil")
    func httpUniversalLink() {
        let url = URL(string: "http://seedkeep.app/invite/abc")!
        #expect(InviteURLRouter.invitationCode(from: url) == nil)
    }
}
