# What's New Changelog — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-app "What's New" changelog that auto-presents the latest release's categorized changes once after each update, with a History button to browse past releases.

**Architecture:** A Swift-constant data source (`ChangelogData`, mirroring `CatalogFieldBounds`), a pure `WhatsNewGate` decision function over a `seedkeep.whatsNew.lastSeenBuild` UserDefaults marker, a SwiftUI sheet built from the Herbarium design system, auto-presented from `RootView`'s signed-in branch, plus a Settings entry point and a fail-closed `release.sh` authoring gate.

**Tech Stack:** Swift, SwiftUI, Swift Testing, XcodeGen, bash.

Spec: `.docs/ai/phases/2026-07-18-whats-new-changelog-spec.md`. Bead: `seedkeep-rdd`.

## Global Constraints

- **Light mode only** — the app forces `.preferredColorScheme(.light)` (`SeedkeepApp.swift:54`); design for light, use `HerbColor`/`HerbFont` tokens, add no new colors.
- **Key naming** — the seen-marker key is exactly `seedkeep.whatsNew.lastSeenBuild` (the `seedkeep.<area>.<detail>` idiom).
- **Categories** — exactly New / Improved / Fixed → `HerbColor.sage` / `.ochre` / `.rose`, SF Symbols `sparkles` / `wand.and.stars` / `ladybug`.
- **Detection keys on the build number** (`CFBundleVersion`, Int); display leads with the marketing version as `"<version> (<build>)"`.
- **Regenerate the project after adding files:** `xcodegen generate` (the `.xcodeproj` is XcodeGen-generated; new files aren't compiled until regenerated).
- **Both `scripts/test-gate.sh` lanes must stay green.** Baseline: 460 tests / 50 suites.
- **Do NOT push.** Local commits only. Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Framework:** Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`).

Full-suite verify command (referred to below as **THE GATE**):
```bash
xcodebuild test -project /Users/tfinklea/git/seedkeep-ios/Seedkeep.xcodeproj -scheme Seedkeep \
  -destination 'platform=iOS Simulator,id=FDDFB511-272B-40DD-8927-5E71311E96BA' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```
Single-suite: append `-only-testing:SeedkeepTests/<SuiteName>`.

## File Structure

- Create `Seedkeep/Core/AppInfo.swift` — reads `CFBundleVersion`/`CFBundleShortVersionString` (build/version). One responsibility: app identity numbers.
- Create `Seedkeep/Core/Changelog/ChangelogData.swift` — `ChangelogCategory` (+ presentation), `ChangelogChange`, `ChangelogRelease`, and the authored `ChangelogData.releases` constant. Data + its presentation mapping.
- Create `Seedkeep/Core/Changelog/WhatsNewGate.swift` — pure `releaseToAutoPresent` decision + `lastSeenBuild`/`markSeen` persistence.
- Create `Seedkeep/Features/WhatsNew/WhatsNewSheet.swift` — `WhatsNewSheet`, `ReleaseDetailView`, `ChangelogHistoryView`. Presentation only.
- Create `SeedkeepTests/ChangelogDataTests.swift`, `SeedkeepTests/WhatsNewGateTests.swift`.
- Modify `Seedkeep/App/SeedkeepApp.swift` — auto-present wiring in `RootView`.
- Modify `Seedkeep/Features/Settings/SettingsView.swift` — "What's New" row + unseen dot in `SettingsContent`.
- Modify `scripts/release.sh` — changelog authoring gate + `--skip-changelog`.

---

### Task 1: ChangelogData model + AppInfo

**Files:**
- Create: `Seedkeep/Core/AppInfo.swift`
- Create: `Seedkeep/Core/Changelog/ChangelogData.swift`
- Test: `SeedkeepTests/ChangelogDataTests.swift`

**Interfaces:**
- Produces:
  - `enum AppInfo { static var currentBuild: Int; static var currentVersion: String }`
  - `enum ChangelogCategory: CaseIterable { case new, improved, fixed; var title: String; var symbolName: String; var tint: Color }`
  - `struct ChangelogChange { let category: ChangelogCategory; let text: String }`
  - `struct ChangelogRelease: Identifiable { var id: Int { build }; let version: String; let build: Int; let date: String?; let headline: String?; let changes: [ChangelogChange] }`
  - `enum ChangelogData { static let releases: [ChangelogRelease] }`

- [ ] **Step 1: Write the failing test**

Create `SeedkeepTests/ChangelogDataTests.swift`:
```swift
import Testing
@testable import Seedkeep

@Suite("ChangelogData integrity")
struct ChangelogDataTests {

    @Test("releases are authored newest-first with strictly descending, unique builds")
    func buildsDescendingAndUnique() {
        let builds = ChangelogData.releases.map(\.build)
        #expect(builds == builds.sorted(by: >), "releases must be authored newest-first")
        #expect(Set(builds).count == builds.count, "build numbers must be unique")
    }

    @Test("every release has at least one change and no empty change text")
    func changesWellFormed() {
        for release in ChangelogData.releases {
            #expect(!release.changes.isEmpty, "release \(release.build) has no changes")
            for change in release.changes {
                #expect(!change.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "release \(release.build) has an empty change")
            }
        }
    }

    @Test("the shipping build has an entry")
    func shippingBuildPresent() {
        // Build 50 was the first build to ship the 27d stabilization set; its
        // entry is the initial seed. Guards the release.sh authoring gate's premise.
        #expect(ChangelogData.releases.contains { $0.build == 50 })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run THE GATE with `-only-testing:SeedkeepTests/ChangelogDataTests`.
Expected: FAIL to compile ("cannot find 'ChangelogData' in scope").

- [ ] **Step 3: Create AppInfo**

Create `Seedkeep/Core/AppInfo.swift`:
```swift
import Foundation

/// App identity numbers read from the bundle. `release.sh` stamps
/// `CFBundleVersion` (build) and `CFBundleShortVersionString` (marketing).
enum AppInfo {
    /// The build number (`CFBundleVersion`) as an Int, or 0 if unreadable.
    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// The marketing version (`CFBundleShortVersionString`), e.g. "0.4.0".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}
```

- [ ] **Step 4: Create ChangelogData**

Create `Seedkeep/Core/Changelog/ChangelogData.swift`:
```swift
import SwiftUI

/// One user-facing change in a release, tagged by category.
struct ChangelogChange {
    let category: ChangelogCategory
    let text: String
}

/// The three change categories, each carrying its own display title, SF Symbol,
/// and Herbarium tint — mirrors how `HerbBanner.Severity` owns its presentation.
enum ChangelogCategory: CaseIterable {
    case new, improved, fixed

    var title: String {
        switch self {
        case .new:      "New"
        case .improved: "Improved"
        case .fixed:    "Fixed"
        }
    }

    var symbolName: String {
        switch self {
        case .new:      "sparkles"
        case .improved: "wand.and.stars"
        case .fixed:    "ladybug"
        }
    }

    var tint: Color {
        switch self {
        case .new:      HerbColor.sage
        case .improved: HerbColor.ochre
        case .fixed:    HerbColor.rose
        }
    }
}

/// One shipped release. `build` (CFBundleVersion) is the ordering + detection
/// key; `version` (marketing) leads the display.
struct ChangelogRelease: Identifiable {
    var id: Int { build }
    let version: String
    let build: Int
    let date: String?
    let headline: String?
    let changes: [ChangelogChange]
}

/// The changelog itself — the source of truth, authored newest-first.
/// `release.sh` refuses to cut a build whose number has no entry here.
enum ChangelogData {
    static let releases: [ChangelogRelease] = [
        ChangelogRelease(
            version: "0.4.0",
            build: 50,
            date: "Jul 17, 2026",
            headline: "Sharing & recovery polish",
            changes: [
                ChangelogChange(category: .new,
                    text: "Recover garden entries that didn't make it into a shared garden — Settings flags any that need your review."),
                ChangelogChange(category: .improved,
                    text: "Sharing is simpler — gardens are now shared entirely through iCloud."),
                ChangelogChange(category: .fixed,
                    text: "Old invite links now explain that sharing moved to iCloud instead of failing."),
            ]
        ),
    ]
}
```

- [ ] **Step 5: Regenerate project and run the test**

```bash
cd /Users/tfinklea/git/seedkeep-ios && xcodegen generate
```
Then run THE GATE with `-only-testing:SeedkeepTests/ChangelogDataTests`.
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/tfinklea/git/seedkeep-ios
git add Seedkeep/Core/AppInfo.swift Seedkeep/Core/Changelog/ChangelogData.swift SeedkeepTests/ChangelogDataTests.swift project.yml
git commit -m "feat: changelog data model + AppInfo (seedkeep-rdd)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: WhatsNewGate (pure decision + persistence)

> **Learning-mode note for the executor:** `releaseToAutoPresent` is small, pure, and its edge cases (first-install, downgrade, skipped builds) are the design's real logic. If the user is authoring it themselves, scaffold the signature + doc comment + the failing tests (Steps 1–2), hand it over, and use the Step-3 body below only as the reference answer.

**Files:**
- Create: `Seedkeep/Core/Changelog/WhatsNewGate.swift`
- Test: `SeedkeepTests/WhatsNewGateTests.swift`

**Interfaces:**
- Consumes: `ChangelogRelease` (Task 1).
- Produces:
  - `static func WhatsNewGate.releaseToAutoPresent(releases: [ChangelogRelease], lastSeenBuild: Int?, currentBuild: Int) -> ChangelogRelease?`
  - `static func WhatsNewGate.lastSeenBuild(defaults: UserDefaults = .standard) -> Int?`
  - `static func WhatsNewGate.markSeen(build: Int, defaults: UserDefaults = .standard)`

- [ ] **Step 1: Write the failing test**

Create `SeedkeepTests/WhatsNewGateTests.swift`:
```swift
import Testing
import Foundation
@testable import Seedkeep

@Suite("WhatsNewGate")
struct WhatsNewGateTests {

    private func release(_ build: Int) -> ChangelogRelease {
        ChangelogRelease(version: "0.4.0", build: build, date: nil, headline: nil,
                         changes: [ChangelogChange(category: .new, text: "x")])
    }

    // MARK: releaseToAutoPresent — the six semantics

    @Test("first install (no lastSeen) presents nothing")
    func firstInstall() {
        #expect(WhatsNewGate.releaseToAutoPresent(
            releases: [release(50)], lastSeenBuild: nil, currentBuild: 50) == nil)
    }

    @Test("an update presents the newest release")
    func update() {
        let r = WhatsNewGate.releaseToAutoPresent(
            releases: [release(50), release(49)], lastSeenBuild: 49, currentBuild: 50)
        #expect(r?.build == 50)
    }

    @Test("nothing newer than lastSeen presents nothing")
    func nothingNew() {
        #expect(WhatsNewGate.releaseToAutoPresent(
            releases: [release(50)], lastSeenBuild: 50, currentBuild: 50) == nil)
    }

    @Test("a downgrade presents nothing")
    func downgrade() {
        #expect(WhatsNewGate.releaseToAutoPresent(
            releases: [release(50), release(49)], lastSeenBuild: 50, currentBuild: 49) == nil)
    }

    @Test("empty releases present nothing")
    func empty() {
        #expect(WhatsNewGate.releaseToAutoPresent(
            releases: [], lastSeenBuild: 10, currentBuild: 50) == nil)
    }

    @Test("across skipped builds, only the latest presents")
    func latestOnlyAcrossSkips() {
        let r = WhatsNewGate.releaseToAutoPresent(
            releases: [release(50), release(49)], lastSeenBuild: 48, currentBuild: 50)
        #expect(r?.build == 50)   // not 49
    }

    @Test("never advertises a release newer than the running binary")
    func neverAheadOfBinary() {
        let r = WhatsNewGate.releaseToAutoPresent(
            releases: [release(51), release(50)], lastSeenBuild: 49, currentBuild: 50)
        #expect(r?.build == 50)   // 51 isn't in this binary yet
    }

    // MARK: persistence round-trip (unique key per run — no defaults cleanup needed)

    @Test("markSeen then lastSeenBuild round-trips; unset reads nil")
    func persistenceRoundTrip() {
        let suiteName = "whatsnew-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        #expect(WhatsNewGate.lastSeenBuild(defaults: defaults) == nil)
        WhatsNewGate.markSeen(build: 50, defaults: defaults)
        #expect(WhatsNewGate.lastSeenBuild(defaults: defaults) == 50)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run THE GATE with `-only-testing:SeedkeepTests/WhatsNewGateTests`.
Expected: FAIL to compile ("cannot find 'WhatsNewGate' in scope").

- [ ] **Step 3: Create WhatsNewGate**

Create `Seedkeep/Core/Changelog/WhatsNewGate.swift`:
```swift
import Foundation

/// Decides whether the "What's New" sheet auto-presents at launch, and
/// persists which build the user has already seen. Mirrors the `FeatureFlags`
/// static-over-UserDefaults idiom; the decision function is pure (inject the
/// build + last-seen) so it is host-testable with no bundle or defaults.
enum WhatsNewGate {
    static let lastSeenBuildKey = "seedkeep.whatsNew.lastSeenBuild"

    static func lastSeenBuild(defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: lastSeenBuildKey) as? Int
    }

    static func markSeen(build: Int, defaults: UserDefaults = .standard) {
        defaults.set(build, forKey: lastSeenBuildKey)
    }

    /// The single release to auto-present, or nil to present nothing.
    /// - Fresh install (`lastSeenBuild == nil`) → nil (caller baselines silently).
    /// - Downgrade (`currentBuild < lastSeenBuild`) → nil.
    /// - Otherwise the newest authored release whose build is present in this
    ///   binary (`build <= currentBuild`), but only if it's newer than
    ///   `lastSeenBuild`. Latest-only, even across skipped builds.
    static func releaseToAutoPresent(
        releases: [ChangelogRelease],
        lastSeenBuild: Int?,
        currentBuild: Int
    ) -> ChangelogRelease? {
        guard let seen = lastSeenBuild else { return nil }
        guard currentBuild >= seen else { return nil }
        guard let newest = releases
            .filter({ $0.build <= currentBuild })
            .max(by: { $0.build < $1.build })
        else { return nil }
        return newest.build > seen ? newest : nil
    }
}
```

- [ ] **Step 4: Regenerate project and run the test**

```bash
cd /Users/tfinklea/git/seedkeep-ios && xcodegen generate
```
Then run THE GATE with `-only-testing:SeedkeepTests/WhatsNewGateTests`.
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/tfinklea/git/seedkeep-ios
git add Seedkeep/Core/Changelog/WhatsNewGate.swift SeedkeepTests/WhatsNewGateTests.swift project.yml
git commit -m "feat: WhatsNewGate auto-present decision + seen marker (seedkeep-rdd)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: WhatsNewSheet UI (sheet + release detail + history)

SwiftUI views are verified by compilation + the full suite staying green (this codebase has no view-unit-test harness); there is no new unit test in this task.

**Files:**
- Create: `Seedkeep/Features/WhatsNew/WhatsNewSheet.swift`

**Interfaces:**
- Consumes: `ChangelogData`, `ChangelogRelease`, `ChangelogCategory` (Task 1).
- Produces: `struct WhatsNewSheet: View { init(initialRelease: ChangelogRelease) }`, `struct ReleaseDetailView: View`, `struct ChangelogHistoryView: View`.

- [ ] **Step 1: Create the views**

Create `Seedkeep/Features/WhatsNew/WhatsNewSheet.swift`:
```swift
import SwiftUI

/// The "What's New" sheet: opens on `initialRelease`; a History toolbar button
/// pushes the full release list. Styled with Herbarium tokens (light-mode only).
struct WhatsNewSheet: View {
    let initialRelease: ChangelogRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReleaseDetailView(release: initialRelease)
                .navigationTitle("What's New")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            ChangelogHistoryView()
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
        }
    }
}

