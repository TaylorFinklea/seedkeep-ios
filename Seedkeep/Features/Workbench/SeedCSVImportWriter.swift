// CSV import writes (R4, slice C). Sequential, on the main actor, through the existing `SyncEngine`
// enqueue methods and `setLocalCustomType`, in time slices that yield between them.
//
// Revalidation keeps the main actor free:
// - Before the first write, the plan is rebuilt off the main actor from a fresh snapshot and must
//   equal the preview's. A cheap `Fingerprint` taken on the main actor before and after that rebuild
//   proves nothing changed in between; the writes start right after the second one.
// - Before each update, its target seed is fetched by id and must be live, in the garden, and at the
//   `updatedAt` the plan saw.
// - New locations and tags, and the seed writes, run in the same time slices (about 40 ms each).
// - After every yield, the household and the fingerprint (an aggregate over every seed, tombstones
//   included, and the locations and tags) are checked against the one taken at the end of the last
//   slice, so this run's own writes are allowed for. If it differs, the rest of the plan is rebuilt
//   off the main actor and the remaining rows must plan the same.
// Anything else stops the run and asks for a fresh preview. Every save is tracked as it happens
// (`Ledger`), so a retry targets the seeds already saved and never creates a second one.
import Foundation
import SwiftData
import SeedkeepKit

/// The mutation boundary the import writes through. `SyncEngine` is the real one; tests wrap it.
@MainActor
protocol SeedCSVImportStore: AnyObject {
    func enqueueCreateLocation(name: String, sortOrder: Int, householdID: String) throws -> LocalLocation
    func enqueueCreateTag(name: String, color: String?, householdID: String) throws -> LocalTag
    func enqueueCreateSeed(_ input: CreateSeedInput, householdID: String) throws -> LocalSeed
    func enqueueUpdateSeed(id: String, _ patch: UpdateSeedInput) throws
    func setLocalCustomType(seedID: String, type: String?) throws
}

extension SyncEngine: SeedCSVImportStore {}

@MainActor
final class SeedCSVImportWriter {
    /// What this import has saved so far, across attempts. Kept by the import session.
    struct Ledger: Equatable, Sendable {
        /// Row line → the seed saved (created or updated) from it.
        var seedIDsByLine: [Int: String] = [:]
        /// Normalized name → id, for locations and tags this import created. An entry whose record is
        /// gone or renamed is dropped before planning, so the import creates it again.
        var createdLocations: [String: String] = [:]
        var createdTags: [String: String] = [:]
    }

    /// What one run saved. Counts are separate, as the result reports them.
    struct Report: Equatable, Sendable {
        var locationsCreated = 0
        var tagsCreated = 0
        var seedsCreated = 0
        var seedsUpdated = 0
        /// Seeds that saved but whose type didn't (row line and name).
        var typeNotApplied: [Failure] = []
        /// Lines whose type was applied in this run, which clears an earlier attempt's warning.
        var typeAppliedLines: Set<Int> = []

        var savedAnything: Bool {
            locationsCreated + tagsCreated + seedsCreated + seedsUpdated > 0 || !typeAppliedLines.isEmpty
        }

        /// Totals across attempts. A type applied later drops its earlier warning.
        static func + (lhs: Report, rhs: Report) -> Report {
            let kept = lhs.typeNotApplied.filter { failure in
                guard let line = failure.line else { return true }
                return !rhs.typeAppliedLines.contains(line)
            }
            return Report(
                locationsCreated: lhs.locationsCreated + rhs.locationsCreated,
                tagsCreated: lhs.tagsCreated + rhs.tagsCreated,
                seedsCreated: lhs.seedsCreated + rhs.seedsCreated,
                seedsUpdated: lhs.seedsUpdated + rhs.seedsUpdated,
                typeNotApplied: kept + rhs.typeNotApplied,
                typeAppliedLines: lhs.typeAppliedLines.union(rhs.typeAppliedLines)
            )
        }
    }

    struct Failure: Equatable, Sendable {
        /// The row's line, or nil for a location or tag.
        let line: Int?
        let name: String
        let message: String
        /// True when the seed saved and only its type didn't.
        var typeOnly = false
    }

    enum Ending: Equatable, Sendable {
        case completed
        /// A write failed. The run stopped there.
        case failed(Failure)
        /// The garden changed. Nothing more is written.
        case householdChanged
        /// Something the import depends on changed. This is the fresh plan to preview.
        case changed(SeedCSVImport.Plan)
        /// The store couldn't be read to check the plan.
        case unreadable(String)
    }

