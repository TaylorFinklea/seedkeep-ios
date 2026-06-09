import Foundation
import SwiftData
import SeedkeepKit

/// Phase 4D — orchestrator that turns `SyncEngine` status-transition
/// posts into user-facing local notifications, deduped across devices
/// via the server-side `catalog_correction_notifications` ledger.
///
/// Wired at app init alongside `WeatherWarningsService.start()`. The
/// notifier observes `.catalogCorrectionsChanged`, debounces 100ms
/// (cancel-prior-Task — bulk-resync batches collapse to one schedule
/// pass), then for each transitioned id:
///
/// 1. Honors the `seedkeep.notif.catalog` UserDefaults toggle BEFORE
///    asking the system for authorization, so a disabled toggle never
///    prompts.
/// 2. Calls `GET /api/catalog/corrections/:id/notified` — if this
///    device's id is already in the ledger, skip. First writer wins.
/// 3. Coalesces to a single roundup ping when a batch surfaces more
///    than 3 transitions; otherwise schedules per-correction pings.
/// 4. `POST /api/catalog/corrections/:id/notified` before scheduling so
///    a sibling device on the same account doesn't double-ping. Marking
///    first wins races against a near-simultaneous sibling device — the
///    schedule call's `ensureGranted()` can stall in fresh process
///    environments, but the ledger write doesn't depend on it.
///
/// Spec: `.docs/ai/specs/2026-06-09-phase-4d-catalog-corrections-design.md`
/// §4 (iOS Notifications block), §7 (notifications), §8 Act 4.
@MainActor
final class CatalogCorrectionNotifier {

    static let shared = CatalogCorrectionNotifier()

    /// UserDefaults key holding this device's stable id for the
    /// cross-device ledger. We mint a UUID on first read and cache it
    /// — the ledger never needs the OS `identifierForVendor` (which is
    /// volatile across uninstall) and a long-lived UUID is enough to
    /// dedup multiple installs on one Apple ID.
    private static let deviceIDDefaultsKey = "seedkeep.notif.catalog.deviceID"

    /// Threshold above which a batch coalesces to one roundup ping
    /// instead of N per-correction pings. Spec §7.
    private static let roundupThreshold = 3

    private var client: SeedkeepClient?
    private var container: ModelContainer?
    private var observerToken: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    /// Accumulates transitioned ids across debounce window posts so a
    /// burst of 5 posts within 100ms still feeds the scheduler the
    /// full set when it fires.
    private var pendingIDs: [String] = []
    private var started = false

    private init() {}

    /// Wires the singleton's client + container and (on first call)
    /// registers the `.catalogCorrectionsChanged` observer. Subsequent
    /// calls re-wire the dependencies but skip the observer registration
    /// — the app's `AppEnvironment.live()` calls this once at launch,
    /// and the test harness calls it again to override the wired client
    /// with a routed mock URL session.
    func start(client: SeedkeepClient, container: ModelContainer) {
        // Always update wired deps — tests need to override the
        // production client/container the host-app's AppEnvironment
        // installed at launch.
        self.client = client
        self.container = container

        guard !started else { return }
        started = true

        // Register the default-true value for the user-facing toggle
        // BEFORE any read site checks it. `@AppStorage` and
        // `UserDefaults.bool(forKey:)` both return the registered
        // default when the user has never explicitly set the key, so
        // a fresh install starts with corrections-notifications on.
        UserDefaults.standard.register(defaults: [
            "seedkeep.notif.catalog": true
        ])

        observerToken = NotificationCenter.default.addObserver(
            forName: .catalogCorrectionsChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Pull the ids out on the posting thread (cheap — they're
            // already in the userInfo dictionary) then hop to
            // MainActor where the notifier lives.
            let ids = (notification.userInfo?["transitionedIDs"] as? [String]) ?? []
            guard !ids.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.enqueueTransitions(ids)
            }
        }
    }

