import SwiftUI

/// N1 entry when the iCloud account holds more than one possible garden. Ambiguity is never
/// resolved by guessing: the user picks. A choice that removes this device's garden asks for
/// confirmation first (`AuthController.choiceDiscardsDeviceData`).
struct GardenChooserView: View {
    @Environment(AuthController.self) private var auth
    let choice: GardenChoice
    @State private var pendingDiscard: GardenZoneSummary?
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WBMetrics.gapLarge) {
                Text(title)
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(WBColor.ink)
                Text(explanation)
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, garden in
                        if index > 0 {
                            Divider().overlay(WBColor.line)
                        }
                        row(garden)
                    }
                }
                .background(WBColor.panel)
                .clipShape(RoundedRectangle(cornerRadius: WBMetrics.radiusPanel))
                .overlay(
                    RoundedRectangle(cornerRadius: WBMetrics.radiusPanel)
                        .stroke(WBColor.line, lineWidth: 1)
                )
                if choice.canKeepDeviceGarden {
                    Button("Keep this device's garden") {
                        run { await auth.keepDeviceGarden() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WBColor.accent)
                    .frame(minHeight: WBMetrics.touchTarget)
                }
                if offersRetry {
                    // Non-destructive: checks iCloud again, e.g. after the garden is shared back.
                    Button("Retry") {
                        run { await auth.retry() }
                    }
                    .buttonStyle(.bordered)
                    .tint(WBColor.accent)
                    .frame(minHeight: WBMetrics.touchTarget)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(WBColor.bg)
        .disabled(isWorking)
        .confirmationDialog(
            "Use this garden?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { garden in
            Button("Remove This Device's Garden", role: .destructive) {
                run { await auth.chooseGarden(garden, discardingDeviceData: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(discardWarning)
        }
    }

    /// The candidates, plus the user's own garden where the choice offers it.
    private var options: [GardenZoneSummary] {
        guard let own = choice.ownGarden, !choice.candidates.contains(own) else { return choice.candidates }
        return [own] + choice.candidates
    }

    private func row(_ garden: GardenZoneSummary) -> some View {
        Button {
            if AuthController.choiceDiscardsDeviceData(choice, garden) {
                pendingDiscard = garden
            } else {
                run { await auth.chooseGarden(garden, discardingDeviceData: false) }
            }
        } label: {
            HStack(spacing: WBMetrics.gapLarge) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(garden.name ?? "Untitled garden")
                        .font(.wbBody)
                        .foregroundStyle(WBColor.ink)
                    Text(subtitle(for: garden))
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                }
                Spacer(minLength: WBMetrics.gap)
                if let updatedAt = garden.updatedAt {
                    Text(Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000)
                        .formatted(date: .abbreviated, time: .omitted))
                        .font(.wbMonoCaption)
                        .foregroundStyle(WBColor.faint)
                        .accessibilityLabel(Text("Updated \(Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000).formatted(date: .long, time: .omitted))"))
                }
                Image(systemName: "chevron.right")
                    .font(.wbCaption)
                    .foregroundStyle(WBColor.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, WBMetrics.gapLarge)
            .frame(minHeight: WBMetrics.touchTarget)
            .padding(.vertical, WBMetrics.gap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await action()
            isWorking = false
        }
    }

    /// The two choices that would discard this device's garden also offer a fresh look at iCloud.
    private var offersRetry: Bool {
        switch choice.reason {
        case .deviceGardenNotFound, .sharedGardenUnavailable: return true
        case .multipleOwnGardens, .multipleSharedGardens, .sharedOrOwnGarden: return false
        }
    }

    private func subtitle(for garden: GardenZoneSummary) -> String {
        if case .sharedOrOwnGarden = choice.reason {
            return garden.scope == .owned ? "Your own garden" : "Shared with you"
        }
        return garden.scope == .owned ? "Yours" : "Shared by someone"
    }

    private var title: String {
        switch choice.reason {
        case .multipleOwnGardens: return "Choose your garden"
        case .multipleSharedGardens: return "Choose a garden"
        case .deviceGardenNotFound: return "This device's garden isn't in iCloud"
        case .sharedGardenUnavailable: return "This shared garden is no longer available"
        case .sharedOrOwnGarden: return "Which garden do you want to open?"
        }
    }

    private var explanation: String {
        switch choice.reason {
        case .multipleOwnGardens:
            return "Your iCloud account has more than one Seedkeep garden. Choose the one to use on this device."
        case .multipleSharedGardens:
            return "Several gardens are shared with you. Choose one, or use your own garden."
        case .deviceGardenNotFound:
            return "Your iCloud account has other Seedkeep gardens. Keep using this device's garden, or switch to one of them."
        case .sharedGardenUnavailable:
            return "It isn't shared with you anymore. Use your own garden, or another garden shared with you."
        case .sharedOrOwnGarden:
            return "A garden is shared with you, and you also have your own. Choose the one to open on this device."
        }
    }

    private var discardWarning: String {
        if case .sharedGardenUnavailable = choice.reason {
            return "This device's copy of the shared garden will be removed from this device. "
                + "Changes not yet synced to iCloud will be lost."
        }
        return "This device's garden will be removed from this device. Changes not yet synced to iCloud will be lost."
    }
}
