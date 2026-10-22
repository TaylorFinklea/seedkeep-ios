import Foundation
import Testing

// N3 (F): the app has no server transport. The server client went in T1; this pins the
// configuration that pointed at the server. It runs against the built test host on iOS and macOS,
// so it checks what ships, not the source files.
@Suite("Zero server transport (N3)")
struct ZeroServerTransportTests {

    private static let retiredHostMarkers = ["fly.dev", "seedkeep-server"]

    /// The app's executable plus any debug dylib beside it (Debug builds put the code there).
    private static func appBinaries() throws -> [URL] {
        // Positive control: the host is the app bundle, not a bare test runner.
        try #require(Bundle.main.bundleURL.pathExtension == "app")
        let executable = try #require(Bundle.main.executableURL)
        let directory = executable.deletingLastPathComponent()
        let dylibs = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dylib" }
        return [executable] + dylibs
    }

    private static func contains(_ data: Data, _ marker: String) -> Bool {
        data.range(of: Data(marker.utf8)) != nil
    }

    @Test("the app's Info.plist has no SeedkeepAPI keys and no server host")
    func infoPlistHasNoServerConfiguration() throws {
        let info = try #require(Bundle.main.infoDictionary)
        // Positive control: this is the app's Info.plist, not the test bundle's.
        #expect(info["KeychainService"] != nil)
        #expect(info.keys.filter { $0.hasPrefix("SeedkeepAPI") }.isEmpty)

        // Every key and value, as text, so a host hidden in any entry is caught.
        let xml = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        #expect(!Self.contains(xml, "SeedkeepAPI"))
        for marker in Self.retiredHostMarkers {
            #expect(!Self.contains(xml, marker), "Info.plist mentions \(marker)")
        }
    }

    @Test("the app binaries carry no server host")
    func binariesHaveNoServerHost() throws {
        let binaries = try Self.appBinaries()
        #expect(!binaries.isEmpty)
        for url in binaries {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            for marker in Self.retiredHostMarkers {
                #expect(!Self.contains(data, marker), "\(url.lastPathComponent) contains \(marker)")
            }
        }
    }

    // Entitlements are not checked here: the gate builds the test host with code signing off, so
    // it carries no entitlements to read. scripts/verify-release-archive.sh rejects a signed
    // archive that still has the Sign in with Apple entitlement.
}