    /// Returns (and lazily mints) this device's stable id used by the
    /// cross-device notification ledger.
    static func currentDeviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDDefaultsKey),
           !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIDDefaultsKey)
        return fresh
    }

    /// Add a fresh batch of transitioned ids to the pending set and
    /// (re-)arm the 100ms debounce. Cancel-prior-Task pattern: every
    /// post cancels the in-flight debounce Task before scheduling a
    /// new one, so 5 posts within 100ms collapse to a single schedule
    /// pass.
    private func enqueueTransitions(_ ids: [String]) {
        // Append without dedupe here — the schedule pass dedupes by
        // looking up local rows; preserving order keeps the
        // "applied vs dismissed" counts correct for the roundup body.
        pendingIDs.append(contentsOf: ids)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            await self?.flushPending()
        }
    }

    /// Snapshot the pending set, clear it, and dispatch one schedule
    /// pass. Runs after the debounce timer elapses.
    private func flushPending() async {
        let batch = pendingIDs
        pendingIDs = []
        guard !batch.isEmpty else { return }
        await scheduleBatch(ids: batch)
    }

    /// Reads local rows for the transitioned ids, applies the
    /// UserDefaults gate + cross-device ledger check per id, then
    /// either fans out per-correction pings or coalesces into a
    /// roundup. POSTs to the ledger after scheduling so a sibling
    /// device skips on the next sync.
    private func scheduleBatch(ids: [String]) async {
        guard UserDefaults.standard.bool(forKey: "seedkeep.notif.catalog") else { return }
        guard let client, let container else { return }

        // Snapshot local rows by id. Rows may have already been
        // tombstoned between the sync post and this flush; skip ids
        // we can no longer resolve.
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalCatalogCorrection>()
        let allRows = (try? context.fetch(descriptor)) ?? []
        var byID: [String: LocalCatalogCorrection] = [:]
        for row in allRows { byID[row.id] = row }

        // De-dupe ids within this batch — a burst can repeat ids
        // (each sync post carries its own transition list). Preserve
        // first-seen order so the roundup counts stay deterministic.
        var seen = Set<String>()
        var orderedIDs: [String] = []
        for id in ids where seen.insert(id).inserted { orderedIDs.append(id) }

        // Cross-device ledger pre-check. Run sequentially so a 429
        // doesn't pile up retry work in parallel; the spec's wire
        // contract is "first writer wins" and that's resilient to
        // serial reads.
        let deviceID = Self.currentDeviceID()
        var eligible: [(row: LocalCatalogCorrection, status: String)] = []
        for id in orderedIDs {
            guard let row = byID[id] else { continue }
            // A row could have flipped back open between sync &
            // flush; only ping on terminal states.
            guard row.status == "applied" || row.status == "dismissed" else { continue }
            let devices: [String]
            do {
                devices = try await client.catalogCorrectionNotified(correctionID: id)
            } catch {
                // Ledger fetch failed — better to silently skip than
                // double-ping a sibling device. The user still sees
                // the new row in YouView.
                continue
            }
            if devices.contains(deviceID) { continue }
            eligible.append((row, row.status))
        }

        guard !eligible.isEmpty else { return }

        let appliedCount = eligible.filter { $0.status == "applied" }.count
        let dismissedCount = eligible.filter { $0.status == "dismissed" }.count

        // Mark each eligible row in the ledger BEFORE scheduling so a
        // sibling device on the same account skips on its next sync.
        // Marking first strengthens the first-writer-wins dedup contract
        // against a near-simultaneous race on a second device — the
        // alternative ordering (mark after schedule) was an artifact of
        // the incorrect assumption that scheduling is cheap, but
        // `ensureGranted()` can stall on `requestAuthorization()` in
        // fresh test/process environments. Best-effort: a failure here
        // is logged silently — the worst outcome is a sibling device
        // also pings the user.
        for entry in eligible {
            do {
                try await client.markCatalogCorrectionNotified(
                    correctionID: entry.row.id,
                    deviceID: deviceID
                )
            } catch {
                continue
            }
        }

        if eligible.count > Self.roundupThreshold {
            await NotificationsCenter.shared.scheduleCatalogCorrectionRoundup(
                applied: appliedCount,
                dismissed: dismissedCount,
                ids: eligible.map { $0.row.id }
            )
        } else {
            for entry in eligible {
                let row = entry.row
                let fieldLabel = Self.fieldLabel(for: row)
                await NotificationsCenter.shared.scheduleCatalogCorrectionPing(
                    correctionID: row.id,
                    newStatus: row.status,
                    catalogSeedName: row.catalogSeedName ?? "your catalog entry",
                    fieldLabel: fieldLabel,
                    dismissedReason: row.dismissedReason
                )
            }
        }
    }

    /// Compose the per-correction `fieldLabel` used in the
    /// single-correction body. For `applied` rows we include the new
    /// value from `applied_patch`; for `dismissed` rows we show the
    /// user's suggested value so the lock-screen copy still anchors
    /// what changed.
    private static func fieldLabel(for row: LocalCatalogCorrection) -> String {
        let humanField = humanize(row.fieldName)
        let value: String?
        if row.status == "applied", let newValue = row.appliedNewValue, !newValue.isEmpty {
            value = newValue
        } else if row.status == "dismissed" {
            value = row.suggestedValue.isEmpty ? nil : row.suggestedValue
        } else {
            value = nil
        }
        if let value {
            return "\(humanField) → \(value)"
        }
        return humanField
    }

    private static func humanize(_ snakeCase: String) -> String {
        snakeCase.replacingOccurrences(of: "_", with: " ")
    }
}
