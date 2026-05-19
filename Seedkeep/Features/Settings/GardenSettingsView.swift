import SwiftUI
import SeedkeepKit

/// Phase 2B garden-aware settings. Stored locally per device; user
/// enters frost dates and hardiness zone manually. Phase 2C will add
/// ZIP-based auto-suggest.
struct GardenSettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var hasLastFrost: Bool = false
    @State private var lastFrostDate: Date = Date()
    @State private var hasFirstFrost: Bool = false
    @State private var firstFrostDate: Date = Date()
    @State private var hardinessZone: Int = 6

    var body: some View {
        Form {
            Section {
                Toggle("Set last frost date", isOn: $hasLastFrost)
                if hasLastFrost {
                    DatePicker(
                        "Last frost",
                        selection: $lastFrostDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                }
            } header: {
                Text("Spring frost")
            } footer: {
                Text("Used to warn you about scheduling tender plants too early. The year is ignored — only the month and day matter.")
            }

            Section {
                Toggle("Set first frost date", isOn: $hasFirstFrost)
                if hasFirstFrost {
                    DatePicker(
                        "First frost",
                        selection: $firstFrostDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                }
            } header: {
                Text("Fall frost")
            } footer: {
                Text("Phase 2C will use this to backsolve indoor-start dates from a packet's days-to-maturity.")
            }

            Section {
                Picker("USDA hardiness zone", selection: $hardinessZone) {
                    ForEach(1...13, id: \.self) { zone in
                        Text("Zone \(zone)").tag(zone)
                    }
                }
                Button {
                    autoFillFromZone()
                } label: {
                    Label("Auto-fill frost dates from zone", systemImage: "wand.and.sparkles")
                }
            } footer: {
                Text("Auto-fill uses agronomic averages for your zone as a starting point. Your specific microclimate may be a week or two earlier or later — adjust the dates above once you know your site.")
            }
        }
        .navigationTitle("Garden settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadFromPreferences() }
        .onChange(of: hasLastFrost) { _, _ in commit() }
        .onChange(of: lastFrostDate) { _, _ in commit() }
        .onChange(of: hasFirstFrost) { _, _ in commit() }
        .onChange(of: firstFrostDate) { _, _ in commit() }
        .onChange(of: hardinessZone) { _, _ in commitZone() }
    }

    private func loadFromPreferences() {
        let cal = Calendar.current
        let now = Date()
        if let last = appEnv.preferences.lastFrost,
           let date = last.date(inYear: cal.component(.year, from: now)) {
            hasLastFrost = true
            lastFrostDate = date
        }
        if let first = appEnv.preferences.firstFrost,
           let date = first.date(inYear: cal.component(.year, from: now)) {
            hasFirstFrost = true
            firstFrostDate = date
        }
        if let zone = appEnv.preferences.hardinessZone {
            hardinessZone = zone
        }
    }

    private func commit() {
        let cal = Calendar.current
        appEnv.preferences.lastFrost = hasLastFrost
            ? MonthDay(month: cal.component(.month, from: lastFrostDate),
                       day: cal.component(.day, from: lastFrostDate))
            : nil
        appEnv.preferences.firstFrost = hasFirstFrost
            ? MonthDay(month: cal.component(.month, from: firstFrostDate),
                       day: cal.component(.day, from: firstFrostDate))
            : nil
    }

    private func commitZone() {
        appEnv.preferences.hardinessZone = hardinessZone
    }

    /// Fill in last/first frost dates from the agronomic-baseline table
    /// for the currently-selected zone. Overwrites any previously-set
    /// dates — this is intended as a "rough draft" the user refines.
    private func autoFillFromZone() {
        guard let frost = HardinessZoneFrostData.dates(for: hardinessZone) else { return }
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        if let lastDate = frost.last.date(inYear: year, calendar: cal) {
            hasLastFrost = true
            lastFrostDate = lastDate
        }
        if let firstDate = frost.first.date(inYear: year, calendar: cal) {
            hasFirstFrost = true
            firstFrostDate = firstDate
        }
        commit()
    }
}
