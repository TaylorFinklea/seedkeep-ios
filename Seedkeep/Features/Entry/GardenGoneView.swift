import SwiftUI

/// N2-E (G3) §7: shown in every window (the Workbench, the iPhone tabs, the Mac Settings window) while
/// the active garden is gone and waits for the user's choice, and while the choice runs. Nothing here is
/// written into the gone garden, and the screen cannot be dismissed: the garden stays out of reach until
/// the user keeps a copy as a new garden or discards this copy.
///
/// Every window shows the same screen from the same state (`AppEnvironment.gardenGoneScreen`), and the
/// runner runs one journal however often a button is tapped or in however many windows.
struct GardenGoneView: View {
    private struct InventoryScope: Equatable {
        let accountKey: String
        let householdID: String

        init(_ screen: GardenGoneScreenState) {
            accountKey = screen.accountKey
            householdID = screen.householdID
        }
    }

    @Environment(AppEnvironment.self) private var appEnv
    @State private var inventory: GardenInventory?
    @State private var inventoryScope: InventoryScope?
    @State private var inventoryFailed = false
    @State private var inventoryAttempt = 0
    @State private var confirmingDiscard = false
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 36

    // MARK: - Words (tests pin them)

    static let ownerTitle = "This garden was deleted from iCloud."
    static let ownerMessage = "It may have been deleted on another device or in iCloud Settings."
    static let participantTitle = "You no longer have access to this shared garden."
    static let participantMessage = "The owner stopped sharing it or removed you."
    static let keepTitle = "Keep a copy as a new garden"
    static let keepHint = "Makes a new garden in your iCloud from what is still on this device."
    static let discardTitle = "Discard this copy"
    static let discardConfirmTitle = "Discard this copy?"
    static let discardConfirmMessage = "The seeds, beds, journal entries and photos of this garden are removed from this device. This can't be undone."
    static let retryTitle = "Try again"

    static func title(isParticipant: Bool) -> String { isParticipant ? participantTitle : ownerTitle }
    static func message(isParticipant: Bool) -> String { isParticipant ? participantMessage : ownerMessage }

    static func workingText(_ action: GardenGoneRecord.Action) -> String {
        switch action {
        case .keep: return "Keeping a copy as a new garden…"
        case .discard: return "Discarding this copy…"
        case .rehome: return "Moving your garden to a new place in iCloud…"
        }
    }

    /// "This device still has 12 seeds, 3 beds, 40 journal entries and 18 photos."
    static func inventorySentence(_ inventory: GardenInventory) -> String {
        let parts = [
            count(inventory.seeds, "seed"), count(inventory.beds, "bed"),
            count(inventory.journalEntries, "journal entry", plural: "journal entries"),
            count(inventory.photos, "photo"),
        ]
        return "This device still has \(list(parts))."
    }

    /// "2 photos aren't on this device and can't be kept." nil when every photo is here.
    static func missingPhotosSentence(_ inventory: GardenInventory) -> String? {
        guard inventory.photosNotOnDevice > 0 else { return nil }
        let n = inventory.photosNotOnDevice
        return n == 1 ? "1 photo isn't on this device and can't be kept."
                      : "\(n) photos aren't on this device and can't be kept."
    }

