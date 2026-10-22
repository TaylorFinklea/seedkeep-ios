// CSV import flow (R4, slice C): the file picker, the preview sheet, the write with progress, and the
// result. Used by the Seeds table (iPad and Mac) and the Library (iPhone) through `.seedCSVImport`.
//
// The import session belongs to `SeedCSVImportCenter`, one per app, not to a view: leaving Seeds (or
// closing its window) never orphans a running import, and showing Seeds again presents it again.
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import SeedkeepKit

/// One import, from the picked file to the result. Nothing is written before `startImport`.
@MainActor
@Observable
final class SeedCSVImportSession: Identifiable {
    enum Phase: Equatable {
        case loading
        case preview
        case importing(done: Int, total: Int)
        /// The import ended. `canReview` offers a fresh preview to finish the rest.
        case result(message: String, canReview: Bool)
        /// The file couldn't be imported at all.
        case refused(String)
    }

    let id = UUID()
    /// The garden the import was opened in.
    let householdID: String
    private(set) var phase: Phase = .loading
    private(set) var plan: SeedCSVImport.Plan?
    /// Shown above a preview that replaced the one the user saw.
    private(set) var notice: String?
    /// True from the Import tap until the run ends, so Import can't be pressed twice.
    private(set) var isWriting = false
    /// Everything saved by this import, across attempts.
    private(set) var totals = SeedCSVImportWriter.Report()

    private var file: SeedCSVImport.ParsedFile?
    let writer: SeedCSVImportWriter

    static let changedNotice = "Something changed since the preview. Check the new preview, then import again."

    init(
        householdID: String,
        store: SeedCSVImportStore,
        container: ModelContainer,
        currentHouseholdID: @escaping @MainActor () -> String?,
        nudgeSync: @escaping @MainActor () -> Void
    ) {
        self.householdID = householdID
        writer = SeedCSVImportWriter(
            store: store,
            container: container,
            householdID: householdID,
            currentHouseholdID: currentHouseholdID,
            nudgeSync: nudgeSync
        )
    }

    /// True while the import is open: reading, previewing or writing. A new import waits for it.
    var isOpen: Bool {
        switch phase {
        case .loading, .preview, .importing: return true
        case .result, .refused: return isWriting
        }
    }

    /// Reads, parses and plans a picked file, all off the main actor.
    func load(url: URL) async {
        phase = .loading
        let read = await Task.detached(priority: .userInitiated) { () -> Result<Data, SeedCSVImport.FatalError> in
            do throws(SeedCSVImport.FatalError) {
                return .success(try SeedCSVImport.readFile(at: url))
            } catch {
                return .failure(error)
            }
        }.value
        switch read {
        case .failure(let error): phase = .refused(error.message)
        case .success(let data): await load(data: data)
        }
    }

    /// Parses and plans file bytes.
    func load(data: Data) async {
        phase = .loading
        let parsed = await Task.detached(priority: .userInitiated) { () -> Result<SeedCSVImport.ParsedFile, SeedCSVImport.FatalError> in
            do throws(SeedCSVImport.FatalError) {
                return .success(try SeedCSVImport.parse(data: data))
            } catch {
                return .failure(error)
            }
        }.value
        switch parsed {
        case .failure(let error):
            phase = .refused(error.message)
        case .success(let file):
            self.file = file
            await buildPreview()
        }
    }

    /// A fresh preview from the store now, off the main actor, keeping what this import has saved.
    func buildPreview() async {
        guard let file, !isWriting else { return }
        guard writer.currentHouseholdID() == householdID else {
            phase = .refused(SeedCSVImportWriter.householdChangedMessage)
            return
        }
        phase = .loading
        let plan: SeedCSVImport.Plan
        do {
            plan = try await writer.freshPlan(for: file)
        } catch {
            phase = .refused("Couldn't read your seeds: \(error.localizedDescription)")
            return
        }
        guard writer.currentHouseholdID() == householdID else {
            phase = .refused(SeedCSVImportWriter.householdChangedMessage)
            return
        }
        self.plan = plan
        phase = .preview
    }

