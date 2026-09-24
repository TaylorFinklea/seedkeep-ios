import Foundation

public enum BundledSeasonalCareTemplateRepositoryError: Error, Equatable, Sendable {
    case missingResource
    case invalidResource
    case invalidTemplate(index: Int, reason: String)
}

/// Loads and filters the app's reviewed, read-only template pack.
public struct BundledSeasonalCareTemplateRepository: SeasonalCareTemplateRepository, Sendable {
    private let allTemplates: [SeasonalCareTemplate]

    public init(bundle: Bundle = .main, resourceName: String = "seasonal-care-templates") throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw BundledSeasonalCareTemplateRepositoryError.missingResource
        }
        do {
            let data = try Data(contentsOf: url)
            try self.init(data: data)
        } catch let error as BundledSeasonalCareTemplateRepositoryError {
            throw error
        } catch {
            throw BundledSeasonalCareTemplateRepositoryError.invalidResource
        }
    }

    public init(data: Data) throws {
        let decoded: [SeasonalCareTemplate]
        do {
            decoded = try JSONDecoder().decode([SeasonalCareTemplate].self, from: data)
        } catch {
            throw BundledSeasonalCareTemplateRepositoryError.invalidResource
        }
        for (index, template) in decoded.enumerated() {
            do {
                try Self.validate(template)
            } catch let error as ValidationError {
                throw BundledSeasonalCareTemplateRepositoryError.invalidTemplate(index: index, reason: error.reason)
            } catch {
                throw BundledSeasonalCareTemplateRepositoryError.invalidTemplate(index: index, reason: "invalid template")
            }
        }
        allTemplates = decoded
    }

    public func templates(cropKey: String, regionCode: String?) throws -> [SeasonalCareTemplate] {
        let crop = Self.normalize(cropKey)
        guard !crop.isEmpty else { return [] }

        let region = regionCode.map(Self.normalize).flatMap { $0.isEmpty ? nil : $0 }
        let cropMatches = allTemplates.filter { Self.normalize($0.cropKey) == crop }

        // A known region can use exact-region templates and broadly applicable
        // templates. A known mismatch never receives another region's timing.
        // When the home region is unknown, show the reviewed crop pack but let
        // the UI expose each row's applicability label before adding it.
        let filtered: [(SeasonalCareTemplate, Int)] = cropMatches.compactMap { template in
            let regions = Set(template.regionCodes.map(Self.normalize))
            let isAll = regions.contains("all")
            guard let region else {
                return (template, isAll ? 0 : 1)
            }
            guard isAll || regions.contains(region) else { return nil }
            return (template, isAll ? 1 : 0)
        }

        return filtered
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                let left = (Self.normalize($0.0.title), $0.0.id)
                let right = (Self.normalize($1.0.title), $1.0.id)
                return left < right
            }
            .map(\.0)
    }

    private struct ValidationError: Error {
        let reason: String
    }

    private static func validate(_ template: SeasonalCareTemplate) throws {
        guard !normalize(template.id).isEmpty else { throw ValidationError(reason: "missing id") }
        guard template.version > 0 else { throw ValidationError(reason: "invalid version") }
        guard !normalize(template.cropKey).isEmpty else { throw ValidationError(reason: "missing crop") }
        guard !template.regionCodes.isEmpty,
              template.regionCodes.allSatisfy({ !normalize($0).isEmpty })
        else { throw ValidationError(reason: "missing region") }
        guard !normalize(template.title).isEmpty else { throw ValidationError(reason: "missing title") }
        guard !normalize(template.instructions).isEmpty else { throw ValidationError(reason: "missing instructions") }
        guard (try? AnnualCareWindow(
            startMonth: template.startMonth,
            startDay: template.startDay,
            endMonth: template.endMonth,
            endDay: template.endDay
        )) != nil else { throw ValidationError(reason: "invalid annual window") }
        guard !normalize(template.authorityName).isEmpty else { throw ValidationError(reason: "missing authority") }
        guard !normalize(template.sourceTitle).isEmpty else { throw ValidationError(reason: "missing source title") }
        guard template.sourceURL.scheme?.lowercased() == "https",
              template.sourceURL.host != nil
        else { throw ValidationError(reason: "invalid source URL") }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
