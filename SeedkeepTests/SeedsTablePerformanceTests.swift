import XCTest
import Foundation
@testable import Seedkeep
import SeedkeepKit

@MainActor
final class SeedsTablePerformanceTests: XCTestCase {
    func testMapAndSortPerformance() {
        func makeSeeds(_ count: Int) -> [LocalSeed] {
            (0..<count).map { index in
                LocalSeed(
                    id: "perf_\(index)",
                    householdID: "hh_perf",
                    catalogID: index.isMultiple(of: 2) ? "cat_\(index)" : nil,
                    state: index.isMultiple(of: 3) ? .wishlist : .active,
                    packetCount: index % 7,
                    locationID: index.isMultiple(of: 5) ? "loc_shed" : nil,
                    yearPacked: index.isMultiple(of: 4) ? nil : 2000 + index % 26,
                    source: .store,
                    customName: "Seed \(index * 37 % 1000)",
                    customVariety: index.isMultiple(of: 3) ? nil : "Variety \(index % 40)",
                    customCompany: "Company \(index % 12)",
                    customType: "Type \(index % 9)",
                    notes: "Notes \(index)",
                    tagIDs: ["tag_a", "tag_b"],
                    createdAt: 1,
                    updatedAt: Int64(index)
                )
            }
        }
        let seeds = makeSeeds(1_000)
        let locations = [LocalLocation(id: "loc_shed", householdID: "hh_perf", name: "Shed", sortOrder: 0, createdAt: 1, updatedAt: 1)]
        let tags = [
            LocalTag(id: "tag_a", householdID: "hh_perf", name: "Heirloom", createdAt: 1, updatedAt: 1),
            LocalTag(id: "tag_b", householdID: "hh_perf", name: "Winter", createdAt: 1, updatedAt: 1),
        ]

        // Initialize each measured path once so one-time setup costs are not counted.
        let warmRows = SeedTableRow.rows(seeds: Array(seeds.prefix(10)), locations: locations, tags: tags, recommendations: [:])
        let warmNameSorted = SeedsTableModel.sorted(warmRows, using: [KeyPathComparator(\SeedTableRow.name, order: .forward)])
        _ = SeedsTableModel.sorted(warmNameSorted, using: [KeyPathComparator(\SeedTableRow.yearSortKey, order: .reverse)])

        let clock = ContinuousClock()
        var sortedCount = 0
        let elapsed = clock.measure {
            let rows = SeedTableRow.rows(seeds: seeds, locations: locations, tags: tags, recommendations: [:])
            let sorted = SeedsTableModel.sorted(rows, using: [KeyPathComparator(\SeedTableRow.name, order: .forward)])
            let byYear = SeedsTableModel.sorted(sorted, using: [KeyPathComparator(\SeedTableRow.yearSortKey, order: .reverse)])
            sortedCount = byYear.count
        }

        XCTAssertEqual(sortedCount, 1_000)
        XCTAssertLessThan(elapsed, .milliseconds(50), "mapping and sorting 1,000 seeds took \(elapsed)")
    }
}