    /// The garden changed. Only an import still reading or previewing is refused: a run in progress
    /// stops on its own check, and a finished one keeps its result.
    func householdChanged() {
        guard !isWriting else { return }
        switch phase {
        case .loading, .preview:
            phase = .refused(SeedCSVImportWriter.householdChangedMessage)
        case .importing, .result, .refused:
            return
        }
    }

    var canImport: Bool {
        guard phase == .preview, !isWriting, let plan else { return false }
        return plan.writeCount > 0
    }

    /// Import. Sets `isWriting` before anything else, so a second tap does nothing. The run belongs to
    /// this session, which the app-wide center keeps, so it finishes even if the sheet goes away.
    func startImport() {
        guard canImport, let plan, let file else { return }
        isWriting = true
        notice = nil
        phase = .importing(done: 0, total: plan.writeCount)
        Task { @MainActor in
            let result = await writer.run(plan: plan, file: file) { [weak self] done, total in
                self?.phase = .importing(done: done, total: total)
            }
            finish(result)
        }
    }

    private func finish(_ result: SeedCSVImportWriter.Result) {
        totals = totals + result.report
        isWriting = false
        switch result.ending {
        case .completed:
            phase = .result(message: SeedCSVImportText.saved(totals), canReview: false)
        case .changed(let fresh):
            plan = fresh
            notice = result.report.savedAnything
                ? Self.changedNotice + " " + SeedCSVImportText.saved(totals)
                : Self.changedNotice
            phase = .preview
        case .householdChanged:
            phase = .result(
                message: SeedCSVImportText.stopped(SeedCSVImportWriter.householdChangedMessage, totals: totals),
                canReview: false
            )
        case .failed(let failure):
            phase = .result(message: SeedCSVImportText.failed(failure, totals: totals), canReview: true)
        case .unreadable(let message):
            phase = .result(
                message: SeedCSVImportText.stopped("Couldn't read your seeds: \(message)", totals: totals),
                canReview: true
            )
        }
    }
}

/// Holds the app's one CSV import. A new import is refused while one is open (reading, previewing
/// or writing); the open one is shown instead. One screen at a time presents it.
@MainActor
@Observable
final class SeedCSVImportCenter {
    static let shared = SeedCSVImportCenter()

    private(set) var session: SeedCSVImportSession?
    /// The `.seedCSVImport` instance presenting the sheet, if any.
    private(set) var presenterID: UUID?

    var isWriting: Bool { session?.isWriting == true }
    var hasOpenImport: Bool { session?.isOpen == true }

    /// Starts `session` for `presenter`, unless an import is open. Returns false when refused; the open
    /// import is then presented by `presenter` if no other screen shows it.
    @discardableResult
    func begin(_ session: SeedCSVImportSession, presenter: UUID) -> Bool {
        guard !hasOpenImport else {
            claim(presenter)
            return false
        }
        self.session = session
        presenterID = presenter
        return true
    }

    enum RequestOutcome: Equatable {
        /// No import is open: pick a file.
        case pickFile
        /// The open import is shown on the requesting screen.
        case showHere
        /// The open import is shown in another window.
        case openElsewhere
    }

    /// An Import request from `presenter`: the picker, or the open import.
    func request(from presenter: UUID) -> RequestOutcome {
        guard hasOpenImport else { return .pickFile }
        claim(presenter)
        return isPresented(by: presenter) ? .showHere : .openElsewhere
    }

    /// Shows the current import, open or finished, from `presenter` when no other screen shows it.
    func claim(_ presenter: UUID) {
        guard session != nil, presenterID == nil else { return }
        presenterID = presenter
    }

    /// The presenting screen went away. The session (and any run) carries on.
    func release(_ presenter: UUID) {
        if presenterID == presenter { presenterID = nil }
    }

    func isPresented(by presenter: UUID) -> Bool {
        session != nil && presenterID == presenter
    }

    /// Cancel or Done. A running import can't be closed.
    func close() {
        guard !isWriting else { return }
        session = nil
        presenterID = nil
    }
}

