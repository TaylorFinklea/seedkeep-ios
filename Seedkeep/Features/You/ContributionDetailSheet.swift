import SwiftUI
import SwiftData
import SeedkeepKit

/// Phase 4D · read-only audit trail for a single catalog correction.
///
/// Presented as a sheet from `YouView`'s contributions section. Surfaces
/// the moderator's actual `ai_notes` verbatim (server-side CHECK caps at
/// 240 chars) so the user sees the reasoning behind any auto-apply or
/// dismissal. Status-specific affordances:
///
///   - `dismissed` with `dismissed_reason='ai_low_confidence'` →
///     "I'm sure — escalate to a human reviewer" button that POSTs to
///     `/escalate` and triggers a sync.
///   - Any terminal status → "Disagree? Tell us why" link that files a
///     free-form follow-up note (lands in the same `catalog_feedback`
///     table for admin review).
///   - "View seed" → prefers `SeedDetailView` when a `LocalSeed` matches
///     the correction's catalog id; falls back to a read-only
///     `CatalogDetailView` when the local seed has been deleted.
///
/// Spec: `.docs/ai/specs/2026-06-09-phase-4d-catalog-corrections-design.md`
/// §7 ("ContributionDetailSheet").
struct ContributionDetailSheet: View {
    /// SwiftData id of the correction row to surface. The sheet queries
    /// by id so it stays in sync with any background-pulled status
    /// transition (e.g. user taps Escalate, sync runs, row flips to
    /// `reviewed`, sheet refreshes without dismissing).
    let correctionID: String

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AuthController.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @Query private var correctionQuery: [LocalCatalogCorrection]
    @Query private var localSeedQuery: [LocalSeed]

    @State private var escalating = false
    @State private var escalateError: String?
    @State private var showDissentSheet = false

    init(correctionID: String) {
        self.correctionID = correctionID
        let id = correctionID
        _correctionQuery = Query(filter: #Predicate<LocalCatalogCorrection> { $0.id == id })
        // Local-seed lookup is keyed on the correction's `catalogSeedID`
        // — but `@Query` doesn't accept dependent predicates at init
        // time. We fetch every LocalSeed whose `catalogID` is non-nil
        // and filter in `localSeed` below; in practice library sizes are
        // small enough that the extra rows are negligible.
        _localSeedQuery = Query(filter: #Predicate<LocalSeed> {
            $0.catalogID != nil && $0.deletedAt == nil
        })
    }

    private var correction: LocalCatalogCorrection? { correctionQuery.first }

