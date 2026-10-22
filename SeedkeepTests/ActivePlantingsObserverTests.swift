import Testing
import Foundation
import os
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Layer 5 — exercises the `NotificationCenter.default` glue between
/// `SyncEngine` and `WeatherWarningsService`. When the engine performs
/// `enqueueCreate / enqueueUpdate / enqueueDelete` for a planting event,
/// it posts `.weatherWarningsActivePlantingsChanged` — the service's
/// debounced observer should fire.
///
/// We don't drive the service's observer directly here (the service's
/// 300ms debounce + actor isolation makes that a flaky-timing test).
/// Instead we attach a synchronous `NotificationCenter` observer in the
/// test and assert the post itself happens. Service-side debounce
/// behavior is covered in `WeatherWarningsServiceTests`.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §11 (Layer 5 — ActivePlantingsObserverTests).
@MainActor
@Suite("ActivePlantingsObserver — Phase 4C SyncEngine post integration", .serialized)
struct ActivePlantingsObserverTests {

    private static let householdID = "hh_obs_test"

    private static func makeContainer() -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "activePlantingsObserverTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        return try! ModelContainer(for: schema, configurations: config)
    }

    // MARK: - Tests

    @Test("enqueueCreatePlantingEvent posts .weatherWarningsActivePlantingsChanged")
    func createPlantingEventPostsNotification() async throws {
        let container = Self.makeContainer()
        let engine = SyncEngine(container: container)

        // Observer state — assigned BEFORE `enqueueCreate` so the post
        // can't race the observer registration.
        let bucket = NotificationBucket()
        let token = NotificationCenter.default.addObserver(
            forName: .weatherWarningsActivePlantingsChanged,
            object: nil,
            queue: nil
        ) { _ in
            bucket.markFired()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let input = CreatePlantingEventInput(
            kind: .sowing,
            planned_for: "2026-07-01"
        )
        _ = try engine.enqueueCreatePlantingEvent(input, householdID: Self.householdID)

        #expect(bucket.fired)
    }

    @Test("enqueueUpdatePlantingEvent posts .weatherWarningsActivePlantingsChanged")
    func updatePlantingEventPostsNotification() async throws {
        let container = Self.makeContainer()
        let engine = SyncEngine(container: container)

        // Pre-seed an active planting we can update.
        let input = CreatePlantingEventInput(
            kind: .sowing,
            planned_for: "2026-07-01"
        )
        let created = try engine.enqueueCreatePlantingEvent(input, householdID: Self.householdID)

        let bucket = NotificationBucket()
        let token = NotificationCenter.default.addObserver(
            forName: .weatherWarningsActivePlantingsChanged,
            object: nil,
            queue: nil
        ) { _ in
            bucket.markFired()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let patch = UpdatePlantingEventInput(notes: "new note")
        try engine.enqueueUpdatePlantingEvent(id: created.id, patch)

        #expect(bucket.fired)
    }

    @Test("enqueueDeletePlantingEvent posts .weatherWarningsActivePlantingsChanged")
    func deletePlantingEventPostsNotification() async throws {
        let container = Self.makeContainer()
        let engine = SyncEngine(container: container)

        let input = CreatePlantingEventInput(
            kind: .sowing,
            planned_for: "2026-07-01"
        )
        let created = try engine.enqueueCreatePlantingEvent(input, householdID: Self.householdID)

        let bucket = NotificationBucket()
        let token = NotificationCenter.default.addObserver(
            forName: .weatherWarningsActivePlantingsChanged,
            object: nil,
            queue: nil
        ) { _ in
            bucket.markFired()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try engine.enqueueDeletePlantingEvent(id: created.id)

        #expect(bucket.fired)
    }
}

// MARK: - Synchronous notification bucket

/// `NotificationCenter.addObserver(forName:object:queue:using:)` with
/// `queue: nil` runs the callback synchronously on the posting thread.
/// The bucket is lock-guarded so the closure (which the compiler treats
/// as nonisolated) can call into it without a `@MainActor` hop.
final class NotificationBucket: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<Bool>
    init() {
        self.state = OSAllocatedUnfairLock(initialState: false)
    }
    var fired: Bool { state.withLock { $0 } }
    func markFired() { state.withLock { $0 = true } }
}