/// The import's wording.
enum SeedCSVImportText {
    /// "Saved on this device: 12 new, 30 updated", plus any locations and tags created and any type
    /// not applied. It means saved locally, not confirmed uploaded.
    static func saved(_ report: SeedCSVImportWriter.Report, omittingTypeWarningFor omitted: Int? = nil) -> String {
        var text = "Saved on this device: \(report.seedsCreated.formatted()) new, \(report.seedsUpdated.formatted()) updated."
        var created: [String] = []
        if report.locationsCreated > 0 {
            created.append(count(report.locationsCreated, "location", "locations"))
        }
        if report.tagsCreated > 0 {
            created.append(count(report.tagsCreated, "tag", "tags"))
        }
        if !created.isEmpty {
            text += " Created " + created.joined(separator: " and ") + "."
        }
        let warnings = report.typeNotApplied.filter { omitted == nil || $0.line != omitted }
        if !warnings.isEmpty {
            let names = warnings.map { failure in
                failure.line.map { "\(failure.name) (line \($0))" } ?? failure.name
            }
            text += " Type not applied to: " + names.joined(separator: ", ") + ". Import again to retry."
        }
        return text
    }

    static func failed(_ failure: SeedCSVImportWriter.Failure, totals: SeedCSVImportWriter.Report) -> String {
        let place = failure.line.map { "line \($0) (\(failure.name))" } ?? "“\(failure.name)”"
        // A type failure is named here once, not again in the saved summary.
        let omitted = failure.typeOnly ? failure.line : nil
        let retry = failure.typeOnly ? " Import again to retry." : ""
        return "The import stopped at \(place). \(failure.message).\(retry) "
            + saved(totals, omittingTypeWarningFor: omitted)
    }

    static func stopped(_ reason: String, totals: SeedCSVImportWriter.Report) -> String {
        "\(reason) " + saved(totals)
    }

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    static func progress(done: Int, total: Int) -> String {
        "Importing \(done.formatted()) of \(total.formatted())"
    }

    static let noMatchingNotice = "This file doesn't have all four of name, variety, company and year, so every row will be added as a new seed. Nothing will be updated. If an import is interrupted, importing this file again adds its rows again."
    static let openElsewhere = "An import is open in another window."
    static let identityExplanation = "Rows update the seed with the same name, variety, company and year. Changing one of those in the file adds a new seed instead."
}

// MARK: - Entry

extension View {
    /// Attaches the CSV import: the file picker when `isPresented` turns on (or the open import, if
    /// there is one), and the app's import sheet while this screen presents it.
    func seedCSVImport(isPresented: Binding<Bool>) -> some View {
        modifier(SeedCSVImportFlow(isPresented: isPresented))
    }
}

