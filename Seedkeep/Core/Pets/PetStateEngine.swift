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
    /// The model lands in commit 3 — until then this always returns
    /// false. The lookup uses a string-keyed dynamic Swift type to
    /// avoid the compile-time dependency; once `LocalPetDeparture`
    /// lands the check converts to a typed fetch.
    ///
    /// (Commit 3 will replace this body with a `FetchDescriptor<LocalPetDeparture>`.)
    private static func hasDeparture(eventID: String, context: ModelContext) -> Bool {
        // Forward-compat stub. `LocalPetDeparture` does not yet exist;
        // departed-state is therefore impossible to reach via SwiftData
        // until commit 3 introduces both the model and the RPC that
        // writes it.
        return false
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
