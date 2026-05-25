import Foundation

/// Wire-format DTOs for the Phase 3 (Journal) API endpoints.
///
/// Naming convention: the journal routes emit camelCase JSON keys on
/// responses (matching the recommendation/extraction routes), so the
/// synthesized `Codable` conformance works without custom `CodingKeys`
/// here. Request bodies use snake_case — those bodies live next to the
/// client methods in `SeedkeepClient` (the `*Input` types) where the
/// snake_case `CodingKeys` mapping is declared.

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

public struct JournalEntryPhotoDTO: Codable, Sendable, Equatable {
    public let id: String
    public let entryId: String
    public let storageKey: String
    public let sortOrder: Int
    public let width: Int?
    public let height: Int?
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(
        id: String,
        entryId: String,
        storageKey: String,
        sortOrder: Int,
        width: Int?,
        height: Int?,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.entryId = entryId
        self.storageKey = storageKey
        self.sortOrder = sortOrder
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct JournalChecklistItemDTO: Codable, Sendable, Equatable {
    public let id: String
    public let entryId: String
    public let text: String
    public let completed: Bool
    public let sortOrder: Int
    public let updatedAt: Int64

    public init(
        id: String,
        entryId: String,
        text: String,
        completed: Bool,
        sortOrder: Int,
        updatedAt: Int64
    ) {
        self.id = id
        self.entryId = entryId
        self.text = text
        self.completed = completed
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }
}

/// Server response for `GET /api/journal`. Mirrors the generic delta-sync
/// envelope used by `/api/seeds`, `/api/beds`, `/api/locations`, etc.:
/// `{ items: [...], cursor: <ms>, has_more: bool }`. Declared as a
/// typealias so callers see a journal-specific name while reusing the
/// existing `DeltaPage` shape (so `cursor` / `has_more` decode and
/// follow-up sync requests work identically to other resources).
public typealias JournalFeedResponseDTO = DeltaPage<JournalEntryDTO>

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
