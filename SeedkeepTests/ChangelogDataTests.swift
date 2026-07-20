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

    @Test("the shipping build has an entry")
    func shippingBuildPresent() {
        // Build 50 was the first build to ship the 27d stabilization set; its
        // entry is the initial seed. Guards the release.sh authoring gate's premise.
        #expect(ChangelogData.releases.contains { $0.build == 50 })
    }
}