    struct Result: Equatable, Sendable {
        var ending: Ending
        var report: Report
    }

    /// The cheap state check: the garden, and an order-independent aggregate over every one of its
    /// seeds, tombstones included (id, `updatedAt`, deleted, and the identity fields), plus its
    /// locations and tags by id, folded name and deleted state. Unlike a count and newest timestamp,
    /// it sees a sync apply that stamps an older peer clock, and a delete plus a create that keep the
    /// count and newest change.
    struct Fingerprint: Equatable, Sendable {
        let householdID: String?
        let seedCount: Int
        let seedHash: Int
        let locations: [String: String]
        let tags: [String: String]
    }

    static let householdChangedMessage = "Your garden changed, so the import stopped."
    /// How many times in a row the store may change during a check before the run asks again.
    static let maxCheckAttempts = 3

    let store: SeedCSVImportStore
    let container: ModelContainer
    /// The garden the import was opened in.
    let householdID: String
    let currentHouseholdID: @MainActor () -> String?
    /// The most rows in one slice (tests use 1). The time budget usually ends a slice first.
    let batchSize: Int
    /// Main-actor work per slice before it yields.
    let sliceBudget: Duration
    /// Called between slices. The default lets the screen draw the progress.
    let pause: @MainActor () async -> Void
    /// Called once at the end when anything was saved, even after a partial run.
    let nudgeSync: @MainActor () -> Void

    private(set) var ledger: Ledger

