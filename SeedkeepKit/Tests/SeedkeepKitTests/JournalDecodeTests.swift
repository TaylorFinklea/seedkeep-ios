import Testing
import Foundation
@testable import SeedkeepKit

@Suite("Journal DTOs decode correctly")
struct JournalDecodeTests {

    @Test func entryRoundTrip() throws {
        let entry = JournalEntryDTO(
            id: "e1",
            householdId: "h1",
            occurredOn: "2026-05-24",
            body: "Planted Ozark Giant peppers.",
            seedId: nil,
            bedId: "b1",
            plantingEventId: nil,
            createdAt: 1234567890000,
            updatedAt: 1234567890000,
            deletedAt: nil
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(JournalEntryDTO.self, from: data)
        #expect(decoded == entry)
    }

    @Test func retrospectiveShape() throws {
        let json = """
        {
          "anchor": "05-24",
          "years": [
            {
              "year": 2025,
              "entries": [
                {
                  "id": "e_2025",
                  "householdId": "h1",
                  "occurredOn": "2025-05-24",
                  "body": "Last year today",
                  "seedId": null,
                  "bedId": null,
                  "plantingEventId": null,
                  "createdAt": 1716508800000,
                  "updatedAt": 1716508800000,
                  "deletedAt": null
                }
              ]
            },
            {
              "year": 2024,
              "entries": []
            }
          ]
        }
        """
        let r = try JSONDecoder().decode(RetrospectiveResponseDTO.self, from: Data(json.utf8))
        #expect(r.anchor == "05-24")
        // Order must be preserved as emitted by the server (most-recent first).
        #expect(r.years.map(\.year) == [2025, 2024])
        #expect(r.years[0].entries.count == 1)
        #expect(r.years[0].entries[0].body == "Last year today")
        #expect(r.years[1].entries.isEmpty)
    }

}
