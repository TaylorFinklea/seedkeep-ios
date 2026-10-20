import SwiftUI

/// Shown while `AuthController` resolves the iCloud identity and garden.
struct EntryProgressView: View {
    var body: some View {
        VStack(spacing: WBMetrics.gapLarge) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Opening your garden…")
                .font(.wbBody)
                .foregroundStyle(WBColor.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WBColor.bg)
    }
}

/// N1 entry screen when the app cannot enter a garden: no iCloud account, iCloud restricted,
/// iCloud unreachable with nothing cached, or a failed identity transition. Every case offers
/// Retry. Nothing on this screen wipes data.
struct CloudEntryView: View {
    enum Reason: Equatable {
        case blocked(CloudEntryBlock)
        case failed(message: String)
    }

    @Environment(AuthController.self) private var auth
    #if os(macOS)
    @Environment(\.openURL) private var openURL
    #endif
    let reason: Reason
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: WBMetrics.gapLarge) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(WBColor.muted)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(WBColor.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.wbBody)
                .foregroundStyle(WBColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .padding(.top, WBMetrics.gap)
        }
        .padding(24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WBColor.bg)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: WBMetrics.gap) {
            #if os(macOS)
            if reason == .blocked(.noAccount),
               let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                Button("Open System Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
                    .tint(WBColor.accent)
            }
            #endif
            Button {
                Task {
                    isRetrying = true
                    await auth.retry()
                    isRetrying = false
                }
            } label: {
                if isRetrying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Retry")
                }
            }
            .buttonStyle(.bordered)
            .tint(WBColor.accent)
            .frame(minHeight: WBMetrics.touchTarget)
            .disabled(isRetrying)
        }
    }

    private var symbol: String {
        switch reason {
        case .blocked(.noAccount): return "icloud.slash"
        case .blocked(.restricted): return "lock.icloud"
        case .blocked(.couldNotVerify): return "exclamationmark.icloud"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch reason {
        case .blocked(.noAccount): return "Sign in to iCloud"
        case .blocked(.restricted): return "iCloud is restricted"
        case .blocked(.couldNotVerify): return "Couldn't reach iCloud"
        case .failed: return "Something went wrong"
        }
    }

    private var message: String {
        switch reason {
        case .blocked(.noAccount):
            #if os(macOS)
            return "Sign in to iCloud to use Seedkeep. Your garden is stored in your iCloud account."
            #else
            return "Sign in to iCloud to use Seedkeep. Your garden is stored in your iCloud account. "
                + "Open Settings, tap your name, and sign in."
            #endif
        case .blocked(.restricted):
            return "iCloud is restricted on this device, by Screen Time or device management. "
                + "Seedkeep stores your garden in iCloud, so it can't open until iCloud is allowed."
        case .blocked(.couldNotVerify):
            return "Couldn't reach iCloud. Check your connection and try again."
        case .failed(let message):
            return message
        }
    }
}
