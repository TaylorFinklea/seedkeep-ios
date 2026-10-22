import Foundation

/// A journal entry as `JournalStore.retrospective` returns it ("on this day" in past years).
/// camelCase, as the retired server's journal routes emitted it.
public struct JournalEntryDTO: Codable, Sendable, Equatable {
    public let id: String
    public let householdId: String
    public let occurredOn: String           // 'YYYY-MM-DD'
    public let body: String
    public let seedId: String?
    public let bedId: String?
    public let plantingEventId: String?
    public let createdAt: Int64             // ms-epoch
    public let updatedAt: Int64
    public let deletedAt: Int64?

    public init(
        id: String,
        householdId: String,
        occurredOn: String,
        body: String,
        seedId: String?,
        bedId: String?,
        plantingEventId: String?,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64?
    ) {
        self.id = id
        self.householdId = householdId
        self.occurredOn = occurredOn
        self.body = body
        self.seedId = seedId
        self.bedId = bedId
        self.plantingEventId = plantingEventId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct RetrospectiveYearDTO: Codable, Sendable, Equatable {
    public let year: Int
    public let entries: [JournalEntryDTO]

    public init(year: Int, entries: [JournalEntryDTO]) {
        self.year = year
        self.entries = entries
    }
}

public struct RetrospectiveResponseDTO: Codable, Sendable, Equatable {
    public let anchor: String               // 'MM-DD'
    public let years: [RetrospectiveYearDTO]

    public init(anchor: String, years: [RetrospectiveYearDTO]) {
        self.anchor = anchor
        self.years = years
    }
}
