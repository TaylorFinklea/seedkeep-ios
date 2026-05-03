import SwiftUI
import SwiftData
import SeedkeepKit

/// One row in the Library list. Pulls the location name (if any) by id;
/// renders the year-packed warning badge when a packet is at least three
/// calendar years old (per `decisions.md`).
struct SeedRow: View {
    let seed: LocalSeed
    let locationName: String?
    let currentYear: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if seed.packetCount > 0 && seed.state != .wishlist {
                    Text("×\(seed.packetCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if let company = seed.customCompany?.nilIfBlank {
                    Text(company)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let location = locationName?.nilIfBlank {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let year = seed.yearPacked {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("packed \(String(year))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if seed.isOlderThanThresholdYears(currentYear: currentYear) {
                    Text("older — check")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: .capsule)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var displayTitle: String {
        let custom = seed.customName?.nilIfBlank
        let variety = seed.customVariety?.nilIfBlank
        switch (custom, variety) {
        case (.some(let n), .some(let v)) where n != v:
            return "\(n) — \(v)"
        case (.some(let n), _):
            return n
        case (.none, .some(let v)):
            return v
        default:
            return "Untitled seed"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
