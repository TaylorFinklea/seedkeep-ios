import SwiftUI
import StoreKit

/// Subscription management surface for the Hosted tier. Lists the
/// available products, runs StoreKit 2 purchase + restore flows, and
/// shows the server's authoritative tier — the cached value comes
/// straight from `/api/subscriptions/me`.
struct SubscriptionSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var loadedOnce = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Server tier") {
                    Text(appEnv.preferences.cachedTier ?? "(unknown)")
                        .foregroundStyle(appEnv.preferences.cachedTier == "hosted" ? .green : .secondary)
                }
                if !appEnv.subscriptions.purchasedProductIDs.isEmpty {
                    LabeledContent("Purchased") {
                        Text(appEnv.subscriptions.purchasedProductIDs.sorted().joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Text("The Seedkeep server is the authority on whether you're on the Hosted tier. Your iCloud account's subscription state syncs here automatically; tap Restore if it doesn't.")
            }

            Section("Subscribe") {
                if appEnv.subscriptions.products.isEmpty {
                    Text("No subscription products available. They're configured in App Store Connect — until that's wired up, stay on Free or BYOK.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appEnv.subscriptions.products, id: \.id) { product in
                        Button {
                            Task { _ = await appEnv.subscriptions.purchase(product) }
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.displayName)
                                        .font(.body.weight(.medium))
                                    Text(product.description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(appEnv.subscriptions.isPurchasing)
                    }
                }
            }

            Section {
                Button {
                    Task { _ = await appEnv.subscriptions.restore() }
                } label: {
                    Label("Restore purchases", systemImage: "arrow.clockwise")
                }
                .disabled(appEnv.subscriptions.isVerifying)
            }

            if appEnv.subscriptions.isPurchasing || appEnv.subscriptions.isVerifying {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(appEnv.subscriptions.isPurchasing ? "Processing purchase…" : "Verifying with server…")
                            .font(.footnote)
                    }
                }
            }

            if let err = appEnv.subscriptions.lastError {
                Section {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loadedOnce {
                loadedOnce = true
                await appEnv.subscriptions.loadProducts()
                await appEnv.subscriptions.refreshEntitlements()
            }
            await appEnv.refreshTier()
        }
    }
}
