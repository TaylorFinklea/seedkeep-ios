import SwiftUI
import SeedkeepKit

/// You ▸ Delete account, as a resumable progress flow rather than a button
/// that deletes.
///
/// The screen is a rendering of `AccountDeletionFlowModel.stage` and
/// nothing else: it holds no state of its own about what has happened, so
/// a relaunch mid-deletion draws exactly what this session drew. Every
/// affordance it offers — Retry, Cancel, the handoff link — is gated by
/// the model on the durable phase, so the view cannot present a button the
/// coordinator would refuse.
struct AccountDeletionFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountDeletionFlowModel

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
                    // "Close" only ever dismisses the sheet. Abandoning the
                    // deletion is the explicit Cancel below, because the
                    // two mean opposite things once a transfer exists.
                    Button(closeTitle) { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .task { await model.prepare() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rubric(text: "closing the book")
            Text("Delete account")
                .font(HerbFont.display(size: 30))
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
        case .dormant, .confirming:
            confirmation
        case .deleted:
            finished(symbol: "checkmark.seal",
                     title: "Account deleted",
                     body: "Your account, your iCloud garden, and everything on this device are gone.")
        case .cancelled:
            finished(symbol: "arrow.uturn.backward",
                     title: "Nothing was deleted",
                     body: "Your account and garden are exactly as they were.")
        case .handoffComplete:
            finished(symbol: "leaf",
                     title: "Garden received",
                     body: "The shared garden is yours now. Your own account is untouched.")
        default:
            progress
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("""
            This permanently deletes your account and all of your household's library, garden, \
            and journal data. It can't be undone.
            """)
            .font(HerbFont.body(size: 14))
            .foregroundStyle(HerbColor.ink)
            .fixedSize(horizontal: false, vertical: true)

            Text("""
            If you share your garden with other people, you'll be asked to hand it to one of \
            them first — nothing is deleted until they've taken it.
            """)
            .font(HerbFont.bodyItalic(size: 12))
            .foregroundStyle(HerbColor.inkSoft)
            .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                Task { await model.confirm() }
            } label: {
                Text("Delete my account")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerbColor.rose)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let steps = model.steps {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { step in
                        stepRow(step)
                    }
                }
            } else if isWorking {
                ProgressView()
                    .herbProgressStyle()
            }

            if case .failed(let phase, let message) = model.stage {
                failureNotice(phase: phase, message: message)
            }

            if let link = model.handoffLink {
                handoffCard(link: link)
            }

            actions
        }
    }

    private func stepRow(_ step: AccountDeletionFlowCopy.Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch step.state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(HerbColor.sage)
                case .active:
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(HerbColor.sepia)
                case .upcoming:
                    Image(systemName: "circle")
                        .foregroundStyle(HerbColor.inkFaint)
                }
            }
            .font(.system(size: 14))

            Text(step.title)
                .font(step.state == .active ? HerbFont.bodyEmph(size: 14) : HerbFont.body(size: 14))
                .foregroundStyle(step.state == .upcoming ? HerbColor.inkFaint : HerbColor.ink)

            if step.state == .active, isWorking {
                ProgressView()
                    .controlSize(.small)
                    .herbProgressStyle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(accessibilityState(step.state))")
    }

    private func failureNotice(phase: AccountDeletionCheckpoint.Phase?, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let phase, let checkpoint = model.checkpoint,
               let title = AccountDeletionFlowCopy.activeTitle(
                role: checkpoint.role, phase: phase, waiting: false) {
                Text("Stopped at: \(title)")
                    .font(HerbFont.bodyEmph(size: 13))
                    .foregroundStyle(HerbColor.rose)
            }
            Text(message)
                .font(HerbFont.body(size: 13))
                .foregroundStyle(HerbColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerbColor.vellumLo, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The one place a live handoff token is ever rendered. `model`
    /// restricts it to the departing owner while the transfer is still
    /// waiting for anybody to accept.
    private func handoffCard(link: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rubric(text: "the handoff")
            Text("""
            Send this link to the person taking over the garden. It works once, and only for \
            someone already sharing this garden.
            """)
            .font(HerbFont.bodyItalic(size: 12))
            .foregroundStyle(HerbColor.inkSoft)
            .fixedSize(horizontal: false, vertical: true)

            ShareLink(item: link) {
                Label("Send handoff link", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerbColor.sepia)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerbColor.vellumHi, in: RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if model.canRetry {
                Button {
                    Task { await model.retry() }
                } label: {
                    Text("Retry").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HerbColor.sepia)
            }
            if model.canCancel {
                Button(role: .destructive) {
                    Task { await model.cancel() }
                } label: {
                    Text("Cancel deletion").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func finished(symbol: String, title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(HerbColor.sepia.opacity(0.65))
            Text(title)
                .font(HerbFont.display(size: 22))
                .foregroundStyle(HerbColor.ink)
            Text(body)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
            Button("Done") {
                model.dismiss()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Small readers

    private var isWorking: Bool {
        if case .working = model.stage { return true }
        return false
    }

    private var closeTitle: String {
        switch model.stage {
        case .dormant, .confirming: return "Cancel"
        default: return "Close"
        }
    }

    private func accessibilityState(_ state: AccountDeletionFlowCopy.Step.State) -> String {
        switch state {
        case .done: return "done"
        case .active: return "in progress"
        case .upcoming: return "not started"
        }
    }
}
