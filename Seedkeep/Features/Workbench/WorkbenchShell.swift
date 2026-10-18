import SwiftUI
import SwiftData

/// Pure policy used by the signed-in root and its size-class tests.
enum WorkbenchDeviceIdiom: Equatable {
    case phone, tablet, other
}

enum WorkbenchShellPolicy {
    static func shouldShowWorkbench(
        isSignedIn: Bool,
        isMac: Bool,
        idiom: WorkbenchDeviceIdiom,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        isSignedIn && shouldShowWorkbench(isMac: isMac, idiom: idiom, horizontalSizeClass: horizontalSizeClass)
    }

    static func shouldShowWorkbench(
        isMac: Bool,
        idiom: WorkbenchDeviceIdiom,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        isMac || (idiom == .tablet && horizontalSizeClass == .regular)
    }
}

struct WorkbenchShell: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.undoManager) private var environmentUndoManager: UndoManager?
    @Bindable var model: WorkbenchModel
    @State private var fallbackUndoManager = UndoManager()
    @State private var undoAvailability = WorkbenchUndoAvailability()
    @State private var dismissTask: Task<Void, Never>?

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var queriedSeeds: [LocalSeed]
    @Query private var queriedTags: [LocalTag]
    @Query private var queriedLocations: [LocalLocation]
    @Query private var recommendations: [LocalRecommendation]

    var body: some View {
        let householdID = appEnv.activeGardenHouseholdID
        let seeds = queriedSeeds.filter { $0.householdID == householdID }
        let tags = queriedTags.filter { $0.householdID == householdID && $0.deletedAt == nil }
        let locations = queriedLocations.filter { $0.householdID == householdID && $0.deletedAt == nil }
        let recommendationsByCatalogID = Dictionary(
            recommendations.map { ($0.catalogSeedID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = SeedTableRow.rows(
            seeds: seeds, locations: locations, tags: tags, recommendations: recommendationsByCatalogID
        )
        let seedsByID = Dictionary(seeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationSplitView {
            WorkbenchSidebar(model: model, seedCount: rows.count)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            routeContent(rows: rows, seedsByID: seedsByID)
        }
        .tint(WBColor.accent)
        .background(WBColor.bg)
        // The window's undo manager (SwiftUI's, or this shell-owned fallback when SwiftUI has
        // none) is published as `model.activeUndoManager` in `updateUndoManager()`. The Seeds
        // screen registers with that, so menus, toolbar and screen share one history. The
        // environment value itself is read-only and can't be replaced here.
        .focusedSceneValue(\.workbenchUndoAvailability, undoAvailability)
        .sheet(isPresented: $model.isPaletteOpen) {
            CommandPaletteView(model: model, rows: rows)
                .frame(minWidth: 420, minHeight: 360)
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .platformTrailing) {
                Button { model.isPaletteOpen = true } label: { Image(systemName: "command") }
                    .accessibilityLabel("Open command palette")
                    .frame(minWidth: WBMetrics.touchTarget, minHeight: WBMetrics.touchTarget)
            }
            #endif
        }
        .overlay(alignment: .top) { bannerOverlay }
        .onChange(of: appEnv.bannerError) { _, newValue in
            if newValue != nil {
                scheduleBannerDismissal()
            } else {
                dismissTask?.cancel()
                dismissTask = nil
            }
        }
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
            undoAvailability.stopObserving()
        }
        .onAppear {
            updateUndoManager()
            if appEnv.bannerError != nil { scheduleBannerDismissal() }
        }
        .onChange(of: environmentUndoManager.map { ObjectIdentifier($0) }) { _, _ in
            updateUndoManager()
        }
        .onChange(of: appEnv.activeGardenHouseholdID) { _, _ in
            Task { @MainActor in
                await Task.yield()
                undoAvailability.refresh()
            }
        }
        .onChange(of: queriedSeeds.map(\.id)) { _, ids in
            let scopedIDs = Set(queriedSeeds.filter { $0.householdID == appEnv.activeGardenHouseholdID }.map(\.id))
            model.selectedSeedIDs.formIntersection(scopedIDs)
        }
    }

    private var undoManager: UndoManager {
        environmentUndoManager ?? fallbackUndoManager
    }

    private func updateUndoManager() {
        model.activeUndoManager = undoManager
        undoAvailability.observe(undoManager)
    }

    @ViewBuilder
    private var bannerOverlay: some View {
        if let message = appEnv.bannerError {
            HerbBanner(
                severity: .error,
                title: "Sync hiccup",
                message: message,
                action: ("dismiss", {
                    dismissTask?.cancel()
                    dismissTask = nil
                    appEnv.dismissBannerError()
                })
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: appEnv.bannerError)
        }
    }

    private func scheduleBannerDismissal() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { appEnv.dismissBannerError() }
        }
    }

    @ViewBuilder private func routeContent(rows: [SeedTableRow], seedsByID: [String: LocalSeed]) -> some View {
        switch model.route {
        case .seeds:
            SeedsTableView(model: model, rows: rows, seedsByID: seedsByID)
        case .today: TodayView()
        case .garden: GardenView()
        case .journal: JournalView()
        // YouView, not SettingsView: it links to Settings and holds Sign out and Delete account.
        case .settings: YouView()
        }
    }
}
