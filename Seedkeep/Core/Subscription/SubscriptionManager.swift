import Foundation
import StoreKit
import SeedkeepKit

/// StoreKit 2 wrapper for the Hosted-tier subscription products.
///
/// Lifecycle:
///   1. App launches → `loadProducts()` fetches the configured products
///      from the App Store.
///   2. User taps "Subscribe" → `purchase(_:)` runs StoreKit 2's
///      `Product.purchase()` and, on success, posts the App Store
///      receipt to `POST /api/subscriptions/verify`.
///   3. The server records the subscription and flips `users.tier` to
///      `hosted`. We update `AppPreferences.cachedTier` so the UI flips.
///   4. Restore button re-runs receipt validation against the same
///      endpoint without going through a new purchase flow.
///   5. The transaction-update listener picks up renewals + revocations
///      and refreshes the server.
///
/// The product IDs are placeholders until they're configured in App
/// Store Connect — `loadProducts` will quietly return an empty list
/// against StoreKit's sandbox until then. Nothing breaks; the UI just
/// shows "No subscription products available" and the user keeps using
/// Free or BYOK.
@MainActor
@Observable
public final class SubscriptionManager {
    public static let monthlyProductID = "app.seedkeep.ios.hosted.monthly"
    public static let yearlyProductID = "app.seedkeep.ios.hosted.yearly"

    public private(set) var products: [Product] = []
    public private(set) var purchasedProductIDs: Set<String> = []
    public private(set) var lastError: String?
    public private(set) var isPurchasing: Bool = false
    public private(set) var isVerifying: Bool = false

    private let client: SeedkeepClient
    private var updateListenerTask: Task<Void, Never>?

    public init(client: SeedkeepClient) {
        self.client = client
        startTransactionListener()
    }
    // The listener task captures `self` weakly so it exits naturally
    // when the manager deinits. We don't add a deinit because the
    // SubscriptionManager lives for the lifetime of AppEnvironment
    // (i.e. the lifetime of the app process); explicit cancellation
    // would only matter if we ever recreated the manager mid-session.

    /// Fetches the subscription products from the App Store. Safe to
    /// call repeatedly — StoreKit caches.
    public func loadProducts() async {
        do {
            let ids: Set<String> = [Self.monthlyProductID, Self.yearlyProductID]
            let loaded = try await Product.products(for: ids)
            // Sort: monthly first, yearly second.
            products = loaded.sorted { lhs, rhs in
                lhs.id == Self.monthlyProductID
            }
        } catch {
            lastError = "Could not load products: \(error.localizedDescription)"
        }
    }

    /// Drives the StoreKit 2 purchase flow. On success, the new receipt
    /// is sent to the server which authoritatively flips the user's
    /// tier. Returns true on a successful purchase.
    @discardableResult
    public func purchase(_ product: Product) async -> Bool {
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                _ = try checkVerified(verification)
                purchasedProductIDs.insert(product.id)
                return await sendReceiptToServer()
            case .userCancelled:
                return false
            case .pending:
                lastError = "Purchase pending — Apple is still processing this transaction."
                return false
            @unknown default:
                lastError = "Unknown StoreKit purchase result"
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Re-validates whatever receipts the device already has against the
    /// server. Used by the "Restore purchases" button.
    @discardableResult
    public func restore() async -> Bool {
        // StoreKit 2 sync is the modern equivalent of "restore" — it
        // refreshes the on-device entitlement state with the App Store.
        do {
            try await AppStore.sync()
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
            return false
        }
        await refreshEntitlements()
        return await sendReceiptToServer()
    }

    /// Reads `Transaction.currentEntitlements` and tracks which product
    /// IDs are currently entitled. Drives whatever UI shows the user's
    /// subscription status.
    public func refreshEntitlements() async {
        var ids: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                ids.insert(transaction.productID)
            }
        }
        purchasedProductIDs = ids
    }

    /// Pulls the App Store receipt off disk, base64-encodes it, posts it
    /// to `POST /api/subscriptions/verify`, and applies the server's
    /// authoritative tier answer.
    @discardableResult
    public func sendReceiptToServer() async -> Bool {
        isVerifying = true
        defer { isVerifying = false }

        // Apple's modern alternative is `AppTransaction.shared` (JWS),
        // but our server uses the legacy `verifyReceipt` endpoint which
        // wants the bundled-receipt bytes. Suppress the deprecation
        // warning here; the path is still functional in iOS 18+.
        let data: Data
        do {
            #if compiler(>=5.9)
            @available(iOS, deprecated: 18.0, message: "Server uses verifyReceipt; switch to AppTransaction when the server moves to App Store Server API.")
            func loadReceipt() throws -> Data? {
                guard let url = Bundle.main.appStoreReceiptURL else { return nil }
                return try Data(contentsOf: url)
            }
            guard let bytes = try loadReceipt() else {
                lastError = "No App Store receipt URL on this build."
                return false
            }
            data = bytes
            #else
            guard let url = Bundle.main.appStoreReceiptURL else {
                lastError = "No App Store receipt URL on this build."
                return false
            }
            data = try Data(contentsOf: url)
            #endif
        } catch {
            lastError = "Could not read receipt: \(error.localizedDescription)"
            return false
        }
        if data.isEmpty {
            lastError = "Receipt is empty. If you're in the simulator, sign into a sandbox Apple ID and try again."
            return false
        }
        let b64 = data.base64EncodedString()
        do {
            _ = try await client.verifyAppleReceipt(receiptDataB64: b64)
            return true
        } catch let err as SeedkeepError {
            lastError = "\(err.code): \(err.message)"
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Background listener for renewals, expirations, and refunds the
    /// App Store delivers asynchronously. Each tick re-syncs with the
    /// server so the cached tier stays accurate.
    private func startTransactionListener() {
        updateListenerTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified = result {
                    await self.refreshEntitlements()
                    _ = await self.sendReceiptToServer()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }
}
