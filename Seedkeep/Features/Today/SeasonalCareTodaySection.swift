import SwiftUI
import SwiftData

/// Date-aware seasonal-care queue for Today. Its rows are built from the same
/// evaluator and view helpers as Seed Detail, so completion changes converge in
/// both surfaces through SwiftData observation.
struct SeasonalCareTodaySection: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Query(filter: #Predicate<LocalSeasonalCareTask> { $0.deletedAt == nil })
    private var tasks: [LocalSeasonalCareTask]
    @Query(filter: #Predicate<LocalSeasonalCareCompletion> { $0.householdID != "" })
    private var completions: [LocalSeasonalCareCompletion]
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil })
    private var seeds: [LocalSeed]

    @State private var errorMessage: String?

    var body: some View {
        let rows = SeasonalCareViewHelpers.todayRows(viewStates)
        if !rows.isEmpty || errorMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                Rubric(text: "seasonal care")
                ForEach(rows) { row in
                    todayRow(row)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(HerbColor.rose)
                }
            }
        }
    }

    private var activeHouseholdID: String? { appEnv.activeGardenHouseholdID }

    private var viewStates: [SeasonalCareTaskViewState] {
        guard let householdID = activeHouseholdID else { return [] }
        let activeSeeds = seeds.filter { $0.householdID == householdID && $0.deletedAt == nil }
        let seedsByID = Dictionary(uniqueKeysWithValues: activeSeeds.map { ($0.id, $0) })
        let activeTasks = tasks.filter {
            $0.householdID == householdID && $0.deletedAt == nil && seedsByID[$0.seedID] != nil
        }
        let calendar = Calendar.current
        let timeZone = calendar.timeZone
        let evaluationDate = appEnv.seasonalCareEvaluationDate
        return activeTasks.compactMap { task in
            guard let seed = seedsByID[task.seedID], let window = task.annualCareWindow else { return nil }
            let years = Set(completions.filter {
                $0.householdID == householdID && $0.taskID == task.id
            }.map(\.gardenYear))
            let createdDate = Date(timeIntervalSince1970: TimeInterval(task.createdAt) / 1_000)
            guard let evaluation = try? window.nextIncompleteEvaluation(
                on: evaluationDate,
                calendar: calendar,
                timeZone: timeZone,
                completedGardenYears: years,
                firstOccurrenceDate: createdDate
            ) else { return nil }
            return SeasonalCareTaskViewState(
                id: task.id,
                seedID: seed.id,
                seedName: seed.customName ?? "Untitled seed",
                title: task.title,
                instructions: task.instructions,
                evaluation: evaluation,
                notificationEnabled: task.notificationEnabled,
                authorityName: task.authorityName,
                sourceTitle: task.sourceTitle,
                sourceURL: task.sourceURL,
                applicabilityLabel: task.applicabilityLabel
            )
        }
    }

    @ViewBuilder
    private func todayRow(_ row: SeasonalCareTaskViewState) -> some View {
        HStack(spacing: 8) {
            NavigationLink {
                SeedDetailView(seedID: row.seedID)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(HerbFont.body(size: 15))
                        .foregroundStyle(HerbColor.ink)
                    Text(row.seedName)
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkSoft)
                    Text(row.stateLabel)
                        .font(HerbFont.smallCaps(size: 9))
                        .tracking(1.2)
                        .foregroundStyle(row.state == .overdue ? HerbColor.rose : HerbColor.sepia)
                        .textCase(.uppercase)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                complete(row)
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!isReadyToComplete(row.state))
            .accessibilityLabel("Complete \(row.title) for \(row.seedName)")
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HerbColor.inkFaint)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func complete(_ row: SeasonalCareTaskViewState) {
        let calendar = Calendar.current
        do {
            try appEnv.seasonalCare.complete(
                taskID: row.id,
                on: Date(),
                calendar: calendar,
                timeZone: calendar.timeZone)
            Task { @MainActor in
                _ = await appEnv.reconcileSeasonalCareReminders()
            }
        } catch {
            errorMessage = "This task can be completed when its window begins."
        }
    }

    private func isReadyToComplete(_ state: AnnualCareState) -> Bool {
        switch state {
        case .due, .overdue: return true
        case .upcoming, .completed: return false
        }
    }
}
