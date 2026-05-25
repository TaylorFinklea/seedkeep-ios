import SwiftUI
import SwiftData

/// Lets the user attach the entry to None (garden-level) / a Seed / a Bed /
/// a Planting event. Backing storage is three nullable IDs on the
/// LocalJournalEntry — exactly one (or zero) is set at a time.
struct AttachedEntityPicker: View {
    @Binding var seedID: String?
    @Binding var bedID: String?
    @Binding var plantingEventID: String?

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil },
           sort: \.customName) private var seeds: [LocalSeed]
    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil },
           sort: \.sortOrder) private var beds: [LocalBed]
    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil },
           sort: \.plannedFor, order: .reverse) private var events: [LocalPlantingEvent]

    enum Choice: Hashable {
        case none
        case seed(String)
        case bed(String)
        case plantingEvent(String)
    }

    private var current: Choice {
        if let id = seedID { return .seed(id) }
        if let id = bedID { return .bed(id) }
        if let id = plantingEventID { return .plantingEvent(id) }
        return .none
    }

    var body: some View {
        Picker("Attached to", selection: Binding(
            get: { current },
            set: { newValue in
                seedID = nil
                bedID = nil
                plantingEventID = nil
                switch newValue {
                case .none: break
                case .seed(let id): seedID = id
                case .bed(let id): bedID = id
                case .plantingEvent(let id): plantingEventID = id
                }
            }
        )) {
            Text("Garden (none)").tag(Choice.none)
            Section("Seeds") {
                ForEach(seeds) { s in
                    Text(s.customName ?? "Unnamed seed").tag(Choice.seed(s.id))
                }
            }
            Section("Beds") {
                ForEach(beds) { b in
                    Text(b.name).tag(Choice.bed(b.id))
                }
            }
            Section("Recent plantings") {
                ForEach(Array(events.prefix(20))) { e in
                    Text("\(e.kindRaw) · \(e.plannedFor)")
                        .tag(Choice.plantingEvent(e.id))
                }
            }
        }
    }
}
