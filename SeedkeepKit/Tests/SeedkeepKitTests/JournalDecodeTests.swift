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

    @Test func serverFeedShape() throws {
        // Mirrors the on-the-wire shape: { items: [...], cursor, has_more }.
        // Property keys are camelCase on `JournalEntryDTO`, snake_case on
        // the envelope (`has_more`) — same convention as DeltaPage<SeedDTO>.
        let json = """
        {
          "items": [
            {
              "id": "e1",
              "householdId": "h1",
              "occurredOn": "2026-05-24",
              "body": "Test",
              "seedId": null,
              "bedId": "b1",
              "plantingEventId": null,
              "createdAt": 1234567890000,
              "updatedAt": 1234567890000,
              "deletedAt": null
            },
            {
              "id": "e2",
              "householdId": "h1",
              "occurredOn": "2026-05-25",
              "body": "Second entry",
              "seedId": "s1",
              "bedId": null,
              "plantingEventId": "p1",
              "createdAt": 1234567899999,
              "updatedAt": 1234567899999,
              "deletedAt": null
            }
          ],
          "cursor": 1234567899999,
          "has_more": false
        }
        """
        let r = try JSONDecoder().decode(JournalFeedResponseDTO.self, from: Data(json.utf8))
        #expect(r.items.count == 2)
        #expect(r.items[0].bedId == "b1")
        #expect(r.items[0].seedId == nil)
        #expect(r.items[1].seedId == "s1")
        #expect(r.items[1].plantingEventId == "p1")
        #expect(r.cursor == 1234567899999)
        #expect(r.has_more == false)
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

    @Test func photoDTOAllFieldsAndNullableDimensions() throws {
        // First payload has both width + height set; second leaves them null.
        let json = """
        {
          "photos": [
            {
              "id": "p1",
              "entryId": "e1",
              "storageKey": "households/h1/journal/e1/p1.jpg",
              "sortOrder": 0,
              "width": 1920,
              "height": 1080,
              "createdAt": 1234567890000,
              "updatedAt": 1234567890000
            },
            {
              "id": "p2",
              "entryId": "e1",
              "storageKey": "households/h1/journal/e1/p2.jpg",
              "sortOrder": 1,
              "width": null,
              "height": null,
              "createdAt": 1234567890001,
              "updatedAt": 1234567890001
            }
          ]
        }
        """
        struct PhotoList: Codable { let photos: [JournalEntryPhotoDTO] }
        let r = try JSONDecoder().decode(PhotoList.self, from: Data(json.utf8))
        #expect(r.photos.count == 2)
        #expect(r.photos[0].width == 1920)
        #expect(r.photos[0].height == 1080)
        #expect(r.photos[0].sortOrder == 0)
        #expect(r.photos[1].width == nil)
        #expect(r.photos[1].height == nil)
        #expect(r.photos[1].sortOrder == 1)
        #expect(r.photos[0].updatedAt == 1234567890000)
    }
}
