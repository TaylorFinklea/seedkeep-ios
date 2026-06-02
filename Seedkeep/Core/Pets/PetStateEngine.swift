import Foundation
import SwiftData
import SeedkeepKit

/// Orchestrates per-pet day-ticks: runs `PetMoodResolver` + `MoodEngine`,
/// materializes the day's `LocalPetMoodSnapshot`, updates the iOS-local
/// streak counters (`petWiltedStreakDays`, `petLastMoodTickAt`), and
/// emits a `PetStateTransition` when the lifecycle phase has crossed a
/// boundary worth acting on (notification scheduling + the depart RPC
/// land in Phase 5.1.1 commits 3 + 4; this engine only **detects** the
/// transition).
///
/// Pure-deterministic given `(event row state, now)` — no global state,
/// no `Date()` reads at the leaves, no implicit clock. Tests pass a
/// frozen `now` and observe the SwiftData side effects + returned
/// transitions.
///
/// Lives on the main actor for the same reason `PetMoodResolver` does:
/// SwiftData `ModelContext` is not yet safe from background actors in
/// this codebase. Callers (`AppEnvironment.syncIfPossible`, future
/// `ScenePhase.active` wiring) hop to the main actor before invoking.
@MainActor
public enum PetStateEngine {
    /// Boundary crossings emitted by `tick`. The caller decides what to
    /// do with them — schedule notifications (5.1.4), POST `/depart`
    /// (5.1.1 commit 3), etc. `.recoveredToAlive` is silent per spec
    /// line 678 but exposed so the caller can cancel pending wilted
    /// notifications.
    public enum Transition: Sendable, Equatable {
        case aliveToWilted(eventID: String)
        case wiltedToDeparting(eventID: String)
        case departingToDeparted(eventID: String)
        case recoveredToAlive(eventID: String)
    }

    // MARK: - Public API