/// One release rendered: header (version · date · headline) then its changes
/// grouped by category in New → Improved → Fixed order.
struct ReleaseDetailView: View {
    let release: ChangelogRelease

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                ForEach(ChangelogCategory.allCases, id: \.self) { category in
                    let items = release.changes.filter { $0.category == category }
                    if !items.isEmpty {
                        categorySection(category, items)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VellumBackground().ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(release.version) (\(release.build))")
                .font(HerbFont.display(size: 30))
                .foregroundStyle(HerbColor.ink)
            if let date = release.date {
                Text(date)
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.5)
                    .foregroundStyle(HerbColor.inkFaint)
            }
            if let headline = release.headline {
                Text(headline)
                    .font(HerbFont.bodyItalic(size: 14))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            ScholarRule(verticalMargin: 8)
        }
    }

    private func categorySection(_ category: ChangelogCategory, _ items: [ChangelogChange]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: category.symbolName)
                Text(category.title.uppercased())
                    .font(HerbFont.smallCaps(size: 11))
                    .tracking(2.0)
            }
            .foregroundStyle(category.tint)

            ForEach(Array(items.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(category.tint)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(change.text)
                        .font(HerbFont.body(size: 15))
                        .foregroundStyle(HerbColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Scrollable list of every release, newest-first; each row pushes its detail.
struct ChangelogHistoryView: View {
    var body: some View {
        List(ChangelogData.releases) { release in
            NavigationLink {
                ReleaseDetailView(release: release)
                    .navigationTitle("What's New")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.version) (\(release.build))")
                        .font(HerbFont.bodyEmph(size: 15))
                        .foregroundStyle(HerbColor.ink)
                    if let date = release.date {
                        Text(date)
                            .font(HerbFont.bodyItalic(size: 12))
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                }
            }
        }
        .navigationTitle("Version History")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] **Step 2: Regenerate project and build**

```bash
cd /Users/tfinklea/git/seedkeep-ios && xcodegen generate
```
Then run THE GATE (full suite).
Expected: BUILD SUCCEEDED and the full suite passes. This task adds no unit tests, so the count is unchanged from after Task 2 (baseline 460 + Task 1's 3 integrity tests + Task 2's 8 gate tests).

- [ ] **Step 3: Commit**

```bash
cd /Users/tfinklea/git/seedkeep-ios
git add Seedkeep/Features/WhatsNew/WhatsNewSheet.swift project.yml
git commit -m "feat: What's New sheet + release detail + history views (seedkeep-rdd)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Auto-present wiring in RootView

Glue task — the decision is already unit-tested (Task 2); verified by build + suite green.

**Files:**
- Modify: `Seedkeep/App/SeedkeepApp.swift` (RootView, around lines 79–152)

**Interfaces:**
- Consumes: `ChangelogData`, `WhatsNewGate`, `AppInfo`, `WhatsNewSheet`.

- [ ] **Step 1: Add the state + decision + sheet to RootView**

In `Seedkeep/App/SeedkeepApp.swift`, add a state property to `RootView` (next to `@Binding var pendingInviteCode`):
```swift
    @State private var whatsNewRelease: ChangelogRelease?
```

In the `.signedIn` branch, add a `.task` and a `.sheet(item:)` to the `MainTabView()` chain. The branch becomes:
```swift
            case .signedIn:
                MainTabView()
                    .task(id: snapshotID(auth.state)) {
                        await appEnv.syncIfPossible()
                    }
                    .task {
                        presentWhatsNewIfNeeded()
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        guard newPhase == .active else { return }
                        Task { await appEnv.processPendingShare(); await appEnv.syncIfPossible() }
                    }
                    .overlay { SproutAssistantOverlay() }
                    .sheet(item: $whatsNewRelease) { release in
                        WhatsNewSheet(initialRelease: release)
                    }
```

Add this method to `RootView` (next to `snapshotID`):
```swift
    /// Decide the What's New sheet once per launch. Never stacks on a pending
    /// invite/CKShare sheet — if one is up, defer to the next launch. Fresh
    /// installs baseline silently (no popup for a version never upgraded from).
    private func presentWhatsNewIfNeeded() {
        guard pendingInviteCode == nil else { return }
        let current = AppInfo.currentBuild
        let seen = WhatsNewGate.lastSeenBuild()
        if let release = WhatsNewGate.releaseToAutoPresent(
            releases: ChangelogData.releases, lastSeenBuild: seen, currentBuild: current) {
            WhatsNewGate.markSeen(build: release.build)
            whatsNewRelease = release
        } else if seen == nil {
            WhatsNewGate.markSeen(build: current)
        }
    }
```

- [ ] **Step 2: Build and run the suite**

Run THE GATE (full suite). No regenerate needed (no new files).
Expected: BUILD SUCCEEDED, full suite green.

- [ ] **Step 3: Manual smoke (simulator)**

Because the auto-present has no view-unit-test seam, verify behavior directly once:
```bash
# Reset the marker so the gate treats this like a fresh state, then confirm no crash on launch.
xcrun simctl spawn FDDFB511-272B-40DD-8927-5E71311E96BA defaults delete app.seedkeep.ios seedkeep.whatsNew.lastSeenBuild 2>/dev/null || true
```
Build+run once in the booted simulator; confirm a fresh launch does NOT show the sheet (first-install baseline), and that the app launches cleanly. (Full update→present behavior is exercised on-device in the release's device-verify pass.)

- [ ] **Step 4: Commit**

```bash
cd /Users/tfinklea/git/seedkeep-ios
git add Seedkeep/App/SeedkeepApp.swift
git commit -m "feat: auto-present What's New once per build at launch (seedkeep-rdd)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Settings "What's New" row + unseen dot

**Files:**
- Modify: `Seedkeep/Features/Settings/SettingsView.swift` (`SettingsContent`, around lines 11–336)

- [ ] **Step 1: Add state, the row, the sheet, and the unseen flag**

In `SettingsContent`, add a state property (next to the other `@State` at lines 16–23):
```swift
    @State private var showingWhatsNew = false
```

Add a new `Section` immediately BEFORE the build-stamp footer `Section` (currently at line 318):
```swift
                Section {
                    Button {
                        if let newest = ChangelogData.releases.map(\.build).max() {
                            WhatsNewGate.markSeen(build: newest)
                        }
                        showingWhatsNew = true
                    } label: {
                        HStack {
                            Label("What's New", systemImage: "sparkles")
                            Spacer()
                            if whatsNewUnseen {
                                Circle().fill(HerbColor.rose).frame(width: 8, height: 8)
                            }
                        }
                    }
                } header: {
                    Rubric(text: "changelog")
                }
```

Add the What's New sheet next to the existing `.sheet(isPresented: $showingJournalRecoveryReview)` (line 331):
```swift
        .sheet(isPresented: $showingWhatsNew) {
            if let latest = ChangelogData.releases.max(by: { $0.build < $1.build }) {
                WhatsNewSheet(initialRelease: latest)
            }
        }
```

Add the computed flag (next to `buildRoman`, around line 344):
```swift
    /// True when the newest authored release is newer than what the user has
    /// last opened — drives the small unseen dot on the What's New row.
    private var whatsNewUnseen: Bool {
        guard let newest = ChangelogData.releases.map(\.build).max() else { return false }
        return newest > (WhatsNewGate.lastSeenBuild() ?? .max)
    }
```

- [ ] **Step 2: Build and run the suite**

Run THE GATE (full suite).
Expected: BUILD SUCCEEDED, full suite green.

- [ ] **Step 3: Commit**

```bash
cd /Users/tfinklea/git/seedkeep-ios
git add Seedkeep/Features/Settings/SettingsView.swift
git commit -m "feat: Settings 'What's New' row with unseen dot (seedkeep-rdd)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: release.sh changelog authoring gate

**Files:**
- Modify: `scripts/release.sh`

- [ ] **Step 1: Add the `--skip-changelog` flag**

In the flag loop (lines 41–49), add a case and a default above the loop. Change the flag block to:
```bash
BUMP_TYPE="build"
SKIP_TESTS=false
SKIP_CHANGELOG=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUMP_TYPE="build"; shift ;;
        --patch) BUMP_TYPE="patch"; shift ;;
        --minor) BUMP_TYPE="minor"; shift ;;
        --skip-tests) SKIP_TESTS=true; shift ;;
        --skip-changelog) SKIP_CHANGELOG=true; shift ;;
        *) fail "Unknown flag: $1. Use --build, --patch, --minor, --skip-tests, or --skip-changelog." ;;
    esac
