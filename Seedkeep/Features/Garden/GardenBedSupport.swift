import SwiftUI
import SeedkeepKit

// What the iPhone bed screen and the iPad and Mac Garden screen share: the brush seeds and their plan
// date, the actions for a bed, running the grid's rules, and the brush list, legend, add-a-bed prompt
// and gridless notice views.

@MainActor
enum GardenBedSupport {
    /// The active seeds of the garden as brushes, ordered by verdict, then name, then id.
    static func brushSeeds(
        seeds: [LocalSeed],
        householdID: String?,
        recommendation: (LocalSeed) -> PlantingRecommendation?
    ) -> [BrushSeed] {
        let active = seeds.filter { $0.householdID == householdID && $0.deletedAt == nil && $0.state == .active }
        return GardenGrid.brushOrder(active.map { BrushSeed($0, verdict: recommendation($0)?.verdict) })
    }

    /// The date a painted event gets for the brush seed (today without one).
    static func planDate(
        brushSeedID: String?,
        seeds: [LocalSeed],
        recommendation: (LocalSeed) -> PlantingRecommendation?,
        today: CalendarDay = .today()
    ) -> CalendarDay {
        guard let brushSeedID, let seed = seeds.first(where: { $0.id == brushSeedID }) else { return today }
        let rec = recommendation(seed)
        return GardenGrid.planDate(windowStart: rec?.rangeStart, verdict: rec?.verdict, today: today)
    }

    static func actions(appEnv: AppEnvironment, householdID: String, bedID: String) -> GardenActions {
        GardenActions(
            sync: appEnv.sync,
            container: appEnv.container,
            scope: .init(householdID: householdID, bedID: bedID),
            currentHouseholdID: { [appEnv] in appEnv.activeGardenHouseholdID },
            didWrite: { [appEnv] in Task { await appEnv.syncIfPossible() } }
        )
    }

    /// What running one input left for the screen to show.
    struct Outcome: Equatable {
        /// A refusal, shown and announced.
        var message: String?
        /// The square to move focus to: the target of an accessibility Move.
        var focus: GridSquare?
    }

    /// Runs one grid input through `GardenInteraction`, adopts the new state and performs its effects
    /// through `GardenActions`. A refusal is announced to VoiceOver and returned to show.
    static func handle(
        _ input: GardenInteraction.Input,
        session: GardenSession,
        data: GardenBedData,
        planDate: CalendarDay,
        actions: GardenActions,
        onError: (Error) -> Void
    ) -> Outcome {
        guard let size = data.size else { return Outcome() }
        let context = GardenInteraction.Context(size: size, events: data.events, bedID: data.bedID, planDate: planDate)
        let effects = session.handle(input, context: context)
        var outcome = Outcome()
        for effect in effects {
            do {
                let result = try actions.perform(effect, size: size)
                switch result {
                case .refused(let message):
                    outcome.message = message
                    GardenAnnouncer.announce(message)
                case .written:
                    if case .moveSelected = input, case .move(_, _, _, let square) = effect {
                        outcome.focus = square
                    }
                case .unchanged:
                    break
                }
            } catch {
                onError(error)
            }
        }
        return outcome
    }

    /// The square holding an event, when it is on the grid.
    static func square(of eventID: String?, in data: GardenBedData) -> GridSquare? {
        guard let event = data.event(eventID), case .square(let square) = GardenGrid.placement(of: event, in: data.size) else {
            return nil
        }
        return square
    }

    /// The subject of the moving event, for the move banner and hints.
    static func movingName(session: GardenSession, data: GardenBedData) -> String? {
        data.event(session.movingEventID).map { GardenText.subject(seedName: data.seedName($0), kind: $0.kind) }
    }
}

// MARK: - Brush list

/// "Paint with a seed": the active seeds with their verdict dots and labels. Vertical beside the grid
/// on iPad and Mac; a horizontal strip on iPhone, with Stop unless the mode bar's Stop is showing.
/// Choosing the current brush again stops it.
struct GardenBrushList: View {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    let seeds: [BrushSeed]
    let brushSeedID: String?
    let isPainting: Bool
    /// The horizontal strip's Stop while painting; off while the mode bar shows its own.
    var showsStop: Bool = true
    let onSelect: (String) -> Void
    let onStop: () -> Void

