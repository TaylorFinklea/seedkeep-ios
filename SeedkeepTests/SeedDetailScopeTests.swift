import Testing
import Foundation
@testable import Seedkeep

/// The seed detail pickers offer only the active household's live locations and tags.
@MainActor
@Suite("Seed detail pickers — household scope")
struct SeedDetailScopeTests {
    private static let locations = [
        LocalLocation(id: "loc_mine", householdID: "hh_mine", name: "Shed", sortOrder: 0, createdAt: 1, updatedAt: 1),
        LocalLocation(id: "loc_theirs", householdID: "hh_other", name: "Their shed", sortOrder: 0, createdAt: 1, updatedAt: 1),
        LocalLocation(id: "loc_gone", householdID: "hh_mine", name: "Old", sortOrder: 1, createdAt: 1, updatedAt: 1, deletedAt: 2),
    ]

    private static let tags = [
        LocalTag(id: "tag_mine", householdID: "hh_mine", name: "Heirloom", createdAt: 1, updatedAt: 1),
        LocalTag(id: "tag_theirs", householdID: "hh_other", name: "Theirs", createdAt: 1, updatedAt: 1),
        LocalTag(id: "tag_gone", householdID: "hh_mine", name: "Retired", createdAt: 1, updatedAt: 1, deletedAt: 2),
    ]

    @Test("only the active household's live locations are offered")
    func locationsScoped() {
        #expect(SeedDetailScope.locations(Self.locations, householdID: "hh_mine").map(\.id) == ["loc_mine"])
        #expect(SeedDetailScope.locations(Self.locations, householdID: nil).isEmpty, "no household, no choices")
    }

    @Test("only the active household's live tags are offered")
    func tagsScoped() {
        #expect(SeedDetailScope.tags(Self.tags, householdID: "hh_mine").map(\.id) == ["tag_mine"])
        #expect(SeedDetailScope.tags(Self.tags, householdID: nil).isEmpty)
    }
}
