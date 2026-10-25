import SwiftUI

/// N2-E: shown in every window while the garden guard file exists and can't be read. Nothing is
/// sent to iCloud for any garden until the record can be read again or is reset. Reset starts an
/// empty record: the garden stays on this device, and Seedkeep checks iCloud again before sending
/// anything. What it loses is the record of which gardens this device has seen and retired.
struct GardenGuardBlockedView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var isWorking = false
    @State private var confirmingReset = false
    @State private var failure: String?
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 36

    var body: some View {
        ScrollView {
            VStack(spacing: WBMetrics.gapLarge) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: symbolSize))
                    .foregroundStyle(WBColor.muted)
                    .accessibilityHidden(true)
                Text("Seedkeep can't read its iCloud safety record")
                    .font(.wbTitle)
                    .foregroundStyle(WBColor.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Your garden is safe on this device. Seedkeep sends nothing to iCloud until it can read the record again.")
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Text(failure)
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: WBMetrics.gap) {
                    Button {
                        run { appEnv.gardenGuard.tryAgain() }
                    } label: {
                        Text("Try again")
                            .foregroundStyle(WBColor.accentInk)
                            .frame(minHeight: WBMetrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WBColor.accent)
                    .accessibilityIdentifier("guard.tryAgain")

                    Button(role: .destructive) {
                        confirmingReset = true
                    } label: {
                        Text("Reset")
                            .frame(minHeight: WBMetrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("guard.reset")
                }
                .padding(.top, WBMetrics.gap)
            }
            .padding(24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WBScreenBackground() }
        .disabled(isWorking)
        .accessibilityIdentifier("screen.guardBlocked")
        .confirmationDialog(
            "Reset the iCloud safety record?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                run {
                    do { try appEnv.gardenGuard.reset() } catch { failure = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your garden stays on this device. Seedkeep forgets which gardens it has seen in iCloud, and checks iCloud again before it sends anything. A garden that was deleted from iCloud will ask you what to do.")
        }
    }

    /// The message after an attempt: none once readable; a failed Reset keeps its own error.
    static func failureText(readable: Bool, existing: String?) -> String? {
        readable ? nil : (existing ?? "It still can't be read.")
    }

    private func run(_ action: @escaping @MainActor () -> Void) {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        Task {
            action()
            failure = Self.failureText(readable: appEnv.gardenGuard.isReadable, existing: failure)
            if appEnv.gardenGuard.isReadable {
                // Resolution may have stopped on the unreadable record: run it again.
                await appEnv.auth.restoreSession()
            }
            isWorking = false
        }
    }
}