done
```

- [ ] **Step 2: Add the gate after NEW_BUILD is computed**

Immediately after `NEW_BUILD=$((OLD_BUILD + 1))` (line ~71) and before the "run tests" block (line ~84), insert:
```bash
# ---------- changelog authoring gate (fail-closed) ----------
CHANGELOG_FILE="$REPO_ROOT/Seedkeep/Core/Changelog/ChangelogData.swift"
if [[ "$SKIP_CHANGELOG" == "false" ]]; then
    [[ -f "$CHANGELOG_FILE" ]] || fail "Changelog file not found at $CHANGELOG_FILE"
    if ! grep -Eq "build:[[:space:]]*${NEW_BUILD}([^0-9]|\$)" "$CHANGELOG_FILE"; then
        fail "No changelog entry for build ${NEW_BUILD}. Add a ChangelogRelease with 'build: ${NEW_BUILD}' to ChangelogData.swift, or pass --skip-changelog for a throwaway diagnostic build."
    fi
    echo "[release] changelog entry for build ${NEW_BUILD} present"
else
    echo "[release] WARNING: skipping changelog gate (--skip-changelog)"
fi
```

- [ ] **Step 3: Verify the gate logic both ways**

The gate is a grep; test it directly without cutting a build. With `project.yml` at build 50, the next `NEW_BUILD` is 51 (no entry yet → must fail); build 50 has an entry (→ must pass):
```bash
cd /Users/tfinklea/git/seedkeep-ios
grep -Eq "build:[[:space:]]*50([^0-9]|$)" Seedkeep/Core/Changelog/ChangelogData.swift && echo "build 50: PRESENT (expected)"
grep -Eq "build:[[:space:]]*51([^0-9]|$)" Seedkeep/Core/Changelog/ChangelogData.swift || echo "build 51: ABSENT (expected — gate would fail-closed)"
bash -n scripts/release.sh && echo "release.sh: syntax OK"
```
Expected output: `build 50: PRESENT (expected)`, `build 51: ABSENT (expected …)`, `release.sh: syntax OK`.

- [ ] **Step 4: Commit**

```bash
cd /Users/tfinklea/git/seedkeep-ios
git add scripts/release.sh
git commit -m "feat: gate release.sh on a changelog entry for the new build (seedkeep-rdd)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Final full-gate + close-out

