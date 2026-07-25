import SwiftUI
import SeedkeepKit

/// The screen a handoff link lands on: someone is leaving Seedkeep and has
/// asked this person to take their shared garden.
///
/// The order here is the whole point. The link carries a single-use token
/// that irreversibly binds a successor, so the flow is look → decide →
/// spend, never tap → spend. `AccountDeletionFlowModel.open(_:)` performs
/// only the non-consuming inspection and the local proof that this device
/// actually participates in the named garden; the token is not presented
/// for acceptance until the user taps Accept. A person who opens somebody
/// else's link, or who is not signed in, therefore leaves it worth exactly
/// as much as they found it.
struct AccountDeletionHandoffAcceptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthController.self) private var auth
    @Bindable var model: AccountDeletionFlowModel
    let link: AccountDeletionHandoffLink

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        ScholarRule(verticalMargin: 4)
                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.declineOffer()
                        dismiss()
                    }
                    .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .task { await model.open(link) }
            // Signing in is what the deferral was waiting for: re-run the
            // inspection the moment there is an identity to inspect with.
            .onChange(of: isSignedIn) { _, signedIn in
                guard signedIn, model.stage == .signInRequired else { return }
                Task { await model.open(link) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rubric(text: "a garden offered")
            Text("Take over this garden")
                .font(HerbFont.display(size: 28))
                .foregroundStyle(HerbColor.ink)
            Text(model.statusLine)
                .font(HerbFont.bodyItalic(size: 13))
                .foregroundStyle(HerbColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .signInRequired:
            notice(symbol: "person.crop.circle.badge.questionmark",
                   title: "Sign in first",
                   body: """
                   Sign in to the Seedkeep account that already shares this garden, then open \
                   the link again. Nothing has been used up.
                   """)

        case .handoffOffered(let preview):
            offer(preview)

        case .handoffRefused(let message):
            notice(symbol: "hand.raised",
                   title: "This link isn't for this account",
                   body: message)

        case .handoffComplete:
            notice(symbol: "leaf",
                   title: "The garden is yours",
                   body: """
                   Everything has been copied into a garden you own. The previous owner's \
                   account can now be deleted; yours is untouched.
                   """)

        default:
            progress
        }
    }

    private func offer(_ preview: AccountDeletionCoordinator.HandoffPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("""
            The owner of the garden you share is deleting their account. If you accept, a copy \
            of the whole garden is made in your own iCloud and you become its owner.
            """)
            .font(HerbFont.body(size: 14))
            .foregroundStyle(HerbColor.ink)
            .fixedSize(horizontal: false, vertical: true)

            Text("""
            Your own Seedkeep account is not affected. Nothing has been accepted yet — this \
            link is still unused.
            """)
            .font(HerbFont.bodyItalic(size: 12))
            .foregroundStyle(HerbColor.inkSoft)
            .fixedSize(horizontal: false, vertical: true)

            Text("Offer expires \(Self.expiry.string(from: Date(timeIntervalSince1970: Double(preview.expiresAt) / 1000)))")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)

            Button {
                Task { await model.acceptOffer() }
            } label: {
                Text("Accept the garden").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerbColor.sage)

            Button(role: .cancel) {
                model.declineOffer()
                dismiss()
            } label: {
                Text("Not now").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let steps = model.steps {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: symbol(for: step.state))
                                .font(.system(size: 14))
                                .foregroundStyle(tint(for: step.state))
                            Text(step.title)
                                .font(step.state == .active
                                      ? HerbFont.bodyEmph(size: 14) : HerbFont.body(size: 14))
                                .foregroundStyle(step.state == .upcoming
                                                 ? HerbColor.inkFaint : HerbColor.ink)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                ProgressView().herbProgressStyle()
            }

            if model.canRetry {
                Button {
                    Task { await model.retry() }
                } label: {
                    Text("Retry").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HerbColor.sepia)
            }
        }
    }

    private func notice(symbol: String, title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(HerbColor.sepia.opacity(0.65))
            Text(title)
                .font(HerbFont.display(size: 22))
                .foregroundStyle(HerbColor.ink)
                .multilineTextAlignment(.center)
            Text(body)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Small readers

    private static let expiry: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var isSignedIn: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    private var isWorking: Bool {
        if case .working = model.stage { return true }
        return false
    }

    private func symbol(for state: AccountDeletionFlowCopy.Step.State) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .active: return "circle.dotted"
        case .upcoming: return "circle"
        }
    }

    private func tint(for state: AccountDeletionFlowCopy.Step.State) -> Color {
        switch state {
        case .done: return HerbColor.sage
        case .active: return HerbColor.sepia
        case .upcoming: return HerbColor.inkFaint
        }
    }
}
