import Testing
import Foundation
@testable import Seedkeep

/// Bulk refresh sends at most 200 ids. The ids the caller asked for come first; pending ids fill only
/// what is left, so an unordered truncation can never drop a requested id.
@MainActor
@Suite("RecommendationStore — bulk id budget")
struct RecommendationBulkIDTests {
    @Test("a full request leaves no room for pending ids, so they cannot displace requested ones")
    func requestedBeforePending() {
        let requested = (0..<200).map { "req-\($0)" }
        let ids = RecommendationStore.bulkRequestIDs(requested: requested, pending: ["aaa-pending", "zzz-pending"])
        #expect(ids == requested)
    }

    @Test("pending ids fill only the remaining budget, in sorted order")
    func pendingFillsRemainder() {
        let requested = (0..<198).map { "req-\($0)" }
        let ids = RecommendationStore.bulkRequestIDs(requested: requested, pending: ["p-3", "p-1", "p-2"])
        #expect(ids.count == 200)
        #expect(Array(ids.prefix(198)) == requested)
        #expect(Array(ids.suffix(2)) == ["p-1", "p-2"])
    }

    @Test("requested ids over the budget are cut from the end of the request, never mixed with pending")
    func requestedOverBudget() {
        let requested = (0..<250).map { "req-\($0)" }
        let ids = RecommendationStore.bulkRequestIDs(requested: requested, pending: ["p"])
        #expect(ids == Array(requested.prefix(200)))
    }

    @Test("an id that is both requested and pending is sent once")
    func deduplicates() {
        let ids = RecommendationStore.bulkRequestIDs(requested: ["a", "b", "a"], pending: ["b", "c"])
        #expect(ids == ["a", "b", "c"])
    }
}