    var body: some View {
        switch axis {
        case .vertical: vertical
        case .horizontal: horizontal
        }
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBSectionHeader("Paint with a seed")
                .padding(.horizontal, WBMetrics.gapLarge)
                .padding(.vertical, WBMetrics.gap)
            if seeds.isEmpty {
                emptyText.padding(.horizontal, WBMetrics.gapLarge)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(seeds) { seed in
                        item(seed).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, WBMetrics.gap)
                .padding(.bottom, WBMetrics.gap)
            }
        }
        .background(WBColor.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garden.brushes")
    }

    private var horizontal: some View {
        VStack(alignment: .leading, spacing: 4) {
            WBSectionHeader("Paint with a seed")
            ScrollView(.horizontal) {
                HStack(spacing: WBMetrics.gap) {
                    if isPainting, showsStop {
                        Button(action: onStop) {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.wbCallout.weight(.semibold))
                                .foregroundStyle(WBColor.accentInk)
                                .padding(.horizontal, 10)
                                .frame(minHeight: WBMetrics.minTouchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WBColor.accent)
                        .accessibilityIdentifier("garden.brushes.stop")
                    }
                    if seeds.isEmpty { emptyText }
                    ForEach(seeds) { seed in
                        item(seed)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garden.brushes")
    }

    private var emptyText: some View {
        Text("Move a seed to Active to paint with it.")
            .font(.wbFootnote)
            .foregroundStyle(WBColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func item(_ seed: BrushSeed) -> some View {
        let selected = isPainting && seed.id == brushSeedID
        let label = SeedTableRow.verdictLabel(for: seed.verdict ?? "unknown")
        return Button {
            if selected { onStop() } else { onSelect(seed.id) }
        } label: {
            HStack(spacing: WBMetrics.gap) {
                Circle()
                    .fill(WBColor.verdict(seed.verdict ?? "unknown"))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(seed.name)
                        .font(.wbCallout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(WBColor.ink)
                    Text(label)
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                }
                .lineLimit(axis == .horizontal ? 1 : 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: WBMetrics.touchTarget)
            .background(
                selected ? WBColor.selection : (axis == .horizontal ? WBColor.panel : Color.clear),
                in: RoundedRectangle(cornerRadius: WBMetrics.radiusControl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WBMetrics.radiusControl)
                    .strokeBorder(selected ? WBColor.accent : (axis == .horizontal ? WBColor.line : Color.clear),
                                  lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(seed.name), \(label)")
        .accessibilityHint(selected ? "Stops painting" : "Paints \(seed.name) on the grid")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("garden.brush.\(seed.id)")
    }
}

// MARK: - Legend

/// Sow, Transplant, Harvest, Done, the frost glyph as "Frost risk (estimate)", and the scale.
struct GardenLegendView: View {
    @ScaledMetric(relativeTo: .body) private var swatch: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var glyphSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: WBMetrics.gap) {
            WBSectionHeader("Legend")
            ForEach(GardenLegend.items) { item in
                HStack(spacing: WBMetrics.gap) {
                    mark(item.mark)
                        .frame(width: swatch, height: swatch)
                        .accessibilityHidden(true)
                    Text(item.title)
                        .font(.wbCallout)
                        .foregroundStyle(WBColor.ink)
                }
                .accessibilityElement(children: .combine)
            }
            Text(GardenLegend.scale)
                .font(.wbFootnote)
                .foregroundStyle(WBColor.muted)
        }
        .padding(WBMetrics.gapLarge)
        .frame(minWidth: 220, alignment: .leading)
        .background(WBColor.bg)
        .accessibilityIdentifier("garden.legend.content")
    }

    @ViewBuilder
    private func mark(_ mark: GardenLegend.Mark) -> some View {
        switch mark {
        case .swatch(let kind):
            RoundedRectangle(cornerRadius: WBMetrics.radiusSmall)
                .fill(BedGridCell.kindColour(kind))
                .overlay(RoundedRectangle(cornerRadius: WBMetrics.radiusSmall).strokeBorder(WBColor.line, lineWidth: 1))
        case .frost:
            Image(systemName: "snowflake")
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(WBColor.warnInk)
                .padding(4)
                .background(WBColor.warn, in: Circle())
        }
    }
}

// MARK: - Prompts

/// "Add a bed with a size to plan", with New bed and Stop: a brush is set but no bed has a grid.
struct GardenAddBedPrompt: View {
    let brushSeedName: String?
    let onNewBed: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WBMetrics.gap) {
            HStack(alignment: .top, spacing: WBMetrics.gap) {
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(WBColor.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(GardenBanner.promptTitle)
                        .font(.wbCallout.weight(.semibold))
                        .foregroundStyle(WBColor.ink)
                    Text(brushSeedName.map { "Planning \($0) needs a bed with a width and length." }
                         ?? "Planning needs a bed with a width and length.")
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: WBMetrics.gap) {
                Button(action: onNewBed) {
                    Text("New bed")
                        .foregroundStyle(WBColor.accentInk)
                        .frame(minHeight: WBMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(WBColor.accent)
                .accessibilityIdentifier("garden.addBedPrompt.newBed")
                Button(action: onStop) {
                    Text("Stop painting")
                        .frame(minHeight: WBMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("garden.addBedPrompt.stop")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WBColor.accentSoft, in: RoundedRectangle(cornerRadius: WBMetrics.radiusControl))
        .overlay(RoundedRectangle(cornerRadius: WBMetrics.radiusControl).strokeBorder(WBColor.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garden.addBedPrompt")
    }
}

/// A bed without a grid: its events stay listed and editable, with "Set a size to plan on a grid".
struct GardenGridlessNotice: View {
    let onEditBed: () -> Void

    static let title = "Set a size to plan on a grid"

    var body: some View {
        WBBanner(
            severity: .info,
            title: Self.title,
            message: "Give this bed a width and length from 1 to 50 feet.",
            action: ("Edit bed", onEditBed)
        )
        .accessibilityIdentifier("garden.gridless")
    }
}

/// A refusal or failure from the grid, shown until dismissed or replaced.
struct GardenMessageBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        WBBanner(severity: .warning, title: message, action: ("Dismiss", onDismiss))
            .accessibilityIdentifier("garden.message")
    }
}

// MARK: - Place in bed

/// Add Planting's "Place in bed": a compact grid of the bed. Each square is one button; the picked one
/// carries the accent ring and the selected trait. What each square already holds is shown and spoken.
struct BedSquarePicker: View {
    let size: GridSize
    let squares: [GridSquare: SquareContents]
    let seedName: (GridEvent) -> String?
    @Binding var selection: GridSquare?

    @ScaledMetric(relativeTo: .body) private var scaledCell: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var spacing: CGFloat = 3
    private static let maxHeight: CGFloat = 320

    private var cell: CGFloat { max(WBMetrics.touchTarget, scaledCell) }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: spacing) {
                ForEach(0..<size.rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<size.columns, id: \.self) { column in
                            square(GridSquare(column: column, rowFromTop: row))
                        }
                    }
                }
            }
            .padding(spacing)
        }
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .frame(height: min(CGFloat(size.rows) * (cell + spacing) + spacing * 2, Self.maxHeight))
        .accessibilityIdentifier("addPlanting.squarePicker")
    }

    private func square(_ square: GridSquare) -> some View {
        let contents = squares[square] ?? .empty
        let picked = selection == square
        return Button {
            selection = picked ? nil : square
        } label: {
            BedGridCell(
                contents: contents,
                seedName: seedName,
                isSelected: picked,
                showsDateLine: false,
                side: cell
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GardenText.cellLabel(square: square, contents: contents, seedName: seedName))
        .accessibilityHint(picked ? "Removes the placement" : "Places the planting here")
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("addPlanting.square.r\(square.rowFromTop + 1).s\(square.column + 1)")
    }
}
