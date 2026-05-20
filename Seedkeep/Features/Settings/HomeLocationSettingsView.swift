import SwiftUI
import SeedkeepKit

/// Lets the user enter their 5-digit US ZIP code so the server can resolve
/// it to a USDA hardiness zone, lat/lon, and average frost dates. The
/// resolved values are cached in `AppPreferences` so they're available on
/// cold launch without a network round-trip.
struct HomeLocationSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var zipText: String = ""
    @State private var saveState: SaveState = .idle

    private enum SaveState {
        case idle
        case loading
        case success(HouseholdLocationDTO)
        case error(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("12345", text: $zipText)
                    .keyboardType(.numberPad)
                    .onChange(of: zipText) { _, new in
                        // Strip non-digit characters and cap at 5.
                        let digits = new.filter(\.isNumber)
                        if digits != new || new.count > 5 {
                            zipText = String(digits.prefix(5))
                        }
                        // Reset feedback when the user edits the field.
                        if case .success = saveState { saveState = .idle }
                        if case .error = saveState { saveState = .idle }
                    }
            } header: {
                Text("ZIP code")
            } footer: {
                Text("Enter your home ZIP code. Seedkeep uses it to look up your USDA hardiness zone and average frost dates.")
            }

            if case .loading = saveState {
                Section {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Looking up…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if case .success(let location) = saveState {
                Section("Location resolved") {
                    LabeledContent("ZIP", value: location.zip)
                    LabeledContent("USDA zone", value: "Zone \(location.usdaZone)")
                    LabeledContent("Avg last frost", value: frostLabel(location.avgLastFrost))
                    LabeledContent("Avg first frost", value: frostLabel(location.avgFirstFrost))
                }
            }

            if case .error(let message) = saveState {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Home location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            if zipText.isEmpty {
                zipText = appEnv.preferences.homeZip ?? ""
            }
        }
    }

    private var canSave: Bool {
        if case .loading = saveState { return false }
        return zipText.count == 5
    }

    private func save() async {
        saveState = .loading
        do {
            let location = try await appEnv.client.setHouseholdLocation(zip: zipText)
            appEnv.preferences.homeZip = location.zip
            appEnv.preferences.cachedUsdaZone = location.usdaZone
            appEnv.preferences.cachedLatitude = location.latitude
            appEnv.preferences.cachedLongitude = location.longitude
            appEnv.recommendations.needsHomeLocation = false
            saveState = .success(location)
        } catch let err as SeedkeepError {
            switch err.code {
            case "invalid_zip":
                saveState = .error("That ZIP isn't a valid 5-digit code.")
            case "unknown_zip":
                saveState = .error("We don't have data for that ZIP yet.")
            default:
                saveState = .error("\(err.code): \(err.message)")
            }
        } catch {
            saveState = .error(error.localizedDescription)
        }
    }

    /// Converts a "MM-DD" frost date string from the server into a
    /// human-readable label like "Apr 1".
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
        return f.string(from: date)
    }
}