- [ ] **Step 1: Run both test-gate lanes**

```bash
cd /Users/tfinklea/git/seedkeep-ios && scripts/test-gate.sh
```
Expected: `[test-gate] all required tests passed` (SeedkeepKit + SeedkeepCloudKit + CloudKit-OFF app lane + production-default CloudKit-ON contract). App-lane total = 460 baseline + Task 1's 3 integrity tests + Task 2's 8 gate tests (≈471 across ≈52 suites); the requirement is green, not a specific count — record whatever the run reports.

- [ ] **Step 2: Update handoff + close the bead**

- Add a build-51 changelog entry note is NOT needed here (this feature ships in the next cut; its own entry gets authored when that build is cut — the gate will require it).
- `bd close seedkeep-rdd --reason "…"` after the gate is green.
- Update `.docs/ai/current-state.md` (umbrella) with the feature landing.

---

## Self-Review

**Spec coverage:**
- Swift-constant data source → Task 1 ✓
- Build-keyed, first-install/downgrade/latest-only detection → Task 2 (6+ semantics tested) ✓
- release.sh gate + `--skip-changelog` → Task 6 ✓
- Auto-present once per build, defer on invite-sheet collision → Task 4 ✓
- Sheet UI (InviteRetirementNotice/HerbBanner idioms, drill-down history) → Task 3 ✓
- Settings entry point + unseen dot → Task 5 ✓
- Initial content seed (build 50) → Task 1 ✓
- Testing invariants (gate semantics, data integrity) → Tasks 1, 2 ✓
- Both test-gate lanes green → Task 7 ✓

**Type consistency:** `ChangelogRelease`/`ChangelogChange`/`ChangelogCategory`/`ChangelogData.releases`, `WhatsNewGate.releaseToAutoPresent/lastSeenBuild/markSeen`, `AppInfo.currentBuild`, `WhatsNewSheet(initialRelease:)` — names/signatures identical across Tasks 1–6. ✓

**Placeholder scan:** every code step contains complete, compile-ready code; no TBD/TODO except the deliberate learning-mode hand-off note in Task 2 (which still ships the full reference body). ✓
