import SwiftUI
import SwiftData

/// Lets the user attach the entry to None (garden-level) / a Seed / a Bed /
/// a Planting event. Backing storage is three nullable IDs on the
/// LocalJournalEntry — exactly one (or zero) is set at a time.
///
/// Seeds and beds list every live row in the household. Plantings list the
/// latest 20, plus the selected one when it is older, so a pre-filled
/// planting always shows as selected. Labels match the Journal filter menu.
///
/// A selection that is no longer live (its seed, bed or planting was deleted)
/// stays visible as a disabled "(removed …)" row, so the selection is not
/// blank. The user can then pick "Garden (none)" to detach it.
struct AttachedEntityPicker: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Binding var seedID: String?
    @Binding var bedID: String?
    @Binding var plantingEventID: String?

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var allSeeds: [LocalSeed]
    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil }) private var allBeds: [LocalBed]
    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil }) private var allEvents: [LocalPlantingEvent]
    @State private var indexCache = JournalFeedCache()

    private var current: JournalTarget? {
        JournalAttachment(seedID: seedID, bedID: bedID, plantingEventID: plantingEventID).target
    }

    private var selection: Binding<JournalTarget?> {
        Binding(
            get: { current },
            set: { newValue in
                let attachment = JournalAttachment(newValue)
                seedID = attachment.seedID
                bedID = attachment.bedID
                plantingEventID = attachment.plantingEventID
            })
    }

    var body: some View {
        let entities = indexCache.entityIndex(
            householdID: appEnv.activeGardenHouseholdID,
            seeds: allSeeds,
            beds: allBeds,
            plantings: allEvents)
        Picker("Attached to", selection: selection) {
            Text("Garden (none)").tag(JournalTarget?.none)
            Section("Seeds") {
                ForEach(entities.seedOptions, id: \.target) { option in
                    Text(option.label).tag(Optional(option.target))
                }
            }
            Section("Beds") {
                ForEach(entities.bedOptions, id: \.target) { option in
                    Text(option.label).tag(Optional(option.target))
                }
            }
            Section("Recent plantings") {
                ForEach(recentPlantings(entities), id: \.target) { option in
                    Text(option.label).tag(Optional(option.target))
                }
            }
            if let removed = removedSelection(entities) {
                Section {
                    Text("(removed \(JournalFeedPresentation.kindName(removed)))")
                        .tag(Optional(removed))
                        .disabled(true)
                }
            }
        }
    }

    /// The latest 20 plantings, plus the selected planting when it is older than those.
    private func recentPlantings(_ entities: JournalEntityIndex) -> [JournalFilterOption] {
        var options = Array(entities.plantingOptions.prefix(20))
        if let plantingEventID,
           !options.contains(where: { $0.target == .plantingEvent(plantingEventID) }),
           let selected = entities.option(for: .plantingEvent(plantingEventID)) {
            options.append(selected)
        }
        return options
    }

    /// The selected seed, bed or planting when it is no longer live, so the picker can show it disabled.
    private func removedSelection(_ entities: JournalEntityIndex) -> JournalTarget? {
        guard let current, entities.option(for: current) == nil else { return nil }
        return current
    }
}
