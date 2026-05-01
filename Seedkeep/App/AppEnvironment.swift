import Foundation
import SwiftUI
import SeedkeepKit

/// Reads launch-time configuration from `Info.plist`, wires the
/// `SeedkeepClient`, and exposes the auth controller as an
/// `@Observable` model the SwiftUI views can read.
///
/// We resolve config eagerly at first access so a misconfigured xcconfig
/// crashes the app cleanly during development instead of failing later.
@MainActor
@Observable
public final class AppEnvironment {
    public let client: SeedkeepClient
    public let auth: AuthController

    public static func live() -> AppEnvironment {
        let baseURL = Self.resolveBaseURL()
        let keychainService = Self.resolveKeychainService()
        let store = KeychainTokenStore(service: keychainService)
        let client = SeedkeepClient(configuration: .init(baseURL: baseURL))
        let auth = AuthController(client: client, tokenStore: store)
        return AppEnvironment(client: client, auth: auth)
    }

    private init(client: SeedkeepClient, auth: AuthController) {
        self.client = client
        self.auth = auth
    }

    private static func resolveBaseURL() -> URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let scheme = (info["SeedkeepAPIScheme"] as? String) ?? "http"
        let host = (info["SeedkeepAPIHost"] as? String) ?? "localhost:8787"
        guard let url = URL(string: "\(scheme)://\(host)") else {
            fatalError("Invalid SeedkeepAPIScheme/SeedkeepAPIHost — check AppConfig.xcconfig")
        }
        return url
    }

    private static func resolveKeychainService() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["KeychainService"] as? String) ?? "com.example.seedkeep"
    }
}
