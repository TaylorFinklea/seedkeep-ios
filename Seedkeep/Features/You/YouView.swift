import SwiftUI
import SwiftData
import SeedkeepKit

/// Identity tab — restyled as "House". Who I am, who is my household,
/// sign out. Locations, tags, and household-invite flow live in Settings.
struct YouView: View {
    @Environment(AuthController.self) private var auth
    @State private var showSignOutConfirm = false
    @State private var selectedContribution: ContributionSelection?

    /// Phase 4D · the user's catalog corrections — newest first, capped
    /// at 20. Tombstones (`deletedAt != nil`) are filtered out so the
    /// list never shows household-membership-revoked rows.
    @Query(
        filter: #Predicate<LocalCatalogCorrection> { $0.deletedAt == nil },
        sort: \LocalCatalogCorrection.createdAt,
        order: .reverse
    )
    private var contributions: [LocalCatalogCorrection]

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                Form {
                    Section {
                        heading
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    if case .signedIn(let user, let household) = auth.state {
                        Section {
                            LabeledContent("Email") { Text(user.email ?? "no email yet").font(HerbFont.body(size: 14)) }
                            LabeledContent("Name") { Text(user.name ?? "no name yet").font(HerbFont.bodyEmph(size: 14)) }
                        } header: {
                            Rubric(text: "steward")
                        }
                        Section {
                            LabeledContent("Name") { Text(household.name).font(HerbFont.bodyEmph(size: 14)) }
                        } header: {
                            Rubric(text: "house")
                        }
                    }
                    contributionsSection
                    Section {
                        Button(role: .destructive) {
                            showSignOutConfirm = true
                        } label: {
                            Text("Sign out")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .confirmationDialog(
                    "Sign out of Seedkeep?",
                    isPresented: $showSignOutConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("You'll need to sign in again to sync your library.")
                }
                .sheet(item: $selectedContribution) { selection in
                    ContributionDetailSheet(correctionID: selection.id)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .publishesAssistantContext(pageType: "you")
        }
    }

    @ViewBuilder
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            FolioStrip(section: "House", folio: 1)
                .padding(.horizontal, -16)
            Text("House")
                .font(HerbFont.display(size: 38))
                .foregroundStyle(HerbColor.ink)
            Text(subtitle)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
            ScholarRule(verticalMargin: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headingAccessibilityLabel)
    }

    private var headingAccessibilityLabel: String {
        if case .signedIn(_, let household) = auth.state {
            return "House of \(household.name). \(subtitle)"
        }
        return "House. \(subtitle)"
    }

    private var subtitle: String {
        if case .signedIn(let user, let household) = auth.state {
            let stewardName = user.name?.split(separator: " ").first.map(String.init) ?? "Steward"
            return "House of \(household.name) · \(stewardName) is at the table"
        }
        return "House awaiting steward"
    }

    // MARK: - Contributions (Phase 4D)

    /// Newest-first list of catalog corrections the user has filed.
    /// Capped at 20 rows to keep the section scrolling reasonably; older
    /// rows remain reachable via the next-cursor delta pull when the
    /// section grows past the cap.
    @ViewBuilder
    private var contributionsSection: some View {
        Section {
            if contributions.isEmpty {
                Text("No corrections yet. Spot something wrong in a catalog entry? Tap Suggest a correction on its detail page.")
                    .font(HerbFont.bodyItalic(size: 13))
                    .foregroundStyle(HerbColor.inkSoft)
            } else {
                ForEach(Array(contributions.prefix(20)), id: \.id) { row in
                    Button {
                        selectedContribution = ContributionSelection(id: row.id)
                    } label: {
                        contributionRow(row)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Rubric(text: "your contributions")
        } footer: {
            Text("Only you can see your contributions list.")
                .font(HerbFont.bodyItalic(size: 11))
                .foregroundStyle(HerbColor.inkFaint)
        }
    }

    @ViewBuilder
    private func contributionRow(_ row: LocalCatalogCorrection) -> some View {
        VStack(alignment: .leading, spacing: HerbSpace.tight) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.catalogSeedName ?? "Catalog entry")
                    .font(HerbFont.bodyEmph(size: 14))
                    .foregroundStyle(HerbColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                CorrectionStatusPill(status: row.status)
                Text(relative(row.createdAt))
                    .font(HerbFont.bodyItalic(size: 11))
                    .foregroundStyle(HerbColor.inkFaint)
            }
            Text("\(fieldLabel(row.fieldName)) → \(row.suggestedValue)")
                .font(HerbFont.body(size: 13))
                .foregroundStyle(HerbColor.sepia)
                .lineLimit(1)
            Text(statusSubtext(row))
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func relative(_ ms: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000),
            relativeTo: Date()
        )
    }

    private func fieldLabel(_ field: String) -> String {
        switch field {
        case "days_to_germinate_min": return "days to germinate (min)"
        case "days_to_germinate_max": return "days to germinate (max)"
        case "days_to_maturity_min":  return "days to maturity (min)"
        case "days_to_maturity_max":  return "days to maturity (max)"
        case "soil_temp_min_f":       return "soil temp (min)"
        case "soil_temp_max_f":       return "soil temp (max)"
        case "seed_depth_inches":     return "seed depth"
        case "plant_spacing_inches":  return "plant spacing"
        case "row_spacing_inches":    return "row spacing"
        case "hardiness_zone_min":    return "hardiness zone (min)"
        case "hardiness_zone_max":    return "hardiness zone (max)"
        case "viability_years":       return "viability"
        case "sun_requirement":       return "sun"
        case "frost_tolerance":       return "frost tolerance"
        case "sow_method":            return "sow method"
        case "life_cycle":            return "life cycle"
        case "scientific_name":       return "scientific name"
        case "common_name":           return "common name"
        case "variety":               return "variety"
        case "company":               return "company"
        case "instructions":          return "instructions"
        default:                      return field.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Status-specific subtext under each contribution row. Mirrors the
    /// copy table in spec §7 (YouView contributions section).
    private func statusSubtext(_ row: LocalCatalogCorrection) -> String {
        switch row.status {
        case "open":
            return "We're reviewing it."
        case "reviewed":
            return "Saved for human review."
        case "applied":
            return "Applied automatically. Tap to see how we decided."
        case "dismissed":
            switch row.dismissedReason {
            case "ai_low_confidence":
                return "Outside our AI's confidence — tap to send to a human reviewer."
            case "out_of_bounds":
                return "Outside typical range — tap to send on for human review."
            case "invalid_enum":
                return "Not a recognized value — tap for details."
            case "catalog_entry_unavailable":
                return "Catalog entry was removed before we could review it."
            case "user_withdrawn":
                return "You withdrew this one."
            case "concurrent_conflict":
                return "Routed for human review — another suggestion landed at the same time."
            case "recent_change":
                return "Routed for human review — field was already updated recently."
            case "household_membership_revoked":
                return "Submitted from a household you're no longer in."
            case "user_escalated":
                return "Escalated to a human reviewer."
            default:
                return "Tap for details."
            }
        default:
            return ""
        }
    }
}

/// Tiny Identifiable wrapper so `.sheet(item:)` can present the
/// contribution-detail sheet keyed by correction id.
private struct ContributionSelection: Identifiable, Hashable {
    let id: String
}