    /// Tick every alive pet (`petSeed != nil`, `completedAt == nil`,
    /// `deletedAt == nil`) in the household. Returns the union of
    /// transitions emitted across all pets — order matches the fetch.
    /// Errors during a per-pet tick are swallowed (the engine should
    /// never break the foreground/sync path).
    @discardableResult
    public static func tickAll(
        householdID: String,
        container: ModelContainer,
        now: Date = Date()
    ) -> [Transition] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalPlantingEvent>(
            predicate: #Predicate { event in
                event.householdID == householdID
                    && event.deletedAt == nil
                    && event.completedAt == nil
                    && event.petSeed != nil
            }
        )
        let events = (try? context.fetch(descriptor)) ?? []
        var transitions: [Transition] = []
        for event in events {
            if let t = tick(event: event, context: context, now: now) {
                transitions.append(t)
            }
        }
        try? context.save()
        return transitions
    }

    /// Tick a single planting event. Writes a `LocalPetMoodSnapshot`
    /// (one row per pet per calendar day, idempotent on
    /// `<eventID>::<YYYY-MM-DD>`), updates the iOS-local streak
    /// counters, and returns a `Transition` when the lifecycle phase
    /// changes. The caller is expected to `context.save()` (or rely on
    /// `tickAll`'s final save).
    ///
    /// Returns `nil` for terminal pets (graduated via `completedAt`,
    /// departed via a co-located `LocalPetDeparture` row) — see spec
    /// line 713's invariant. Departed-detection is forward-compat with
    /// the `LocalPetDeparture` model that lands in commit 3.
    @discardableResult
    public static func tick(
        event: LocalPlantingEvent,
        context: ModelContext,
        now: Date
    ) -> Transition? {
        // Terminal-state short-circuit (spec line 713). Graduated pets
        // never wilt; the streak counters must not advance.
        guard event.completedAt == nil else { return nil }
        guard event.deletedAt == nil else { return nil }
        guard event.petSeed != nil else { return nil }
        if hasDeparture(eventID: event.id, context: context) { return nil }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // 1) Resolve and score mood.
        let inputs = PetMoodResolver.resolveInputs(
            event: event,
            now: now,
            context: context
        )
        let result = MoodEngine.compute(inputs)
        let newLabel = result.label

        // 2) Snapshot for today. Idempotent via the unique key, but we
        //    still update an existing row's mood so a same-day re-tick
        //    reflects the latest score (the row's `dayYMD` is stable).
        writeSnapshot(
            eventID: event.id,
            dayYMD: dayYMDString(for: now),
            label: newLabel,
            composite: result.composite,
            createdAt: nowMs,
            context: context
        )

        // 3) Determine the previous lifecycle phase from the most
        //    recent prior snapshot. `PetStateEngine` does not store
        //    phase; the prior snapshot's label is the source of truth
        //    for "what state was this pet in before this tick".
        let priorLabel = mostRecentPriorMoodLabel(
            eventID: event.id,
            beforeDayYMD: dayYMDString(for: now),
            context: context
        )
        let priorPhase = phase(for: priorLabel)
        let newPhase = phase(for: newLabel)

        // 4) Streak-counter rule (spec line 685-692).
        let previousTick = event.petLastMoodTickAt
        let sameCalendarDay: Bool = {
            guard let prevMs = previousTick else { return false }
            let prev = Date(timeIntervalSince1970: TimeInterval(prevMs) / 1000)
            return Calendar.current.isDate(prev, inSameDayAs: now)
        }()

        if newLabel == .departingImminent {
            if !sameCalendarDay {
                event.petWiltedStreakDays += 1
                event.petLastMoodTickAt = nowMs
            }
            // Same-day repeated tick at .departingImminent: streak
            // stays, last-tick stays (rolling the timestamp would
            // arm the next cross-midnight tick to NOT increment).
        } else {
            event.petWiltedStreakDays = 0
            event.petLastMoodTickAt = nowMs
        }

        // 5) Determine effective phase post-streak. If we just hit
        //    `>= 5` consecutive day-ticks at `.departingImminent`, the
        //    pet has crossed into `.departed`.
        let effectivePhase: PetLifecyclePhase = {
            if newPhase == .departing && event.petWiltedStreakDays >= 5 {
                return .departed
            }
            return newPhase
        }()

        // 6) Emit transition. The cases that don't fire any side
        //    effect (mood drift within `.alive`, identical phase)
        //    return nil.
        return transition(from: priorPhase, to: effectivePhase, eventID: event.id)
    }

    // MARK: - Phase mapping

    /// Map a mood label to its lifecycle phase. `.alive` includes
    /// `.quiet` / `.content` / `.thriving` (spec line 665). Graduated
    /// and departed are terminal states resolved upstream — this map
    /// only handles the mood-derived non-terminal phases.
    static func phase(for label: PetMoodLabel?) -> PetLifecyclePhase {
        guard let label else { return .alive }
        switch label {
        case .thriving, .content, .quiet:
            return .alive
        case .wilted:
            return .wilted
        case .departingImminent:
            return .departing
        }
    }

    /// Build a `Transition` from a phase pair, or nil when no boundary
    /// worth emitting was crossed.
    private static func transition(
        from prior: PetLifecyclePhase,
        to current: PetLifecyclePhase,
        eventID: String
    ) -> Transition? {
        guard prior != current else { return nil }
        switch (prior, current) {
        case (.alive, .wilted):
            return .aliveToWilted(eventID: eventID)
        case (.wilted, .departing):
            return .wiltedToDeparting(eventID: eventID)
        case (.departing, .departed):
            return .departingToDeparted(eventID: eventID)
        case (.wilted, .alive), (.departing, .alive):
            return .recoveredToAlive(eventID: eventID)
        default:
            // Anything else (e.g. alive → departing without passing
            // through wilted on the previous tick) is unusual but
            // possible if mood collapses fast. Treat as "recovery is
            // silent" path's inverse: no notification needed at this
            // boundary, the next tick will surface it as
            // wilted → departing once the snapshot lands.
            return nil
        }
    }

    // MARK: - Snapshot read/write

    private static func writeSnapshot(
        eventID: String,
        dayYMD: String,
        label: PetMoodLabel,
        composite: Int,
        createdAt: Int64,
        context: ModelContext
    ) {
        let key = "\(eventID)::\(dayYMD)"
        let descriptor = FetchDescriptor<LocalPetMoodSnapshot>(
            predicate: #Predicate { snap in snap.id == key }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.moodLabel = label.rawValue
            existing.compositeScore = composite
            existing.createdAt = createdAt
        } else {
            context.insert(LocalPetMoodSnapshot(
                plantingEventID: eventID,
                dayYMD: dayYMD,
                moodLabel: label.rawValue,
                compositeScore: composite,
                createdAt: createdAt
            ))
        }
    }

    /// Most recent mood label strictly *before* the given day. Returns
    /// nil when no prior snapshot exists (first tick ever).
    private static func mostRecentPriorMoodLabel(
        eventID: String,
        beforeDayYMD: String,
        context: ModelContext
    ) -> PetMoodLabel? {
        var descriptor = FetchDescriptor<LocalPetMoodSnapshot>(
            predicate: #Predicate { snap in
                snap.plantingEventID == eventID && snap.dayYMD < beforeDayYMD
            },
            sortBy: [SortDescriptor(\.dayYMD, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
            .flatMap { PetMoodLabel(rawValue: $0.moodLabel) }
    }

    /// Cheap presence check for a co-located `LocalPetDeparture` row.
    /// Once a departure exists, the pet is terminal — `tick` must return
    /// early without writing snapshots or advancing streak counters
    /// (spec line 713). The lookup matches on `plantingEventID` since
    /// the `LocalPetDeparture` model uses that as its unique key.
    private static func hasDeparture(eventID: String, context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<LocalPetDeparture>(
            predicate: #Predicate { row in
                row.plantingEventID == eventID && row.deletedAt == nil
            }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    // MARK: - Side effects

    /// Run the side-effect step for a batch of transitions emitted by
    /// `tick`/`tickAll`. Today this covers the `.departingToDeparted`
    /// case only: POST to `/api/pets/:id/depart` (idempotent server-side
    /// so a duplicate from a sibling device or a re-tick is safe),
    /// upsert the returned `LocalPetDeparture`, and apply the bumped
    /// parent `LocalPlantingEvent` from the inline response so the
    /// `updated_at` advance is visible immediately.
    ///
    /// Notification scheduling (`.aliveToWilted`, `.departingToDeparted`)
    /// and the cancel-on-recovery branch are stubbed — Phase 5.1.4 wires
    /// the real `NotificationsCenter` helpers. The stubs document the
    /// hook points so the wiring doesn't drift.
    ///
    /// Failures from the depart RPC are swallowed: a transient network
    /// blip should leave the streak counters at 5 so the next foreground
    /// `tickAll` re-detects the boundary and retries the call. The
    /// server-side idempotency guarantee means a retry is cheap.
    public static func performSideEffects(
        for transitions: [Transition],
        client: SeedkeepClient,
        container: ModelContainer
    ) async {
        for transition in transitions {
            switch transition {
            case .departingToDeparted(let eventID):
                await runDepartureRPC(
                    eventID: eventID,
                    client: client,
                    container: container
                )
                // Phase 5.1.4: schedule
                //   `seedkeep.notif.pet.departed.<eventID>` (5s, gated).

            case .aliveToWilted:
                // Phase 5.1.4: schedule
                //   `seedkeep.notif.pet.wilted.<eventID>` (10s, gated).
                break

            case .recoveredToAlive:
                // Phase 5.1.4: cancel the pending wilted notification
                //   if one was scheduled.
                break

            case .wiltedToDeparting:
                // Visual change only per spec line 679 — no side effect.
                break
            }
        }
    }

    /// Calls `/api/pets/:id/depart` and upserts the response into
    /// SwiftData. Idempotent on the server: a duplicate call from a
    /// sibling device or a re-tick after a transient failure is a no-op
    /// that returns the same row.
    private static func runDepartureRPC(
        eventID: String,
        client: SeedkeepClient,
        container: ModelContainer
    ) async {
        do {
            let (event, departure) = try await client.requestPetDeparture(
                plantingEventID: eventID
            )
            let context = ModelContext(container)
            // Upsert the parent planting first so the bumped `updated_at`
            // is visible to the next sync round (this matches what the
            // delta-sync pull would write anyway — landing it inline
            // saves a UI flicker).
            let parentDescriptor = FetchDescriptor<LocalPlantingEvent>(
                predicate: #Predicate { $0.id == eventID }
            )
            if let parent = try? context.fetch(parentDescriptor).first {
                event.apply(to: parent)
            }
            // Upsert the departure row.
            let depDescriptor = FetchDescriptor<LocalPetDeparture>(
                predicate: #Predicate { $0.plantingEventID == eventID }
            )
            let goodbyeJSON = departure.goodbye_note
            let fallback = departure.decodedGoodbyeNote()?.fallback ?? false
            if let existing = try? context.fetch(depDescriptor).first {
                existing.goodbyeNoteJSON = goodbyeJSON
                existing.reason = departure.reason
                existing.fallback = fallback
                existing.createdAt = departure.created_at
                existing.updatedAt = departure.updated_at
                existing.departedAt = departure.departed_at
                existing.deletedAt = departure.deleted_at
            } else {
                context.insert(LocalPetDeparture(
                    plantingEventID: departure.planting_event_id,
                    goodbyeNoteJSON: goodbyeJSON,
                    reason: departure.reason,
                    fallback: fallback,
                    createdAt: departure.created_at,
                    updatedAt: departure.updated_at,
                    departedAt: departure.departed_at,
                    deletedAt: departure.deleted_at
                ))
            }
            try? context.save()
        } catch {
            // Swallowed deliberately — the streak counter is still at 5,
            // so the next `tickAll` (foreground or sync completion) will
            // re-detect the same boundary and retry. The server route is
            // idempotent so the retry costs nothing if a partial write
            // happened on the prior attempt.
        }
    }

    // MARK: - Time helpers

    /// `YYYY-MM-DD` in the device's local calendar — matches the
    /// convention `LocalPetMoodSnapshot.dayYMD` already enforces and
    /// what `PetMoodResolver` uses internally.
    private static func dayYMDString(for date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
