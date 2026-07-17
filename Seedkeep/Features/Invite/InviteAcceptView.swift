import SwiftUI
import SeedkeepKit

/// Sheet that's auto-presented when a `seedkeep://invite/<code>` URL or the
/// `applinks:seedkeep.app` universal link is opened. Server household invitations are retired
/// (2026-07-13 "CKShare is the sole R1 invitation model" ADR) — CKShare is the only sharing model,
/// so this no longer calls any accept endpoint; it just tells the user sharing moved to iCloud.
struct InviteAcceptView: View {
    @Environment(\.dismiss) private var dismiss

    /// Kept so the existing deep-link plumbing (the sheet in `SeedkeepApp`, fed by
    /// `InviteURLRouter`) doesn't need to change — the code itself is no longer used.
    let code: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                InviteRetirementNotice()
                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationTitle("Household invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Retired-capability notice, in the idiom of `AssistantView.restrictedState`: SF Symbol + display
/// title + italic body. Shared by the signed-in (`InviteAcceptView`) and signed-out
/// (`SeedkeepApp.signedOutInviteView`) deep-link landings so an old invite link always lands
/// somewhere deliberate instead of a dead accept flow.
struct InviteRetirementNotice: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.slash")
                .font(.system(size: 36))
                .foregroundStyle(HerbColor.sepia.opacity(0.65))
            Text("Household invites have moved")
                .font(HerbFont.display(size: 22))
                .foregroundStyle(HerbColor.ink)
                .multilineTextAlignment(.center)
            Text(FeatureFlags.legacyInviteRetirementMessage)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Routes `seedkeep://invite/<code>` and `https://seedkeep.app/invite/<code>`
/// to an invite code, or returns `nil` for anything else.
enum InviteURLRouter {
    static func invitationCode(from url: URL) -> String? {
        // Custom scheme: seedkeep://invite/<code> or seedkeep://invite?code=<code>
        if url.scheme == "seedkeep", url.host == "invite" {
            if let code = url.pathComponents.dropFirst().first, !code.isEmpty {
                return code
            }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "code" })?
                .value
        }
        // Universal link: https://seedkeep.app/invite/<code>
        if url.scheme == "https", url.host == "seedkeep.app",
           url.pathComponents.count >= 3, url.pathComponents[1] == "invite" {
            return url.pathComponents[2]
        }
        return nil
    }
}
