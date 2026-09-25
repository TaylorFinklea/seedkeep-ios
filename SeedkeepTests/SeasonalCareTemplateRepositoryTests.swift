import Foundation
import Testing
@testable import Seedkeep

@Suite("Seasonal-care template repository")
struct SeasonalCareTemplateRepositoryTests {
    private static let packString = #"""
    [
      {
        "id": "authority.tomato.mulch",
        "version": 2,
        "crop_key": " Tomato ",
        "region_codes": ["all"],
        "applicability_label": "Broad guidance",
        "title": "Mulch tomatoes",
        "instructions": "Apply a clean mulch layer after the soil warms.",
        "start_month": 5,
        "start_day": 1,
        "end_month": 6,
        "end_day": 15,
        "authority_name": "Example Extension",
        "source_title": "Tomato growing guide",
        "source_url": "https://example.org/tomatoes"
      },
      {
        "id": "authority.tomato.mn-pruning",
        "version": 1,
        "crop_key": "tomato",
        "region_codes": ["US-MN"],
        "title": "Check tomato supports",
        "instructions": "Inspect supports during the growing season.",
        "start_month": 6,
        "start_day": 1,
        "end_month": 8,
        "end_day": 31,
        "authority_name": "Example Extension",
        "source_title": "Tomato growing guide",
        "source_url": "https://example.org/tomatoes"
      },
      {
        "id": "authority.tomato.ks-pruning",
        "version": 1,
        "crop_key": "tomato",
        "region_codes": ["US-KS"],
        "title": "Check tomato pruning",
        "instructions": "Inspect plants during the growing season.",
        "start_month": 6,
        "start_day": 1,
        "end_month": 8,
        "end_day": 31,
        "authority_name": "Example Extension",
        "source_title": "Tomato growing guide",
        "source_url": "https://example.org/tomatoes"
      }
    ]
    """#
    private static let pack = Data(packString.utf8)

    @Test("decodes all editable snapshot inputs and attribution")
    func decodesTemplate() throws {
        let repository = try BundledSeasonalCareTemplateRepository(data: Self.pack)
        let result = try repository.templates(cropKey: " tomato ", regionCode: "US-MN")
        #expect(result.count == 2)
        let broad = try #require(result.first { $0.id == "authority.tomato.mulch" })
        #expect(broad.version == 2)
        #expect(broad.cropKey == " Tomato ")
        #expect(broad.sourceURL.absoluteString == "https://example.org/tomatoes")
        #expect(broad.applicabilityLabel == "Broad guidance")
    }

    @Test("known exact region precedes broad templates and excludes another region")
    func filtersKnownRegion() throws {
        let repository = try BundledSeasonalCareTemplateRepository(data: Self.pack)
        let result = try repository.templates(cropKey: "tomato", regionCode: " us-mn ")
        #expect(result.map(\.id) == ["authority.tomato.mn-pruning", "authority.tomato.mulch"])

        let wrongRegion = try repository.templates(cropKey: "tomato", regionCode: "US-IA")
        #expect(wrongRegion.map(\.id) == ["authority.tomato.mulch"])
    }

    @Test("unknown region broadens reviewed rows for visible applicability labeling")
    func broadensUnknownRegion() throws {
        let repository = try BundledSeasonalCareTemplateRepository(data: Self.pack)
        let result = try repository.templates(cropKey: "tomato", regionCode: nil)
        #expect(result.map(\.id) == [
            "authority.tomato.mulch",
            "authority.tomato.ks-pruning",
            "authority.tomato.mn-pruning"
        ])
    }

    @Test("unknown crop has a manual fallback")
    func unknownCropIsEmpty() throws {
        let repository = try BundledSeasonalCareTemplateRepository(data: Self.pack)
        #expect(try repository.templates(cropKey: "cucumber", regionCode: nil).isEmpty)
        #expect(try repository.templates(cropKey: "", regionCode: nil).isEmpty)
    }

    @Test("corrupt and incomplete packs fail closed")
    func invalidResourcesFail() {
        #expect(throws: BundledSeasonalCareTemplateRepositoryError.invalidResource) {
            try BundledSeasonalCareTemplateRepository(data: Data("not json".utf8))
        }

        let missingURL = Self.packString.replacingOccurrences(of: "https://example.org/tomatoes", with: "http://example.org/tomatoes")
        #expect(throws: BundledSeasonalCareTemplateRepositoryError.invalidTemplate(index: 0, reason: "invalid source URL")) {
            try BundledSeasonalCareTemplateRepository(data: Data(missingURL.utf8))
        }

        let invalidStart = Self.packString
            .replacingOccurrences(of: "\"start_month\": 5", with: "\"start_month\": 4")
            .replacingOccurrences(of: "\"start_day\": 1", with: "\"start_day\": 31")
        #expect(throws: BundledSeasonalCareTemplateRepositoryError.invalidTemplate(index: 0, reason: "invalid annual window")) {
            try BundledSeasonalCareTemplateRepository(data: Data(invalidStart.utf8))
        }

        let invalidEnd = Self.packString
            .replacingOccurrences(of: "\"end_month\": 6", with: "\"end_month\": 2")
            .replacingOccurrences(of: "\"end_day\": 15", with: "\"end_day\": 30")
        #expect(throws: BundledSeasonalCareTemplateRepositoryError.invalidTemplate(index: 0, reason: "invalid annual window")) {
            try BundledSeasonalCareTemplateRepository(data: Data(invalidEnd.utf8))
        }
    }
}