    private static func count(_ n: Int, _ one: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? one : (plural ?? one + "s"))"
    }

    private static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }

    // MARK: - Body

    private struct InventoryRequest: Equatable {
        let scope: InventoryScope?
        let attempt: Int
    }

    var body: some View {
        let screen = appEnv.gardenGoneScreen
        ScrollView {
            VStack(spacing: WBMetrics.gapLarge) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: symbolSize))
                    .foregroundStyle(WBColor.muted)
                    .accessibilityHidden(true)
                Text(Self.title(isParticipant: screen?.isParticipant ?? false))
                    .font(.wbTitle)
                    .foregroundStyle(WBColor.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("gardenGone.title")
                Text(Self.message(isParticipant: screen?.isParticipant ?? false))
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gardenGone.message")
                inventoryBlock
                if let screen {
                    switch screen.phase {
                    case .choice: choice(screen)
                    case .working(let action): working(screen, action)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WBScreenBackground() }
        .accessibilityIdentifier("screen.gardenGone")
        .task(id: InventoryRequest(scope: screen.map(InventoryScope.init), attempt: inventoryAttempt)) {
            inventory = nil
            inventoryScope = nil
            inventoryFailed = false
            guard let scope = screen.map(InventoryScope.init) else { return }
            let counted: GardenInventory
            do {
                counted = try await GardenInventory.count(container: appEnv.container, householdID: scope.householdID)
            } catch {
                guard !Task.isCancelled, let current = appEnv.gardenGoneScreen,
                      InventoryScope(current) == scope else { return }
                inventoryFailed = true
                return
            }
            guard !Task.isCancelled,
                  let current = appEnv.gardenGoneScreen,
                  InventoryScope(current) == scope else { return }
            inventory = counted
            inventoryScope = scope
        }
    }

    @ViewBuilder private var inventoryBlock: some View {
        if inventoryFailed {
            Text("What this device still has couldn't be checked. Try again.")
                .font(.wbCaption)
                .foregroundStyle(WBColor.muted)
                .accessibilityIdentifier("gardenGone.inventoryFailure")
            Button(Self.retryTitle) { inventoryAttempt += 1 }
                .accessibilityIdentifier("gardenGone.inventoryRetry")
        }
        if let inventory, let screen = appEnv.gardenGoneScreen,
           inventoryScope == InventoryScope(screen) {
            VStack(spacing: WBMetrics.gap) {
                Text(Self.inventorySentence(inventory))
                    .font(.wbBody)
                    .foregroundStyle(WBColor.ink)
                    .accessibilityIdentifier("gardenGone.inventory")
                if let missing = Self.missingPhotosSentence(inventory) {
                    Text(missing)
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                        .accessibilityIdentifier("gardenGone.missingPhotos")
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choice(_ screen: GardenGoneScreenState) -> some View {
        let inventoryIsCurrent = inventory != nil && inventoryScope == InventoryScope(screen)
        return VStack(spacing: WBMetrics.gap) {
            if let failure = screen.failure {
                Text(failure)
                    .font(.wbCaption)
                    .foregroundStyle(WBColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gardenGone.failure")
            }
            Button {
                appEnv.answerGardenChoice(.keep)
            } label: {
                Text(Self.keepTitle)
                    .foregroundStyle(WBColor.accentInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: WBMetrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .tint(WBColor.accent)
            .accessibilityHint(Self.keepHint)
            .accessibilityIdentifier("gardenGone.keep")
            .disabled(!inventoryIsCurrent)
            Text(Self.keepHint)
                .font(.wbCaption)
                .foregroundStyle(WBColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                confirmingDiscard = true
            } label: {
                Text(Self.discardTitle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: WBMetrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("gardenGone.discard")
        }
        .padding(.top, WBMetrics.gap)
        .confirmationDialog(Self.discardConfirmTitle, isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { appEnv.answerGardenChoice(.discard) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.discardConfirmMessage)
        }
    }

    @ViewBuilder
    private func working(_ screen: GardenGoneScreenState, _ action: GardenGoneRecord.Action) -> some View {
        VStack(spacing: WBMetrics.gap) {
            if screen.isRunning || screen.failure == nil {
                ProgressView().tint(WBColor.accent)
                Text(Self.workingText(action))
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("gardenGone.working")
            } else if let failure = screen.failure {
                Text(failure)
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gardenGone.failure")
                Button {
                    Task { await appEnv.retryGardenJournal() }
                } label: {
                    Text(Self.retryTitle)
                        .foregroundStyle(WBColor.accentInk)
                        .frame(maxWidth: .infinity, minHeight: WBMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(WBColor.accent)
                .accessibilityIdentifier("gardenGone.retry")
            }
        }
        .padding(.top, WBMetrics.gap)
    }
}
