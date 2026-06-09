import Foundation

// MARK: - Cross-component notification names (Phase 4D+)

/// In-process NotificationCenter names used to fan changes from the
/// sync engine into the local notification orchestrators
/// (`CatalogCorrectionNotifier`, future siblings). Frost / heat / water
/// reuse `weatherWarningsActivePlantingsChanged`, defined in
/// `WeatherWarningsService.swift`.
extension Notification.Name {
    /// Phase 4D — posted by `SyncEngine` after `upsertCatalogCorrections`
    /// detects one or more `open`/`reviewed` → `applied`/`dismissed`
    /// status transitions. `userInfo["transitionedIDs"]` carries the
    /// `[String]` of transitioned correction ids.
    ///
    /// `CatalogCorrectionNotifier` debounces these (100ms
    /// cancel-prior-Task) into one schedule pass so a bulk-resync of
    /// 20 transitions collapses to a single notification batch.
    static let catalogCorrectionsChanged =
        Notification.Name("seedkeep.catalogCorrections.changed")
}