private struct SeedCSVImportFlow: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppEnvironment.self) private var appEnv
    @State private var presenterID = UUID()
    @State private var showingPicker = false
    @State private var showingOpenElsewhere = false
    private let center = SeedCSVImportCenter.shared

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    open { session in await session.load(url: url) }
                case .failure(let error):
                    appEnv.surfaceMessage(humanizeError(error))
                }
            }
            .sheet(isPresented: sheetPresented) {
                if let session = center.session {
                    SeedCSVImportSheet(session: session) { center.close() }
                }
            }
            .onChange(of: isPresented, initial: true) {
                guard isPresented else { return }
                isPresented = false
                requestImport()
            }
            .onChange(of: appEnv.activeGardenHouseholdID) {
                center.session?.householdChanged()
            }
            .onChange(of: center.presenterID) { _, presenter in
                // The presenting window closed (or left Seeds): another screen on Seeds takes the
                // import over. `claim` keeps the first claimant.
                if presenter == nil { center.claim(presenterID) }
            }
            .alert(SeedCSVImportText.openElsewhere, isPresented: $showingOpenElsewhere) {
                Button("OK", role: .cancel) {}
            }
            .onAppear {
                // Showing Seeds again presents the running or finished import.
                center.claim(presenterID)
                #if DEBUG
                openFixtureIfRequested()
                #endif
            }
            .onDisappear {
                center.release(presenterID)
            }
    }

    private var sheetPresented: Binding<Bool> {
        Binding(
            get: { center.isPresented(by: presenterID) },
            set: { shown in
                // Cancel and Done close through the center. A sheet torn down with its screen only
                // releases it; the import carries on.
                if !shown { center.release(presenterID) }
            }
        )
    }

    /// The picker, or the open import when there is one.
    private func requestImport() {
        switch center.request(from: presenterID) {
        case .pickFile: showingPicker = true
        case .showHere: break
        case .openElsewhere: showingOpenElsewhere = true
        }
    }

    private func open(_ load: @escaping @MainActor (SeedCSVImportSession) async -> Void) {
        guard let householdID = appEnv.activeGardenHouseholdID else {
            appEnv.surfaceMessage("Choose a garden before importing seeds.")
            return
        }
        let sync = appEnv.sync
        let session = SeedCSVImportSession(
            householdID: householdID,
            store: sync,
            container: appEnv.container,
            currentHouseholdID: { [appEnv] in appEnv.activeGardenHouseholdID },
            nudgeSync: { SeedCSVImportFlow.nudge(sync) }
        )
        guard center.begin(session, presenter: presenterID) else {
            if !center.isPresented(by: presenterID) { showingOpenElsewhere = true }
            return
        }
        Task { await load(session) }
    }

    /// One nudge at the end of a run: the household-mutation hook schedules the CloudKit save (as each
    /// enqueue does), and the server queue is flushed where the server still runs.
    static func nudge(_ sync: SyncEngine) {
        sync.onLocalHouseholdMutation?()
        if !ServerRetirement.isRetired {
            Task { try? await sync.flushPending() }
        }
    }

    #if DEBUG
    /// Sample-garden screenshots: `-SeedkeepCSVImportFixture` opens the preview of a bundled file once.
    private func openFixtureIfRequested() {
        guard SeedCSVImportFixture.consumeRequest(
            arguments: CommandLine.arguments, isSampleGarden: DevicePreferences.isSampleGarden
        ) else { return }
        open { session in await session.load(data: SeedCSVImportFixture.data) }
    }
    #endif
}

// MARK: - Sheet

struct SeedCSVImportSheet: View {
    @Bindable var session: SeedCSVImportSession
    let close: () -> Void

