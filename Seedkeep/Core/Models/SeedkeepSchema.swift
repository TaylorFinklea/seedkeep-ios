import Foundation
import SwiftData

/// Single source of truth for every `@Model` type in the app target.
///
/// `AppEnvironment.makeModelContainer` AND every test container build
/// their `Schema` from `SeedkeepSchema.all` — never from a hand-typed
/// list. The Phase 4C `LocalForecastSnapshot` regression (registered in
/// test schemas but missing from the production schema, so all
/// weather-warning persistence silently failed on device) is exactly the
/// drift this constant exists to prevent.
///
/// When adding a new `@Model`, add it here and nowhere else.
/// `SchemaRegistrationTests` walks the app image at runtime and fails if
/// any `PersistentModel` class is absent from this list.
enum SeedkeepSchema {
    static let all: [any PersistentModel.Type] = [
        LocalLocation.self,
        LocalTag.self,
        LocalSeed.self,
        LocalSeedPhoto.self,
        LocalBed.self,
        LocalPlantingEvent.self,
        LocalSyncCursor.self,
        LocalPendingWrite.self,
        LocalRecommendation.self,
        LocalJournalEntry.self,
        LocalJournalEntryPhoto.self,
        LocalJournalChecklistItem.self,
        LocalAssistantThread.self,
        LocalAssistantMessage.self,
        LocalAssistantToolCall.self,
        LocalAssistantKeyStatus.self,
        LocalPetMoodSnapshot.self,
        LocalPetDeparture.self,
        LocalCatalogCorrection.self,
        LocalForecastSnapshot.self,
    ]
}
