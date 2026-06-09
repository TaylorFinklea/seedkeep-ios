import SwiftUI
import SeedkeepKit

/// Phase 4D · read-only catalog entry view keyed by `catalog_seed_id`.
///
/// Surfaces when a contribution's local `LocalSeed` has been deleted but
/// the correction row still references the (still-published) catalog
/// entry. The audit trail's "View seed" affordance falls back here
/// instead of pushing `SeedDetailView`, which would otherwise crash on a
/// missing local row.
///
/// No editing affordances — this view is informational only. If the
/// catalog entry itself has been unpublished or removed server-side,
/// renders a "Seed unavailable" placeholder rather than an error toast.
///
/// Spec: `.docs/ai/specs/2026-06-09-phase-4d-catalog-corrections-design.md`
/// §7 ("View seed navigation").
struct CatalogDetailView: View {
    /// Server-side catalog seed id. Stable across devices; the same id
    /// the correction row carries.
    let catalogSeedID: String

    @Environment(AppEnvironment.self) private var appEnv

    @State private var catalog: CatalogSeedDTO?
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        Form {
            if loading {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Loading catalog entry…")
                            .font(HerbFont.bodyItalic(size: 13))
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                }
            } else if let catalog {
                identitySection(catalog)
                growingInfoSection(catalog)
                if let instructions = catalog.instructions, !instructions.isEmpty {
                    instructionsSection(instructions)
                }
            } else {
                unavailableSection
            }
        }
        .vellumForm()
        .navigationTitle(catalog?.common_name ?? "Catalog entry")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: catalogSeedID) {
            await load()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func identitySection(_ c: CatalogSeedDTO) -> some View {
        Section {
            LabeledContent("Common name") {
                Text(c.common_name)
                    .font(HerbFont.bodyEmph(size: 14))
            }
            if let sci = c.scientific_name, !sci.isEmpty {
                LabeledContent("Scientific name") {
                    Text(sci)
                        .font(HerbFont.bodyItalic(size: 14))
                }
            }
            if let variety = c.variety, !variety.isEmpty {
                LabeledContent("Variety") {
                    Text(variety)
                        .font(HerbFont.body(size: 14))
                }
            }
            if let company = c.company, !company.isEmpty {
                LabeledContent("Company") {
                    Text(company)
                        .font(HerbFont.body(size: 14))
                }
            }
        } header: {
            Rubric(text: "identity")
        } footer: {
            Text("Read-only view of the shared catalog entry. The local seed for this contribution is no longer in your library.")
                .font(HerbFont.bodyItalic(size: 11))
                .foregroundStyle(HerbColor.inkFaint)
        }
    }

    @ViewBuilder
    private func growingInfoSection(_ c: CatalogSeedDTO) -> some View {
        Section {
            if let germ = numericRange(min: c.days_to_germinate_min, max: c.days_to_germinate_max, unit: "days") {
                LabeledContent("Days to germinate") { Text(germ).font(HerbFont.body(size: 14)) }
            }
            if let mature = numericRange(min: c.days_to_maturity_min, max: c.days_to_maturity_max, unit: "days") {
                LabeledContent("Days to maturity") { Text(mature).font(HerbFont.body(size: 14)) }
            }
            if let soil = numericRange(min: c.soil_temp_min_f, max: c.soil_temp_max_f, unit: "°F") {
                LabeledContent("Soil temp") { Text(soil).font(HerbFont.body(size: 14)) }
            }
            if let depth = c.seed_depth_inches {
                LabeledContent("Seed depth") { Text("\(formatNumber(depth)) in").font(HerbFont.body(size: 14)) }
            }
            if let plant = c.plant_spacing_inches {
                LabeledContent("Plant spacing") { Text("\(plant) in").font(HerbFont.body(size: 14)) }
            }
            if let row = c.row_spacing_inches {
                LabeledContent("Row spacing") { Text("\(row) in").font(HerbFont.body(size: 14)) }
            }
            if let zones = numericRange(min: c.hardiness_zone_min, max: c.hardiness_zone_max, unit: nil) {
                LabeledContent("Hardiness zones") { Text(zones).font(HerbFont.body(size: 14)) }
            }
            if let years = c.viability_years {
                LabeledContent("Viability") { Text("\(years) years").font(HerbFont.body(size: 14)) }
            }
            if let sun = c.sun_requirement, !sun.isEmpty {
                LabeledContent("Sun") { Text(sun).font(HerbFont.body(size: 14)) }
            }
            if let frost = c.frost_tolerance, !frost.isEmpty {
                LabeledContent("Frost tolerance") { Text(frost).font(HerbFont.body(size: 14)) }
            }
            if let sow = c.sow_method, !sow.isEmpty {
                LabeledContent("Sow method") { Text(sow).font(HerbFont.body(size: 14)) }
            }
            if let cycle = c.life_cycle, !cycle.isEmpty {
                LabeledContent("Life cycle") { Text(cycle).font(HerbFont.body(size: 14)) }
            }
        } header: {
            Rubric(text: "growing info")
        }
    }

    @ViewBuilder
    private func instructionsSection(_ instructions: String) -> some View {
        Section {
            Text(instructions)
                .font(HerbFont.body(size: 14))
                .foregroundStyle(HerbColor.ink)
        } header: {
            Rubric(text: "instructions")
        }
    }

    @ViewBuilder
    private var unavailableSection: some View {
        Section {
            VStack(alignment: .leading, spacing: HerbSpace.tight) {
                Text("Seed unavailable")
                    .font(HerbFont.bodyEmph(size: 14))
                    .foregroundStyle(HerbColor.ink)
                Text(loadError ?? "This catalog entry isn't available anymore — it may have been removed before we could surface it.")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Helpers

    private func load() async {
        loading = true
        loadError = nil
        do {
            let result = try await appEnv.client.catalogByID(catalogSeedID)
            catalog = result
        } catch {
            catalog = nil
            loadError = humanizeError(error)
        }
        loading = false
    }

    private func numericRange<T: CustomStringConvertible>(min lo: T?, max hi: T?, unit: String?) -> String? {
        switch (lo, hi) {
        case let (.some(a), .some(b)):
            let unitSuffix = unit.map { " \($0)" } ?? ""
            return "\(a)–\(b)\(unitSuffix)"
        case let (.some(a), nil):
            let unitSuffix = unit.map { " \($0)" } ?? ""
            return "\(a)\(unitSuffix)"
        case let (nil, .some(b)):
            let unitSuffix = unit.map { " \($0)" } ?? ""
            return "\(b)\(unitSuffix)"
        case (nil, nil):
            return nil
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}