    var body: some View {
        NavigationStack {
            content
                .background { WBScreenBackground() }
                .navigationTitle("Import CSV")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if isFinished {
                            EmptyView()
                        } else {
                            Button("Cancel", action: close)
                                .disabled(session.isWriting)
                                .accessibilityIdentifier("csvImport.cancel")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isFinished {
                            Button("Done", action: close)
                                .accessibilityIdentifier("csvImport.done")
                        } else {
                            Button("Import") { session.startImport() }
                                .disabled(!session.canImport)
                                .accessibilityIdentifier("csvImport.import")
                        }
                    }
                }
        }
        .interactiveDismissDisabled(true)  // Cancel and Done close it, through the center
        .frame(minWidth: PlatformCapabilities.isMac ? 480 : nil, minHeight: PlatformCapabilities.isMac ? 420 : nil)
        .accessibilityIdentifier("csvImport.sheet")
    }

    private var isFinished: Bool {
        switch session.phase {
        case .result, .refused: return true
        case .loading, .preview, .importing: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView("Reading the file…")
                .font(.wbBody)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preview:
            if let plan = session.plan {
                SeedCSVImportPreview(plan: plan, notice: session.notice)
            }
        case .importing(let done, let total):
            VStack(spacing: 12) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(WBColor.accent)
                Text(SeedCSVImportText.progress(done: done, total: total))
                    .font(.wbBody)
                    .foregroundStyle(WBColor.ink)
                    .monospacedDigit()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("csvImport.progress")
        case .result(let message, let canReview):
            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .font(.wbBody)
                    .foregroundStyle(WBColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("csvImport.result")
                if canReview {
                    Button { Task { await session.buildPreview() } } label: {
                        // The minimum height and the hit shape sit inside the label, so the target grows.
                        Text("Review the rest")
                            .frame(minHeight: WBMetrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("csvImport.review")
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .refused(let message):
            ContentUnavailableView {
                Label("Can't import this file", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .accessibilityIdentifier("csvImport.refused")
        }
    }
}

private struct SeedCSVImportPreview: View {
    let plan: SeedCSVImport.Plan
    let notice: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// How many errors and skipped rows the preview lists; the counts cover the rest.
    private static let listLimit = 5

    var body: some View {
        Form {
            if let notice {
                Section {
                    Text(notice)
                        .font(.wbBody)
                        .foregroundStyle(WBColor.warn)
                        .accessibilityIdentifier("csvImport.notice")
                }
            }
            if !plan.matchingEnabled {
                Section {
                    Label {
                        Text(SeedCSVImportText.noMatchingNotice)
                            .font(.wbBody)
                            .foregroundStyle(WBColor.ink)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(WBColor.warn)
                    }
                    .accessibilityIdentifier("csvImport.noMatching")
                }
            }
            Section {
                countRow("New", plan.newCount, id: "new")
                countRow("Updated", plan.updatedCount, id: "updated")
                countRow("Unchanged", plan.unchangedCount, id: "unchanged")
                countRow("Skipped", plan.skippedCount, id: "skipped")
                countRow("Errors", plan.errorRowCount, id: "errors")
            } header: {
                WBSectionHeader("Seeds")
            } footer: {
                if plan.matchingEnabled {
                    Text(SeedCSVImportText.identityExplanation)
                        .font(.wbFootnote)
                }
            }
            if !plan.newLocations.isEmpty || !plan.newTags.isEmpty {
                Section {
                    if !plan.newLocations.isEmpty {
                        valueRow("Locations", plan.newLocations.map(\.name).joined(separator: ", "), id: "newLocations")
                    }
                    if !plan.newTags.isEmpty {
                        valueRow("Tags", plan.newTags.map(\.name).joined(separator: ", "), id: "newTags")
                    }
                } header: {
                    WBSectionHeader("Will be created")
                }
            }
            if !plan.issues.isEmpty {
                Section {
                    ForEach(Array(plan.issues.prefix(Self.listLimit).enumerated()), id: \.offset) { _, issue in
                        Text(issue.text)
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.warn)
                    }
                    if plan.issues.count > Self.listLimit {
                        Text("And \((plan.issues.count - Self.listLimit).formatted()) more.")
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                    }
                } header: {
                    WBSectionHeader("Errors")
                }
            }
            let skipped = plan.skippedTexts
            if !skipped.isEmpty {
                Section {
                    ForEach(Array(skipped.prefix(Self.listLimit).enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                    }
                    if skipped.count > Self.listLimit {
                        Text("And \((skipped.count - Self.listLimit).formatted()) more.")
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                    }
                } header: {
                    WBSectionHeader("Skipped")
                }
            }
            if plan.writeCount == 0 {
                Section {
                    Text("Nothing to import: every row is unchanged, skipped or has an error.")
                        .font(.wbBody)
                        .foregroundStyle(WBColor.muted)
                }
            }
        }
        .formStyle(.grouped)
        // On the Form itself: after `wbForm()`'s ZStack it would replace the rows' own identifiers.
        .accessibilityIdentifier("csvImport.preview")
        .wbForm()
    }

    private func countRow(_ title: String, _ value: Int, id: String) -> some View {
        valueRow(title, value.formatted(), id: "count.\(id)")
    }

    /// A title and its value side by side, stacked at accessibility sizes. The value wraps; it is never
    /// truncated.
    @ViewBuilder
    private func valueRow(_ title: String, _ value: String, id: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(title)
                .foregroundStyle(WBColor.ink)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value)
                .foregroundStyle(WBColor.muted)
                .monospacedDigit()
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.wbBody)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("csvImport.\(id)")
    }
}
