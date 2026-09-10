import Testing
@testable import Seedkeep

@Suite("ChangelogData integrity")
struct ChangelogDataTests {

    @Test("releases are authored newest-first with strictly descending, unique builds")
    func buildsDescendingAndUnique() {
        let builds = ChangelogData.releases.map(\.build)
        #expect(builds == builds.sorted(by: >), "releases must be authored newest-first")
        #expect(Set(builds).count == builds.count, "build numbers must be unique")
    }

    @Test("every release has at least one change and no empty change text")
    func changesWellFormed() {
        for release in ChangelogData.releases {
            #expect(!release.changes.isEmpty, "release \(release.build) has no changes")
            for change in release.changes {
                #expect(!change.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "release \(release.build) has an empty change")
            }
        }
    }

    @Test("the build-55 1.0 candidate has an entry and retains build 54")
    func shippingBuildPresent() throws {
        let release = try #require(ChangelogData.releases.first { $0.build == 55 })
        #expect(release.version == "1.0.0")
        #expect(release.changes.contains { $0.text.localizedCaseInsensitiveContains("journal") })
        #expect(release.changes.contains { $0.text.localizedCaseInsensitiveContains("bed detail") })
        #expect(ChangelogData.releases.contains { $0.build == 54 && $0.version == "1.0.0" })
    }
}
