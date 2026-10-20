import SwiftUI

/// Lets the user enter their 5-digit US ZIP code. The ZIP is looked up in the climate table bundled with the app,
/// offline, as the user types it. Save caches the zone, the frost dates and the coordinates in `AppPreferences`.
struct HomeLocationSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var zipText: String = ""
    @State private var lookup: Lookup = .none

    private enum Lookup: Equatable {
        case none
        case found(HomeClimate)
        case unknown
    }

    var body: some View {
        Form {
            Section {
                TextField("12345", text: $zipText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onChange(of: zipText) { _, new in
                        // Strip non-digit characters and cap at 5.
                        let digits = new.filter(\.isNumber)
                        if digits != new || new.count > 5 {
                            zipText = String(digits.prefix(5))
                        }
                        // A result for the previous entry is no longer the ZIP on screen.
                        lookup = .none
                    }
            } header: {
                Rubric(text: "zip code")
            } footer: {
                Text("Enter your home ZIP code. Seedkeep uses it to look up your USDA hardiness zone and average frost dates on this device.")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }

            switch lookup {
            case .none:
                EmptyView()
            case .found(let climate):
                Section {
                    LabeledContent("ZIP", value: climate.zip)
                    LabeledContent("USDA zone", value: "Zone \(climate.usdaZone)")
                    LabeledContent("Avg last frost", value: frostLabel(climate.avgLastFrost))
                    LabeledContent("Avg first frost", value: frostLabel(climate.avgFirstFrost))
                } header: {
                    Rubric(text: "location")
                } footer: {
                    Text("Frost dates are estimates for your hardiness zone, not measurements for your ZIP.")
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkSoft)
                }
            case .unknown:
                Section {
                    Text("We don't have climate data for that ZIP.")
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.rose)
                }
            }
        }
        .vellumForm()
        .navigationTitle("Home location")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
        .task(id: zipText) {
            await lookUp(zipText)
        }
        .onAppear {
            if zipText.isEmpty {
                zipText = appEnv.preferences.homeZip ?? ""
            }
        }
    }

    /// Looks the ZIP up off the main actor. The first lookup loads the bundled table, which is the only slow step.
    private func lookUp(_ zip: String) async {
        guard zip.count == 5 else {
            lookup = .none
            return
        }
        let climate = await Task.detached { ClimateLookup.climate(forZip: zip) }.value
        guard !Task.isCancelled else { return }
        lookup = climate.map { .found($0) } ?? .unknown
    }

    /// Only a ZIP that resolves and differs from the saved one can be saved.
    private var canSave: Bool {
        guard case .found(let climate) = lookup, climate.zip == zipText else { return false }
        return climate != appEnv.preferences.homeClimate
    }

    private func save() async {
        guard case .found(let climate) = lookup, climate.zip == zipText else { return }
        appEnv.preferences.saveHomeClimate(climate)
        // Phase 4C — coord generation bump + cache clear + refresh.
        await appEnv.weatherWarnings.invalidateLocation()
    }

    /// Converts a "MM-DD" frost date into a human-readable label like "Apr 1".
    private func frostLabel(_ mmdd: String) -> String {
        let parts = mmdd.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return mmdd
        }
        var comps = DateComponents()
        comps.month = month
        comps.day = day
        comps.year = Calendar.current.component(.year, from: Date())
        guard let date = Calendar.current.date(from: comps) else { return mmdd }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
