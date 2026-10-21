import Foundation

enum SeedsListEmptyState: Equatable {
    case noSeeds
    case noMatches
    case hasResults
}

enum SeedsListText {
    static func displayName(for row: SeedTableRow) -> String {
        nonBlank(row.name) ?? "Untitled seed"
    }

    /// The secondary display lines for a compact Seeds row.
    static func rowLines(for row: SeedTableRow) -> [String] {
        var lines: [String] = []
        let typeAndVariety = joined([row.type, row.variety])
        if !typeAndVariety.isEmpty { lines.append(typeAndVariety) }
        let companyAndYear = joined([row.company, row.year.map(String.init) ?? ""])
        if !companyAndYear.isEmpty { lines.append(companyAndYear) }
        return lines
    }

    static func accessibilityLabel(for row: SeedTableRow) -> String {
        var parts = [displayName(for: row)]
        parts.append(contentsOf: [row.type, row.variety, row.company].compactMap(nonBlank))
        if let year = row.year { parts.append(String(year)) }
        if row.verdict != nil, let verdict = nonBlank(row.verdictLabel) {
            parts.append(verdict)
        }
        return parts.joined(separator: ", ")
    }

    static func subtitle(total: Int, active: Int) -> String {
        "\(total) \(total == 1 ? "seed" : "seeds") · \(active) active"
    }

    static func emptyState(rowsInSelectedState: [SeedTableRow], searchMatches: [SeedTableRow]) -> SeedsListEmptyState {
        if rowsInSelectedState.isEmpty { return .noSeeds }
        return searchMatches.isEmpty ? .noMatches : .hasResults
    }

    private static func joined(_ values: [String]) -> String {
        values.compactMap(nonBlank).joined(separator: " · ")
    }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
