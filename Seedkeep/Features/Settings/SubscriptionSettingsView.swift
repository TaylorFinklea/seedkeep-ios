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
                        .foregroundStyle(appEnv.preferences.cachedTier == "hosted" ? HerbColor.sage : HerbColor.inkSoft)
                }
                if !appEnv.subscriptions.purchasedProductIDs.isEmpty {
                    LabeledContent("Purchased") {
                        Text(appEnv.subscriptions.purchasedProductIDs.sorted().joined(separator: ", "))
                            .foregroundStyle(HerbColor.inkSoft)
                            .font(.caption.monospaced())
                    }
                }
            } header: {
                Rubric(text: "status")
            } footer: {
                Text("The Seedkeep server is the authority on whether you're on the Hosted tier. Your iCloud account's subscription state syncs here automatically; tap Restore if it doesn't.")
                    .font(HerbFont.bodyItalic(size: 11))
                    .foregroundStyle(HerbColor.inkSoft)
            }

            Section {
                if appEnv.subscriptions.products.isEmpty {
                    Text("No subscription products available. They're configured in App Store Connect — until that's wired up, stay on Free or BYOK.")
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkSoft)
                } else {
                    ForEach(appEnv.subscriptions.products, id: \.id) { product in
                        Button {
                            Task { _ = await appEnv.subscriptions.purchase(product) }
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.displayName)
                                        .font(HerbFont.bodyEmph(size: 14))
                                        .foregroundStyle(HerbColor.ink)
                                    Text(product.description)
                                        .font(HerbFont.bodyItalic(size: 12))
                                        .foregroundStyle(HerbColor.inkSoft)
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .font(HerbFont.bodyEmph(size: 14))
                                    .foregroundStyle(HerbColor.sepia)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(appEnv.subscriptions.isPurchasing)
                    }
                }
            } header: {
                Rubric(text: "subscribe")
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
                        ProgressView().controlSize(.small).herbProgressStyle()
                        Text(appEnv.subscriptions.isPurchasing ? "Processing purchase…" : "Verifying with server…")
                            .font(HerbFont.bodyItalic(size: 12))
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                }
            }

            if let err = appEnv.subscriptions.lastError {
                Section {
                    Text(err)
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.rose)
                }
            }
        }
        .vellumForm()
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