    /// LocalSeed that matches this correction's catalog id, if the user
    /// still has one in their library. Drives the "View seed" branching:
    /// when present we push `SeedDetailView`; when nil we push
    /// `CatalogDetailView` (read-only).
    private var localSeed: LocalSeed? {
        guard let catalogID = correction?.catalogSeedID else { return nil }
        return localSeedQuery.first(where: { $0.catalogID == catalogID })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let correction {
                    headerSection(correction)
                    valuesSection(correction)
                    statusSection(correction)
                    auditTrailSection(correction)
                    viewSeedSection(correction)
                    dissentSection(correction)
                } else {
                    Section {
                        Text("Contribution not found.")
                            .font(HerbFont.bodyItalic(size: 13))
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                }
            }
            .vellumForm()
            .navigationTitle("Contribution")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showDissentSheet) {
                if let correction {
                    DissentSheet(correction: correction)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(_ row: LocalCatalogCorrection) -> some View {
        Section {
            VStack(alignment: .leading, spacing: HerbSpace.tight) {
                Text(row.catalogSeedName ?? "Catalog entry")
                    .font(HerbFont.display(size: 24))
                    .foregroundStyle(HerbColor.ink)
                Text(fieldLabel(row.fieldName))
                    .font(HerbFont.bodyItalic(size: 13))
                    .foregroundStyle(HerbColor.sepia)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func valuesSection(_ row: LocalCatalogCorrection) -> some View {
        Section {
            LabeledContent("Your suggestion") {
                Text(row.suggestedValue)
                    .font(HerbFont.bodyEmph(size: 14))
            }
            if let seen = row.clientSeenValue, !seen.isEmpty {
                LabeledContent("Was") {
                    Text(seen)
                        .font(HerbFont.body(size: 14))
                        .foregroundStyle(HerbColor.inkSoft)
                }
            }
        } header: {
            Rubric(text: "value")
        }
    }

    @ViewBuilder
    private func statusSection(_ row: LocalCatalogCorrection) -> some View {
        Section {
            HStack(spacing: 10) {
                CorrectionStatusPill(status: row.status)
                Text(statusSubtext(row))
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
                Spacer()
            }
            if row.status == "dismissed" && row.dismissedReason == "ai_low_confidence" {
                escalateButton(row)
            }
        } header: {
            Rubric(text: "status")
        }
    }

    @ViewBuilder
    private func escalateButton(_ row: LocalCatalogCorrection) -> some View {
        Button {
            Task { await escalate(row) }
        } label: {
            HStack(spacing: 8) {
                if escalating {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
                Text("I'm sure — escalate to a human reviewer")
                    .font(HerbFont.bodyEmph(size: 14))
                    .foregroundStyle(HerbColor.sepia)
            }
        }
        .disabled(escalating)
        if let escalateError {
            Text(escalateError)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.rose)
        }
    }

    @ViewBuilder
    private func auditTrailSection(_ row: LocalCatalogCorrection) -> some View {
        Section {
            // Submitted
            auditRow(
                icon: "tray.and.arrow.down",
                title: "Submitted",
                detail: dateLabel(row.createdAt)
            )

            // AI moderator notes (verbatim, capped at 240 chars server-side).
            if let notes = row.aiNotes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: HerbSpace.tight) {
                    HStack(spacing: 8) {
                        Image(systemName: aiIcon(for: row))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HerbColor.sepia)
                        Text(aiHeader(for: row))
                            .font(HerbFont.bodyEmph(size: 13))
                            .foregroundStyle(HerbColor.ink)
                    }
                    Text(notes)
                        .font(HerbFont.body(size: 13))
                        .foregroundStyle(HerbColor.inkSoft)
                }
            }

            // Reviewed / Applied / Dismissed timestamps
            if let appliedAt = row.appliedAt {
                auditRow(icon: "checkmark.seal", title: "Auto-applied", detail: dateLabel(appliedAt))
            } else if let reviewedAt = row.reviewedAt, row.status == "reviewed" {
                auditRow(icon: "magnifyingglass", title: "Routed for human review", detail: dateLabel(reviewedAt))
            } else if let reviewedAt = row.reviewedAt, row.status == "dismissed" {
                auditRow(icon: "xmark.seal", title: "Dismissed", detail: dateLabel(reviewedAt))
            }
            if let escalatedAt = row.escalatedAt {
                auditRow(icon: "arrow.up.forward", title: "Escalated to human", detail: dateLabel(escalatedAt))
            }
        } header: {
            Rubric(text: "audit trail")
        }
    }

    @ViewBuilder
    private func auditRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HerbColor.sepia)
                .frame(width: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(HerbFont.bodyEmph(size: 13))
                    .foregroundStyle(HerbColor.ink)
                Text(detail)
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func viewSeedSection(_ row: LocalCatalogCorrection) -> some View {
        if let localSeed {
            Section {
                NavigationLink {
                    SeedDetailView(seedID: localSeed.id)
                } label: {
                    Label("View seed", systemImage: "leaf")
                        .font(HerbFont.body(size: 14))
                        .foregroundStyle(HerbColor.sepia)
                }
            }
        } else if let catalogID = row.catalogSeedID {
            Section {
                NavigationLink {
                    CatalogDetailView(catalogSeedID: catalogID)
                } label: {
                    Label("View catalog entry", systemImage: "doc.text")
                        .font(HerbFont.body(size: 14))
                        .foregroundStyle(HerbColor.sepia)
                }
            } footer: {
                Text("Your local seed for this contribution isn't in your library — showing the shared catalog entry.")
                    .font(HerbFont.bodyItalic(size: 11))
                    .foregroundStyle(HerbColor.inkFaint)
            }
        }
    }

    @ViewBuilder
    private func dissentSection(_ row: LocalCatalogCorrection) -> some View {
        if row.status == "applied" || row.status == "dismissed" {
            Section {
                Button {
                    showDissentSheet = true
                } label: {
                    Label("Disagree? Tell us why", systemImage: "bubble.left")
                        .font(HerbFont.body(size: 14))
                        .foregroundStyle(HerbColor.sepia)
                }
            } footer: {
                Text("Your note goes to the catalog reviewers — they'll fold it into the next moderation pass.")
                    .font(HerbFont.bodyItalic(size: 11))
                    .foregroundStyle(HerbColor.inkFaint)
            }
        }
    }

    // MARK: - Actions

    private func escalate(_ row: LocalCatalogCorrection) async {
        guard let catalogID = row.catalogSeedID else {
            escalateError = "Catalog entry is no longer available."
            return
        }
        escalating = true
        escalateError = nil
        defer { escalating = false }
        do {
            _ = try await appEnv.client.escalateDismissedCorrection(
                catalogID: catalogID,
                correctionID: row.id
            )
            // Trigger sync so the local row picks up the new
            // `status='reviewed'` + `escalated_at` and the audit-trail
            // section re-renders without dismissing the sheet.
            if case .signedIn(_, let household) = auth.state {
                await appEnv.sync.syncAll(householdID: household.id)
            }
        } catch {
            escalateError = humanizeError(error)
        }
    }

    // MARK: - Copy helpers

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
        case "sun_requirement":       return "sun requirement"
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

    private func statusSubtext(_ row: LocalCatalogCorrection) -> String {
        switch row.status {
        case "open":
            return "We're reviewing it."
        case "reviewed":
            return "Saved for human review."
        case "applied":
            return "Applied automatically."
        case "dismissed":
            return dismissedSubtext(row.dismissedReason)
        default:
            return ""
        }
    }

    private func dismissedSubtext(_ reason: String?) -> String {
        switch reason {
        case "ai_low_confidence":
            return "Our AI moderator wasn't confident."
        case "out_of_bounds":
            return "Outside the typical range."
        case "invalid_enum":
            return "Not a recognized value."
        case "concurrent_conflict":
            return "Conflicted with another open suggestion."
        case "recent_change":
            return "This field was already updated recently."
        case "catalog_entry_unavailable":
            return "The catalog entry was removed before review."
        case "user_withdrawn":
            return "You withdrew this suggestion."
        case "household_membership_revoked":
            return "Submitted from a household you're no longer in."
        case "user_escalated":
            return "Escalated to a human reviewer."
        default:
            return "Not applied."
        }
    }

    private func aiIcon(for row: LocalCatalogCorrection) -> String {
        if let score = row.aiReviewScore, score >= 0.85 {
            return "checkmark.bubble"
        }
        if let score = row.aiReviewScore, score < 0.30 {
            return "exclamationmark.bubble"
        }
        return "bubble.left"
    }

    private func aiHeader(for row: LocalCatalogCorrection) -> String {
        guard let score = row.aiReviewScore else { return "AI moderator" }
        if score >= 0.85 { return "AI moderator (high confidence)" }
        if score < 0.30 { return "AI moderator (low confidence)" }
        return "AI moderator"
    }

    private func dateLabel(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Dissent sheet

/// Lightweight free-form follow-up. Files a new `catalog_feedback` row
/// (no `field_name`) carrying the user's dissent text — lands in the
/// admin triage page alongside other free-form notes.
private struct DissentSheet: View {
    let correction: LocalCatalogCorrection

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @State private var noteText: String = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    var canSubmit: Bool {
        !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: HerbSpace.tight) {
                        Text("Tell us why")
                            .font(HerbFont.display(size: 22))
                            .foregroundStyle(HerbColor.ink)
                        if let name = correction.catalogSeedName {
                            Text("about your suggestion on \(name)")
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.inkSoft)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    TextField(
                        "e.g. \"My local farm has confirmed 70 days for this variety three years running.\"",
                        text: $noteText,
                        axis: .vertical
                    )
                    .font(HerbFont.body(size: 14))
                    .lineLimit(4...12)
                } header: {
                    Rubric(text: "your note")
                } footer: {
                    Text("Your note is private — only the catalog reviewers see who sent it.")
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkFaint)
                }
                if didSubmit {
                    Section {
                        Text("Thanks — your note is on its way.")
                            .font(HerbFont.bodyItalic(size: 13))
                            .foregroundStyle(HerbColor.sage)
                    }
                } else if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(HerbFont.bodyItalic(size: 12))
                            .foregroundStyle(HerbColor.rose)
                    }
                }
            }
            .vellumForm()
            .navigationTitle("Disagree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !didSubmit {
                        Button("Send") { Task { await submit() } }
                            .disabled(!canSubmit)
                    }
                }
            }
        }
    }

    private func submit() async {
        guard let catalogID = correction.catalogSeedID else {
            errorMessage = "Catalog entry is no longer available."
            return
        }
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Re: correction \(correction.id) [\(correction.fieldName)] — "
        do {
            _ = try await appEnv.client.submitCatalogFeedback(
                catalogID: catalogID,
                body: prefix + trimmed
            )
            didSubmit = true
        } catch {
            errorMessage = humanizeError(error)
        }
    }
}
