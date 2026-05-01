import Foundation

/// Lifecycle state of a per-household seed entry. Mirrors the server's
/// `seeds.state` CHECK constraint exactly so the client can encode/decode
/// without translation.
public enum SeedState: String, Codable, CaseIterable, Sendable, Hashable {
    /// Currently in your library; appears in random pick.
    case active
    /// Want to buy or trade for. Not yet owned.
    case wishlist
    /// Self-harvested from your own plants.
    case saved
    /// Used up or otherwise retired. Hidden from the active library by default.
    case archived
}

/// Where a seed packet originally came from. Mirrors `seeds.source`.
public enum SeedSource: String, Codable, CaseIterable, Sendable, Hashable {
    case store
    case saved
    case gift
    case swap
}

/// Photo role on a seed packet. Front, back, or extra (e.g. close-up of the
/// instructions). Mirrors `seed_photos.role`.
public enum PhotoRole: String, Codable, CaseIterable, Sendable, Hashable {
    case front
    case back
    case `extra`
}
