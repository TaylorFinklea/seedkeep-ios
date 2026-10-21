import SwiftUI
import SwiftData
import SeedkeepKit
import PhotosUI
#if os(iOS)
import UIKit
#endif

/// The planting-windows screen (R3 G3). On the regular-width workbench it draws the season timeline; on compact
/// layouts, and on iPad at accessibility sizes, a grouped list with the same fields. Plan hands the seed to the
/// Garden screen through the window's `GardenSession`. Windows are computed on this device.
struct WindowsView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(GardenSession.self) private var garden
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var tierHeight: CGFloat = 16
    /// Horizontal spacing that keeps two marker labels on one tier apart; scales with the label text.
    @ScaledMetric(relativeTo: .caption) private var markerSpacing: Double = WindowsTimeline.markerLabelSpacing

    /// The shell that shows this screen. Plan routes from it.
    private let host: WindowsHost
    /// The workbench model when the regular-width shell hosts the screen. Nil in the compact tab shell, where Plan
    /// switches the tab instead.
    private let workbench: WorkbenchModel?

    // Single-key sorts, per the project's @Query convention. The household scope and grouping are in code.
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }, sort: \.customName, order: .forward)
    private var seeds: [LocalSeed]

    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil }, sort: \.sortOrder, order: .forward)
    private var beds: [LocalBed]

    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil && $0.completedAt == nil })
    private var events: [LocalPlantingEvent]

    /// Width of the view, measured for the timeline's chart.
    @State private var availableWidth: Double = 0
    /// Each marker label's measured width, by its index among the markers. The tiers are laid out from these.
    @State private var markerLabelWidths: [Int: Double] = [:]
    @State private var showNeedsBedPrompt = false
    @State private var showAddBed = false
    /// The seed whose Plan asked for a bed, and the bed New bed then created, so the Plan resumes when
    /// the sheet closes.
    @State private var planAwaitingBed: WindowsRow?
    @State private var createdBed: GardenSession.BedChoice?
    @State private var planMessage: String?

    @State private var cornerViewModel: CornerSuggestionsViewModel?
    @State private var showCornerSuggestions = false
    @State private var pickerItem: PhotosPickerItem?

    /// The seed column's width on the timeline, and the page gutter it sits in.
    private static let labelWidth = 240.0

    init(host: WindowsHost, workbench: WorkbenchModel?) {
        self.host = host
        self.workbench = workbench
    }

    /// What the timeline or the list draws: the groups in display order, and the timeline's dates and markers.
    private struct Content {
        struct Section: Identifiable {
            let group: PlantingWindowGroup
            let rows: [WindowsRow]
            var id: PlantingWindowGroup { group }
        }

        let sections: [Section]
        let domain: SeasonTimeline.Domain
        let markers: [SeasonTimeline.Marker]

        var rows: [WindowsRow] { sections.flatMap(\.rows) }
    }

    // MARK: - Body

    var body: some View {
        let content = makeContent()
        Group {
            switch layout {
            case .timeline: timeline(content)
            case .list: list(content)
            }
        }
        .accessibilityIdentifier("screen.windows")
        .navigationTitle("Windows")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: WindowsSeedDestination.self) { destination in
            SeedDetailView(seedID: destination.seedID)
        }
        .toolbar {
            ToolbarItem(placement: .platformTrailing) {
                PhotosPicker(
                    selection: $pickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 4) {
                        // Icon only at accessibility sizes, so the title keeps room; VoiceOver still says it.
                        if dynamicTypeSize.isAccessibilitySize {
                            Image(systemName: "camera.viewfinder")
                                .accessibilityLabel("Snap a corner")
                        } else {
                            Image(systemName: "camera.viewfinder")
                            Text("Snap a corner")
                                .font(.wbCallout.weight(.semibold))
                        }
                    }
                    .foregroundStyle(WBColor.accent)
                }
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = PlatformImageCoding.image(data: data) {
                    await launchCornerSuggestions(image: image)
                }
                pickerItem = nil
            }
        }
        .sheet(isPresented: $showCornerSuggestions) {
            if let vm = cornerViewModel {
                CornerSuggestionsView(viewModel: vm)
                    .environment(appEnv)
            }
        }
        .sheet(isPresented: $showAddBed, onDismiss: resumePlanAfterNewBed) {
            AddBedView(onCreated: { createdBed = $0 })
        }
        .alert("Add a bed with a size to plan", isPresented: $showNeedsBedPrompt) {
            Button("New bed") { showAddBed = true }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Plan", isPresented: planMessageIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(planMessage ?? "")
        }
    }

    private var planMessageIsPresented: Binding<Bool> {
        Binding(
            get: { planMessage != nil },
            set: { if !$0 { planMessage = nil } }
        )
    }

    // MARK: - Layout

    private var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// The same rule as the app root: macOS and iPad at regular width show the workbench.
    private var showsWorkbench: Bool {
        #if os(macOS)
        WorkbenchShellPolicy.shouldShowWorkbench(isMac: true, idiom: .other, horizontalSizeClass: horizontalSizeClass)
        #else
        WorkbenchShellPolicy.shouldShowWorkbench(
            isMac: false,
            idiom: isPad ? .tablet : .phone,
            horizontalSizeClass: horizontalSizeClass
        )
        #endif
    }

    private var layout: WindowsLayout {
        WindowsLayout.choose(
            workbenchShell: showsWorkbench,
            isPad: isPad,
            accessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    private func list(_ content: Content) -> some View {
        List {
            if content.rows.isEmpty {
                Section {
                    emptyStatus
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(content.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        WindowsSeedRow(row: row, showsDates: true, onPlan: { plan(row) })
                    }
                } header: {
                    WBSectionHeader(WindowsRowFormat.groupHeader(section.group, count: section.rows.count))
                }
            }
        }
        .wbForm()
    }

    private func timeline(_ content: Content) -> some View {
        let chart = CGFloat(WindowsTimeline.chartWidth(
            available: availableWidth - Self.labelWidth - 2 * Double(WBMetrics.screenGutter)
        ))
        return ZStack {
            WBScreenBackground()
            if content.rows.isEmpty {
                // Outside the two-axis scroll view, so the text wraps and centres.
                ScrollView {
                    emptyStatus
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, WBMetrics.screenGutter)
                        .padding(.vertical, WBMetrics.gap)
                }
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        timelineHeader(content, width: chart)
                        ForEach(content.sections) { section in
                            WBSectionHeader(WindowsRowFormat.groupHeader(section.group, count: section.rows.count))
                                .padding(.horizontal, WBMetrics.screenGutter)
                                .padding(.top, WBMetrics.gapLarge)
                                .padding(.bottom, 4)
                            ForEach(section.rows) { row in
                                timelineRow(row, content: content, width: chart)
                            }
                        }
                    }
                    .padding(.vertical, WBMetrics.gap)
                }
            }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { availableWidth = $0 }
    }

    /// Month names along the bottom, and the marker labels above them on up to two tiers.
    private func timelineHeader(_ content: Content, width: CGFloat) -> some View {
        let chart = Double(width)
        let markerXs = content.markers.map {
            SeasonTimeline.markerX($0.day, in: content.domain, totalWidth: chart)
        }
        // Each label's final leading x, and the span it takes, from its measured width. Until a label is
        // measured its width is zero, and the layout corrects itself on the next pass.
        let leadings = markerXs.indices.map { index in
            WindowsTimeline.markerLabelX(
                lineX: markerXs[index],
                labelWidth: markerLabelWidths[index] ?? 0,
                chartWidth: chart
            )
        }
        let spans = leadings.indices.map { index in
            WindowsTimeline.markerLabelSpan(
                leading: leadings[index],
                width: markerLabelWidths[index] ?? 0,
                spacing: markerSpacing
            )
        }
        let tiers = WindowsTimeline.labelTiers(spans)
        let months = SeasonTimeline.months(in: content.domain)
        return HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(Self.labelWidth))
            ZStack(alignment: .topLeading) {
                ForEach(content.markers.indices, id: \.self) { index in
                    Text(content.markers[index].kind.title)
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: {
                            markerLabelWidths[index] = $0
                        }
                        // The guide is the negated leading x, so the label's leading edge lands on that x. The clamp
                        // uses the label's live width, so it always matches what is drawn.
                        .alignmentGuide(.leading) { dimensions in
                            CGFloat(-WindowsTimeline.markerLabelX(
                                lineX: markerXs[index],
                                labelWidth: Double(dimensions.width),
                                chartWidth: chart
                            ))
                        }
                        .offset(y: CGFloat(tiers[index]) * tierHeight)
                }
                ForEach(months.indices, id: \.self) { index in
                    Text(months[index].label)
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                        .offset(x: CGFloat(months[index].offset) * width + 4, y: 2 * tierHeight)
                }
            }
            .frame(width: width, height: 3 * tierHeight, alignment: .topLeading)
        }
        .padding(.horizontal, WBMetrics.screenGutter)
        .accessibilityHidden(true)
    }

    /// One seed: its text on the left, its bars on the chart. The marker lines run behind the whole row.
    private func timelineRow(_ row: WindowsRow, content: Content, width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 0) {
            WindowsSeedRow(row: row, showsDates: false, onPlan: { plan(row) })
                .frame(width: CGFloat(Self.labelWidth), alignment: .leading)
            WindowsBarLanes(row: row, domain: content.domain, width: width)
        }
        .padding(.horizontal, WBMetrics.screenGutter)
        .padding(.vertical, WBMetrics.gap)
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(content.markers.indices, id: \.self) { index in
                    let marker = content.markers[index]
                    let x = WBMetrics.screenGutter + CGFloat(Self.labelWidth)
                        + CGFloat(SeasonTimeline.markerX(marker.day, in: content.domain, totalWidth: Double(width)))
                    VerticalLine(x: x)
                        .stroke(
                            marker.kind == .today ? WBColor.ink : WBColor.muted,
                            style: StrokeStyle(lineWidth: 1, dash: marker.kind == .today ? [] : [4, 3])
                        )
                }
            }
            .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WBColor.line)
                .frame(height: 1)
                .padding(.horizontal, WBMetrics.screenGutter)
        }
    }

    /// Shown in place of the rows: the home-location prompt, the loading state, or the empty state.
    @ViewBuilder
    private var emptyStatus: some View {
        if appEnv.recommendations.needsHomeLocation {
            RecommendationPanel.needsLocation
                .wbPanel()
        } else if appEnv.isSyncingForDisplay {
            VStack(spacing: 8) {
                ProgressView()
                    .tint(WBColor.accent)
                    .controlSize(.small)
                Text("Loading…")
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            WBEmptyState(
                title: "No recommendations yet",
                message: "Add growing info to a seed to see when to plant it.",
                systemImage: "leaf"
            )
        }
    }

    // MARK: - Data

    private var householdID: String? { appEnv.activeGardenHouseholdID }

    private var householdSeeds: [LocalSeed] {
        guard let householdID else { return [] }
        return seeds.filter { $0.householdID == householdID }
    }

    private var householdBeds: [LocalBed] {
        guard let householdID else { return [] }
        return beds.filter { $0.householdID == householdID }
    }

    /// The rows in display order, and the timeline's domain and markers. Windows are computed on this device.
    private func makeContent() -> Content {
        let climate = appEnv.preferences.homeClimate
        let stamp = appEnv.recommendations.today
        let today = CalendarDay.make(year: stamp.year, month: stamp.month, day: stamp.day) ?? CalendarDay.today()
        let bedNames = Dictionary(householdBeds.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        let recommended: [(seed: LocalSeed, recommendation: PlantingRecommendation)] = householdSeeds.compactMap { seed in
            appEnv.recommendations.recommendation(for: seed).map { (seed: seed, recommendation: $0) }
        }
        // Next planned: the household's first incomplete planting in a live bed, for each seed. The Windows
        // screen doesn't show frost, so the events carry no frost flag.
        let storedEvents = events.map { (householdID: $0.householdID, event: GridEvent($0, isFrostFlagged: false)) }
        let nextBySeed = WindowsGrouping.nextPlannedBySeed(
            storedEvents,
            householdID: householdID,
            liveBedIDs: Set(bedNames.keys)
        )

        var windowSeeds: [WindowSeed] = []
        var rowsByID: [String: WindowsRow] = [:]
        for item in recommended {
            let seed = WindowSeed(item.seed, recommendation: item.recommendation)
            windowSeeds.append(seed)
            let next = nextBySeed[seed.id].flatMap { event -> WindowsRow.NextPlanned? in
                guard let bedID = event.bedID,
                      let bedName = bedNames[bedID],
                      let day = CalendarDay.parse(event.plannedFor) else { return nil }
                return WindowsRow.NextPlanned(bedName: bedName, plannedFor: day)
            }
            rowsByID[seed.id] = WindowsRowFormat.row(
                seed: seed,
                reason: item.recommendation.reason,
                today: today,
                nextPlanned: next
            )
        }

        let sections = WindowsGrouping.sections(windowSeeds).map { section in
            Content.Section(group: section.group, rows: section.seeds.compactMap { rowsByID[$0.id] })
        }
        let markers = SeasonTimeline.markers(
            today: today,
            lastFrost: climate?.avgLastFrost,
            firstFrost: climate?.avgFirstFrost
        )
        let domain = WindowsTimeline.domain(
            year: today.year,
            rows: sections.flatMap(\.rows),
            markers: markers
        )
        return Content(sections: sections, domain: domain, markers: markers)
    }

    // MARK: - Plan

    /// Plans the row's seed in the window's Garden session, then routes from the host shell. Only a sheet is
    /// dismissed: the workbench's Windows route is the window's root, and closing it would close the window.
    private func plan(_ row: WindowsRow, newBed: GardenSession.BedChoice? = nil) {
        var beds = householdBeds.map { GardenSession.BedChoice($0) }
        // A bed just created may not be in the query yet.
        if let newBed, !beds.contains(where: { $0.id == newBed.id }) { beds.append(newBed) }
        let result = garden.plan(seedID: row.id, isActive: row.isActive, beds: beds)
        switch WindowsPlanRoute.route(for: result, seedName: row.name, host: host) {
        case .gardenTab:
            appEnv.requestedTab = .garden
            closeIfSheet()
        case .gardenRoute:
            workbench?.route = .garden
            closeIfSheet()
        case .addBed:
            planAwaitingBed = row
            showNeedsBedPrompt = true
        case .message(let text):
            planMessage = text
        }
    }

    /// After New bed from the add-a-bed prompt: plans the seed again when the brush is still set and
    /// the new bed has a grid, rather than making the user tap Plan again.
    private func resumePlanAfterNewBed() {
        defer {
            createdBed = nil
            planAwaitingBed = nil
        }
        guard let row = planAwaitingBed,
              GardenPlanHandoff.seedToResume(brushSeedID: garden.brushSeedID, created: createdBed) == row.id else { return }
        plan(row, newBed: createdBed)
    }

    private func closeIfSheet() {
        if host.isSheet { dismiss() }
    }

    // MARK: - Corner suggestions

    private func launchCornerSuggestions(image: PlatformImage) async {
        let recommendations = appEnv.recommendations
        // Only active (non-deleted, non-archived) seeds reach the ranker (AC #1).
        let localSeeds = householdSeeds.filter { $0.stateRaw == "active" }

        let vm = CornerSuggestionsViewModel(
            analyze: { img in
                await CornerVisionAnalyzer().analyze(image: img)
            },
            fetchSeeds: {
                localSeeds.map { seed in
                    PlantSuggestionRanker.SeedInput(
                        id: seed.id,
                        displayName: seed.displayName,
                        catalogID: seed.catalogID,
                        yearPacked: seed.yearPacked,
                        sunRequirement: seed.growingInfo?.sun_requirement,
                        plantSpacingInches: seed.growingInfo?.plant_spacing_inches
                    )
                }
            },
            fetchRecommendations: { seedIDs in
                // Each requested seed contributes its on-device window, whether or not it has a catalog link.
                let requested = Set(seedIDs)
                return localSeeds.compactMap { seed -> PlantSuggestionRanker.RecommendationInput? in
                    guard requested.contains(seed.id),
                          let rec = recommendations.recommendation(for: seed) else { return nil }
                    return PlantSuggestionRanker.RecommendationInput(
                        seedID: seed.id,
                        verdict: rec.verdict,
                        rangeStart: rec.rangeStart,
                        rangeEnd: rec.rangeEnd
                    )
                }
            },
            hasHomeLocation: { !recommendations.needsHomeLocation }
        )
        cornerViewModel = vm
        showCornerSuggestions = true
        await vm.capture(image: image)
    }
}

/// Pushed when a seed on the Windows screen is tapped: that seed's detail.
struct WindowsSeedDestination: Hashable {
    let seedID: String
}

// MARK: - Seed row

/// A seed's text and its Plan button. The text is one VoiceOver element, with Plan as a custom action too.
private struct WindowsSeedRow: View {
    let row: WindowsRow
    /// The list shows the window dates; the timeline shows them as bars instead.
    let showsDates: Bool
    let onPlan: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes Plan goes under the text, so the name and dates keep the full width.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: WBMetrics.gap) {
                    link
                    plan
                }
            } else {
                HStack(alignment: .center, spacing: WBMetrics.gapLarge) {
                    link
                    plan
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var link: some View {
        NavigationLink(value: WindowsSeedDestination(seedID: row.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.wbHeadline)
                    .foregroundStyle(WBColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if showsDates, let outdoor = row.outdoor {
                    Text("Outdoors \(WindowsRowFormat.windowText(outdoor))")
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                }
                if showsDates, let indoor = row.indoor {
                    Text("Indoors \(WindowsRowFormat.windowText(indoor))")
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                }
                if let timing = row.timing {
                    Text(timing)
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                }
                if let reason = row.noWindowReason {
                    Text(reason)
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let next = row.nextPlanned {
                    Text(WindowsRowFormat.nextPlannedText(next))
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the link itself, so the element VoiceOver focuses carries the label and the Plan action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WindowsRowFormat.accessibilityLabel(row))
        .accessibilityAction(named: "Plan") { onPlan() }
    }

    private var plan: some View {
        Button(action: onPlan) {
            Text("Plan")
                .font(.wbCallout.weight(.semibold))
                .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(WBColor.accent)
        .accessibilityLabel("Plan \(row.name)")
        .accessibilityIdentifier("windows.plan.\(row.id)")
    }
}

// MARK: - Timeline drawing

/// A seed's outdoor bar (filled, in its verdict colour) and indoor bar (outlined) on the chart. Hidden from
/// VoiceOver, which hears the dates in the seed's label.
private struct WindowsBarLanes: View {
    let row: WindowsRow
    let domain: SeasonTimeline.Domain
    let width: CGFloat

    private let barHeight: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            lane(row.outdoor, filled: true)
            lane(row.indoor, filled: false)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func lane(_ range: ClosedRange<CalendarDay>?, filled: Bool) -> some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(width: width, height: barHeight)
            if let range {
                let bar = SeasonTimeline.bar(for: range, in: domain, totalWidth: Double(width))
                Group {
                    if filled {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(WBColor.verdict(row.verdict))
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(WBColor.muted, lineWidth: 1.5)
                    }
                }
                .frame(width: CGFloat(bar.width), height: barHeight)
                .offset(x: CGFloat(bar.x))
            }
        }
    }
}

/// A vertical line across the full height it is given.
private struct VerticalLine: Shape {
    let x: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
    }
}
