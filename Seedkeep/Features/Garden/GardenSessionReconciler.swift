import SwiftUI
import SwiftData

/// Keeps a window's `GardenSession` in step with the store: resets it on sign-out or a garden
/// change, and clears a bed, event or brush seed that is gone. Applied once at the window root.
struct GardenSessionReconciler: ViewModifier {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AuthController.self) private var auth
    let session: GardenSession

    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil }) private var beds: [LocalBed]
    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil }) private var events: [LocalPlantingEvent]
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var seeds: [LocalSeed]

    func body(content: Content) -> some View {
        content
            .onChange(of: snapshot, initial: true) { _, snapshot in
                session.reconcile(snapshot)
            }
    }

    private var snapshot: GardenSession.Snapshot {
        let isSignedIn: Bool
        if case .signedIn = auth.state { isSignedIn = true } else { isSignedIn = false }
        return Self.snapshot(
            householdID: appEnv.activeGardenHouseholdID, isSignedIn: isSignedIn,
            beds: beds, events: events, seeds: seeds
        )
    }

    /// The snapshot for the store's rows: only live rows in `householdID` count.
    static func snapshot(
        householdID: String?,
        isSignedIn: Bool,
        beds: [LocalBed],
        events: [LocalPlantingEvent],
        seeds: [LocalSeed]
    ) -> GardenSession.Snapshot {
        let householdBeds = beds.filter { $0.householdID == householdID && $0.deletedAt == nil }
        return GardenSession.Snapshot(
            householdID: householdID,
            isSignedIn: isSignedIn,
            bedIDs: Set(householdBeds.map(\.id)),
            gridBedIDs: Set(householdBeds.filter {
                GardenGrid.size(widthFeet: $0.widthFeet, lengthFeet: $0.lengthFeet) != nil
            }.map(\.id)),
            eventIDs: Set(events.filter { $0.householdID == householdID && $0.deletedAt == nil }.map(\.id)),
            activeSeedIDs: Set(seeds.filter {
                $0.householdID == householdID && $0.deletedAt == nil && $0.state == .active
            }.map(\.id))
        )
    }
}
