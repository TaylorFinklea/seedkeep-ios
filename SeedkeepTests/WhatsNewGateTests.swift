import Testing
import Foundation
@testable import Seedkeep

@Suite("WhatsNewGate")
struct WhatsNewGateTests {

    private func release(_ build: Int) -> ChangelogRelease {
        ChangelogRelease(version: "0.4.0", build: build, date: nil, headline: nil,
                         changes: [ChangelogChange(category: .new, text: "x")])
    }

    // MARK: releaseToAutoPresent — the six semantics

    @Test("first install (no lastSeen) presents nothing")
    func firstInstall() {
        #expect(WhatsNewGate.releaseToAutoPresent(
            releases: [release(50)], lastSeenBuild: nil, currentBuild: 50) == nil)
    }

    @Test("an update presents the newest release")
    func update() {
        let r = WhatsNewGate.releaseToAutoPresent(
            releases: [release(50), release(49)], lastSeenBuild: 49, currentBuild: 50)
        #expect(r?.build == 50)
    }

    @Test("nothing newer than lastSeen presents nothing")
    func nothingNew() {
        #expect(WhatsNewGate.releaseToAutoPresent(
            releases: [release(50)], lastSeenBuild: 50, currentBuild: 50) == nil)
    }

    @Test("a downgrade presents nothing")
    func downgrade() {
        #expect(WhatsNewGate.releaseToAutoPresent(
            releases: [release(50), release(49)], lastSeenBuild: 50, currentBuild: 49) == nil)
    }

    @Test("empty releases present nothing")
    func empty() {
        #expect(WhatsNewGate.releaseToAutoPresent(
            releases: [], lastSeenBuild: 10, currentBuild: 50) == nil)
    }

    @Test("across skipped builds, only the latest presents")
    func latestOnlyAcrossSkips() {
        let r = WhatsNewGate.releaseToAutoPresent(
            releases: [release(50), release(49)], lastSeenBuild: 48, currentBuild: 50)
        #expect(r?.build == 50)   // not 49
    }

    @Test("never advertises a release newer than the running binary")
    func neverAheadOfBinary() {
        let r = WhatsNewGate.releaseToAutoPresent(
            releases: [release(51), release(50)], lastSeenBuild: 49, currentBuild: 50)
        #expect(r?.build == 50)   // 51 isn't in this binary yet
    }

    // MARK: persistence round-trip (unique key per run — no defaults cleanup needed)

    @Test("markSeen then lastSeenBuild round-trips; unset reads nil")
    func persistenceRoundTrip() {
        let suiteName = "whatsnew-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        #expect(WhatsNewGate.lastSeenBuild(defaults: defaults) == nil)
        WhatsNewGate.markSeen(build: 50, defaults: defaults)
        #expect(WhatsNewGate.lastSeenBuild(defaults: defaults) == 50)
    }
}