    init(
        store: SeedCSVImportStore,
        container: ModelContainer,
        householdID: String,
        currentHouseholdID: @escaping @MainActor () -> String?,
        ledger: Ledger = Ledger(),
        batchSize: Int = .max,
        sliceBudget: Duration = .milliseconds(40),
        pause: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(5)) },
        nudgeSync: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.container = container
        self.householdID = householdID
        self.currentHouseholdID = currentHouseholdID
        self.ledger = ledger
        self.batchSize = max(1, batchSize)
        self.sliceBudget = sliceBudget
        self.pause = pause
        self.nudgeSync = nudgeSync
    }

    // MARK: - Checks

    /// The fingerprint now. Reads only the fields it hashes. Hash values are stable within the process,
    /// which is all a comparison during one import needs.
    func fingerprint() throws -> Fingerprint {
        let household = householdID
        let context = ModelContext(container)
        var seedQuery = FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.householdID == household })
        seedQuery.propertiesToFetch = [
            \.id, \.updatedAt, \.deletedAt, \.customName, \.customVariety, \.customCompany, \.yearPacked,
        ]
        let seeds = try context.fetch(seedQuery)
        var seedHash = 0
        for seed in seeds {
            var hasher = Hasher()
            hasher.combine(seed.id)
            hasher.combine(seed.updatedAt)
            hasher.combine(seed.deletedAt != nil)
            hasher.combine(seed.customName)
            hasher.combine(seed.customVariety)
            hasher.combine(seed.customCompany)
            hasher.combine(seed.yearPacked)
            seedHash &+= hasher.finalize()
        }
        var locationQuery = FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.householdID == household })
        locationQuery.propertiesToFetch = [\.id, \.name, \.deletedAt]
        var tagQuery = FetchDescriptor<LocalTag>(predicate: #Predicate { $0.householdID == household })
        tagQuery.propertiesToFetch = [\.id, \.name, \.deletedAt]
        func state(_ name: String, _ deletedAt: Int64?) -> String {
            (deletedAt == nil ? "live:" : "deleted:") + SeedCSVImport.normalized(name)
        }
        return Fingerprint(
            householdID: currentHouseholdID(),
            seedCount: seeds.count,
            seedHash: seedHash,
            locations: Dictionary(try context.fetch(locationQuery).map { ($0.id, state($0.name, $0.deletedAt)) },
                                  uniquingKeysWith: { a, _ in a }),
            tags: Dictionary(try context.fetch(tagQuery).map { ($0.id, state($0.name, $0.deletedAt)) },
                             uniquingKeysWith: { a, _ in a })
        )
    }

    /// Drops created locations and tags that are no longer live under the name they were created
    /// with, so a retry creates them again instead of using a stale id.
    func pruneLedger(against snapshot: SeedCSVImport.Snapshot) {
        let locations = Dictionary(snapshot.locations.map { ($0.id, SeedCSVImport.normalized($0.name)) }, uniquingKeysWith: { a, _ in a })
        let tags = Dictionary(snapshot.tags.map { ($0.id, SeedCSVImport.normalized($0.name)) }, uniquingKeysWith: { a, _ in a })
        ledger.createdLocations = ledger.createdLocations.filter { key, id in locations[id] == key }
        ledger.createdTags = ledger.createdTags.filter { key, id in tags[id] == key }
    }

    /// The plan rebuilt from the store now, off the main actor, with this import's saved rows.
    func freshPlan(for file: SeedCSVImport.ParsedFile) async throws -> SeedCSVImport.Plan {
        let result = try await SeedCSVImport.detachedPlan(
            file, householdID: householdID, container: container, savedSeedIDs: ledger.seedIDsByLine
        )
        pruneLedger(against: result.snapshot)
        return result.plan
    }

    /// A fresh plan that nothing changed under: the fingerprint is the same before and after the
    /// off-main rebuild. Returns that fingerprint, which holds until the caller next suspends.
    private func stablePlan(for file: SeedCSVImport.ParsedFile) async throws -> (SeedCSVImport.Plan, Fingerprint?) {
        var plan: SeedCSVImport.Plan?
        for _ in 0..<Self.maxCheckAttempts {
            let before = try fingerprint()
            let fresh = try await freshPlan(for: file)
            plan = fresh
            let after = try fingerprint()
            if before == after { return (fresh, after) }
        }
        // The store kept changing: hand back the latest plan without a fingerprint.
        guard let plan else { throw CancellationError() }
        return (plan, nil)
    }

    /// The target seed is still live, in the garden, and unchanged since the plan.
    private func targetIsCurrent(_ seedID: String, updatedAt: Int64) -> Bool {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == seedID })
        descriptor.fetchLimit = 1
        guard let seed = try? context.fetch(descriptor).first else { return false }
        return seed.deletedAt == nil && seed.householdID == householdID && seed.updatedAt == updatedAt
    }

    // MARK: - Run

    /// One unit of work in a slice: a new location, a new tag, or a seed row (an index into the plan).
    private enum Step {
        case location(SeedCSVImport.NewDependency, sortOrder: Int)
        case tag(SeedCSVImport.NewDependency)
        case row(Int)
    }

    /// Writes `plan`, which the user saw in the preview. `progress` gets (done, total) steps (new
    /// locations, new tags and seed writes) at each yield.
    func run(
        plan: SeedCSVImport.Plan,
        file: SeedCSVImport.ParsedFile,
        progress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> Result {
        var report = Report()
        func finish(_ ending: Ending) -> Result {
            if report.savedAnything { nudgeSync() }
            return Result(ending: ending, report: report)
        }
        func changed() async -> Result {
            guard currentHouseholdID() == householdID else { return finish(.householdChanged) }
            do {
                return finish(.changed(try await freshPlan(for: file)))
            } catch {
                return finish(.unreadable(error.localizedDescription))
            }
        }

        // Revalidate off the main actor: the plan rebuilt now must be the one previewed.
        guard currentHouseholdID() == householdID, plan.householdID == householdID else {
            return finish(.householdChanged)
        }
        let checked: (SeedCSVImport.Plan, Fingerprint?)
        do {
            checked = try await stablePlan(for: file)
        } catch {
            return finish(.unreadable(error.localizedDescription))
        }
        guard currentHouseholdID() == householdID else { return finish(.householdChanged) }
        guard checked.0 == plan, var baseline = checked.1, baseline.householdID == householdID else {
            return finish(.changed(checked.0))
        }

        // The steps: locations and tags first (new locations go after the household's live ones, as
        // Settings adds them), then the seeds. All of them run in the same time slices.
        let liveLocationCount = baseline.locations.values.count(where: { $0.hasPrefix("live:") })
        var steps: [Step] = []
        for (offset, dependency) in plan.newLocations.enumerated() where ledger.createdLocations[dependency.key] == nil {
            steps.append(.location(dependency, sortOrder: liveLocationCount + offset))
        }
        for dependency in plan.newTags where ledger.createdTags[dependency.key] == nil {
            steps.append(.tag(dependency))
        }
        let work = plan.rows.indices.filter { plan.rows[$0].action.writes }
        steps += work.map(Step.row)
        let total = steps.count
        var done = 0
        var processedLocations: Set<String> = []
        var processedTags: Set<String> = []
        /// The first seed row not yet written, as a position in `plan.rows`.
        func remainingPosition() -> Int {
            for index in done..<total { if case .row(let position) = steps[index] { return position } }
            return plan.rows.count
        }

        let clock = ContinuousClock()
        var firstSlice = true
        while done < total {
            if !firstSlice {
                progress(done, total)
                await pause()

                // Re-check after every yield.
                guard currentHouseholdID() == householdID else { return finish(.householdChanged) }
                do {
                    var attempts = 0
                    while try fingerprint() != baseline {
                        // Something outside this run changed: the rows still to come must plan the same.
                        attempts += 1
                        let (fresh, settled) = try await stablePlan(for: file)
                        guard currentHouseholdID() == householdID else { return finish(.householdChanged) }
                        guard remainingRowsMatch(
                            original: plan, fresh: fresh, from: remainingPosition(),
                            processedLocations: processedLocations, processedTags: processedTags
                        ) else {
                            return finish(.changed(fresh))
                        }
                        if let settled {
                            baseline = settled
                        } else if attempts >= Self.maxCheckAttempts {
                            return finish(.changed(fresh))
                        }
                    }
                } catch {
                    return finish(.unreadable(error.localizedDescription))
                }
            }
            firstSlice = false

            let sliceStart = clock.now
            var inSlice = 0
            repeat {
                switch steps[done] {
                case .location(let dependency, let sortOrder):
                    processedLocations.insert(dependency.key)
                    do {
                        let location = try store.enqueueCreateLocation(
                            name: dependency.name, sortOrder: sortOrder, householdID: householdID
                        )
                        ledger.createdLocations[dependency.key] = location.id
                        report.locationsCreated += 1
                    } catch {
                        return finish(.failed(Failure(
                            line: nil, name: dependency.name,
                            message: "Couldn't create the location “\(dependency.name)”: \(error.localizedDescription)"
                        )))
                    }
                case .tag(let dependency):
                    processedTags.insert(dependency.key)
                    do {
                        let tag = try store.enqueueCreateTag(name: dependency.name, color: nil, householdID: householdID)
                        ledger.createdTags[dependency.key] = tag.id
                        report.tagsCreated += 1
                    } catch {
                        return finish(.failed(Failure(
                            line: nil, name: dependency.name,
                            message: "Couldn't create the tag “\(dependency.name)”: \(error.localizedDescription)"
                        )))
                    }
                case .row(let position):
                    let row = plan.rows[position]
                    if case .update(let seedID, let updatedAt, _) = row.action,
                       !targetIsCurrent(seedID, updatedAt: updatedAt) {
                        return await changed()
                    }
                    if let failure = write(row, report: &report) {
                        return finish(.failed(failure))
                    }
                }
                done += 1
                inSlice += 1
            } while done < total && inSlice < batchSize && clock.now - sliceStart < sliceBudget

            // This run's own writes are part of the next baseline.
            do {
                baseline = try fingerprint()
            } catch {
                return finish(.unreadable(error.localizedDescription))
            }
        }
        progress(done, total)
        return finish(.completed)
    }

    /// True when every row from `position` on plans the same as it did, with this run's created
    /// locations and tags standing in for the ones the preview showed as new. A row that still needs a
    /// location or tag this run already created, but which is gone or renamed since, doesn't match:
    /// the import asks for a new preview instead of failing on it.
    func remainingRowsMatch(
        original: SeedCSVImport.Plan,
        fresh: SeedCSVImport.Plan,
        from position: Int,
        processedLocations: Set<String> = [],
        processedTags: Set<String> = []
    ) -> Bool {
        guard original.rows.count == fresh.rows.count else { return false }
        for index in position..<original.rows.count {
            let expected = original.rows[index]
            let actual = fresh.rows[index]
            let resolved = resolvingCreated(expected.action)
            guard expected.line == actual.line, resolved == actual.action else { return false }
            let (locations, tags) = Self.newKeys(in: resolved)
            if !locations.isDisjoint(with: processedLocations) || !tags.isDisjoint(with: processedTags) {
                return false
            }
        }
        return true
    }

    /// The `.new` location and tag keys an action still refers to.
    private static func newKeys(in action: SeedCSVImport.Action) -> (Set<String>, Set<String>) {
        func key(_ ref: SeedCSVImport.Ref?) -> String? {
            if case .new(let key) = ref { return key }
            return nil
        }
        switch action {
        case .create(let seed):
            return (Set([key(seed.location)].compactMap { $0 }), Set(seed.tags.compactMap(key)))
        case .update(_, _, let changes):
            let location = changes.location.flatMap { $0 }
            return (Set([key(location)].compactMap { $0 }), Set((changes.tags ?? []).compactMap(key)))
        case .unchanged, .skipped:
            return ([], [])
        }
    }

    private func resolvingCreated(_ action: SeedCSVImport.Action) -> SeedCSVImport.Action {
        func location(_ ref: SeedCSVImport.Ref) -> SeedCSVImport.Ref {
            if case .new(let key) = ref, let id = ledger.createdLocations[key] { return .existing(id) }
            return ref
        }
        func tag(_ ref: SeedCSVImport.Ref) -> SeedCSVImport.Ref {
            if case .new(let key) = ref, let id = ledger.createdTags[key] { return .existing(id) }
            return ref
        }
        switch action {
        case .create(var seed):
            seed.location = seed.location.map(location)
            seed.tags = seed.tags.map(tag)
            return .create(seed)
        case .update(let seedID, let updatedAt, var changes):
            changes.location = changes.location.map { $0.map(location) }
            changes.tags = changes.tags?.map(tag)
            return .update(seedID: seedID, targetUpdatedAt: updatedAt, changes: changes)
        case .unchanged, .skipped:
            return action
        }
    }

    // MARK: - One row

    private enum Unresolved: Error {
        case dependency
    }

    private func locationID(_ ref: SeedCSVImport.Ref) throws -> String {
        switch ref {
        case .existing(let id): return id
        case .new(let key):
            guard let id = ledger.createdLocations[key] else { throw Unresolved.dependency }
            return id
        }
    }

    private func tagID(_ ref: SeedCSVImport.Ref) throws -> String {
        switch ref {
        case .existing(let id): return id
        case .new(let key):
            guard let id = ledger.createdTags[key] else { throw Unresolved.dependency }
            return id
        }
    }

    /// Writes one row. Returns the failure that stops the run, or nil.
    private func write(_ row: SeedCSVImport.PlannedRow, report: inout Report) -> Failure? {
        func failure(_ error: Error) -> Failure {
            let detail = (error as? Unresolved) != nil
                ? "a location or tag it needs wasn't created"
                : error.localizedDescription
            return Failure(line: row.line, name: row.name, message: "Couldn't save it: \(detail)")
        }
        func typeFailure(_ error: Error) -> Failure {
            Failure(
                line: row.line, name: row.name,
                message: "Saved, but its type wasn't applied: \(error.localizedDescription)",
                typeOnly: true
            )
        }

        switch row.action {
        case .create(let seed):
            let input: CreateSeedInput
            do {
                input = CreateSeedInput(
                    state: seed.state,
                    packet_count: seed.packets,
                    location_id: try seed.location.map(locationID),
                    year_packed: seed.year,
                    // Add Seed's default for a manual entry.
                    source: .store,
                    custom_name: seed.name,
                    custom_variety: seed.variety,
                    custom_company: seed.company,
                    notes: seed.notes,
                    tag_ids: try seed.tags.map(tagID)
                )
            } catch {
                return failure(error)
            }
            let created: LocalSeed
            do {
                created = try store.enqueueCreateSeed(input, householdID: householdID)
            } catch {
                return failure(error)
            }
            ledger.seedIDsByLine[row.line] = created.id
            report.seedsCreated += 1
            if let type = seed.type {
                do {
                    try store.setLocalCustomType(seedID: created.id, type: type)
                    report.typeAppliedLines.insert(row.line)
                } catch {
                    let failed = typeFailure(error)
                    report.typeNotApplied.append(failed)
                    return failed
                }
            }
            return nil

        case .update(let seedID, _, let changes):
            var saved = false
            if !changes.patchIsEmpty {
                let patch: UpdateSeedInput
                do {
                    patch = UpdateSeedInput(
                        state: changes.state,
                        packet_count: changes.packets,
                        location_id: try changes.location.map { try $0.map(locationID) },
                        notes: changes.notes,
                        tag_ids: try changes.tags?.map(tagID)
                    )
                    try store.enqueueUpdateSeed(id: seedID, patch)
                } catch {
                    return failure(error)
                }
                saved = true
                ledger.seedIDsByLine[row.line] = seedID
                report.seedsUpdated += 1
            }
            if let type = changes.type {
                do {
                    try store.setLocalCustomType(seedID: seedID, type: type)
                    report.typeAppliedLines.insert(row.line)
                } catch {
                    guard saved else { return failure(error) }
                    let failed = typeFailure(error)
                    report.typeNotApplied.append(failed)
                    return failed
                }
                if !saved {
                    ledger.seedIDsByLine[row.line] = seedID
                    report.seedsUpdated += 1
                }
            }
            return nil

        case .unchanged, .skipped:
            return nil
        }
    }
}
