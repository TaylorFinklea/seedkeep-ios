import SwiftUI
import SwiftData
import SeedkeepKit
import OSLog
import SeedkeepCloudKit
#if os(iOS)
import UIKit
#endif

@main
struct SeedkeepApp: App {
    @State private var environment = AppEnvironment.live()
    @State private var pendingInviteCode: String?
    #if os(macOS)
    @MainActor private static var didRunStartup = false
    #endif
    // iOS routes scenes through ShareSceneDelegate; macOS receives CKShare acceptance on its app delegate.
    #if os(iOS)
    @UIApplicationDelegateAdaptor(SeedkeepAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            #if DEBUG
            if let spikeMode = CKSpike.mode {
                CKSpikeView(mode: spikeMode)
            } else {
                mainRoot
            }
            #else
            mainRoot
            #endif
        }
        .commands { WorkbenchCommands() }

        #if os(macOS)
        // The standard Settings window (⌘, from the app menu). It gets the instances `mainRoot` gets,
        // applied explicitly. It never copies RootView, so opening it starts nothing: startup runs
        // only from the main window.
        Settings {
            MacSettingsWindow()
                .environment(environment)
                .environment(environment.auth)
                .modelContainer(environment.container)
                .modifier(AppAppearanceModifier())
                .tint(WBColor.accent)
        }
        #endif
    }

    @ViewBuilder private var mainRoot: some View {
        RootView(pendingInviteCode: $pendingInviteCode)
            .environment(environment)
            .environment(environment.auth)
            .modelContainer(environment.container)
            // The Light / Dark / System choice from Settings. System (nil) follows the device.
            .modifier(AppAppearanceModifier())
            // Workbench accent for controls, links and progress, on every platform.
            .tint(WBColor.accent)
            .task {
                // Hosted tests (iOS and Mac) share the developer's Keychain and CloudKit account.
                // Keep startup entirely local so a test host never makes a live iCloud identity
                // call, restores a real session, or mutates one.
                guard FeatureFlags.canRunLiveAppStartup else { return }
                #if os(macOS)
                guard !Self.didRunStartup else { return }
                Self.didRunStartup = true
                #endif
                appDelegate.environment = environment   // let the scene delegate drive participant adopt
                await environment.auth.restoreSession()
                // N2-E: the guard was loaded first. With a journal or gone entry, nothing mutated until
                // `restoreSession` verified the owning account; now the runner resumes, the deferred
                // background services start, and windows may show a garden.
                environment.resumeGuardAfterLaunch()
                #if os(macOS)
                if case .signedIn = environment.auth.state {
                    await appDelegate.processPendingShares()
                }
                #else
                await environment.processPendingShare()  // cold-launch: adopt a share tapped while terminated
                #endif
            }
            .onOpenURL { url in
                route(IncomingLink(url: url))
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { route(IncomingLink(url: url)) }
            }
            // Bridge links forwarded by ShareSceneDelegate (covers the case where the custom
            // scene delegate suppresses the SwiftUI .onOpenURL/.onContinueUserActivity hooks above).
            .onChange(of: environment.incomingInviteCode) { _, code in
                if let code { pendingInviteCode = code; environment.incomingInviteCode = nil }
            }
    }

    private func route(_ link: IncomingLink?) {
        switch link {
        case .invite(let code): pendingInviteCode = code
        case nil: break
        }
    }
}

struct RootView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.scenePhase) private var scenePhase
    @Binding var pendingInviteCode: String?
    @State private var whatsNewRelease: ChangelogRelease?
    @State private var workbenchModel = WorkbenchModel()
    /// The window's Garden state, shared by both shells so a Plan survives a size-class switch.
    @State private var gardenSession = GardenSession()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // N2-E: an unreadable guard file blocks every window until it is read again or reset.
        if !appEnv.gardenGuard.isReadable {
            GardenGuardBlockedView()
        } else {
            mainBody
        }
    }

    private var mainBody: some View {
        ZStack {
            switch auth.state {
            case .signedOut:
                // Never a dead end: resolve from here too. Single-flight makes this safe beside
                // the startup task and other windows.
                EntryProgressView()
                    .task {
                        guard FeatureFlags.canRunLiveAppStartup else { return }
                        await auth.restoreSession()
                    }
            case .authenticating:
                EntryProgressView()
            case .needsICloud(let block):
                CloudEntryView(reason: .blocked(block))
            case .choosingGarden(let choice):
                GardenChooserView(choice: choice)
            case .failed(let message):
                CloudEntryView(reason: .failed(message: message))
            case .signedIn where appEnv.isLaunchGuardPending:
                // N2-E: a launch with a journal or gone entry shows no garden, and starts no task,
                // until the guard has resumed after `restoreSession`.
                EntryProgressView()
            case .signedIn where appEnv.isActiveGardenGone:
                // N2-E: the garden is gone. The placeholder stands in until G3's choice replaces it.
                GardenGonePlaceholderView()
            case .signedIn:
                signedInRoot
                    .task(id: snapshotID(auth.state)) {
                        // N2: a cut-short scan save finishes once the identity is confirmed.
                        await appEnv.resumeStagedScansIfNeeded()
                        // A share tapped on a fresh device is adopted before any solo sync.
                        await appEnv.processPendingShare()
                        await appEnv.syncIfPossible()
                    }
                    .task {
                        presentWhatsNewIfNeeded()
                    }
                    // Confirming the identity later, on the same household, must still adopt a
                    // pending share and start CloudKit. Unstructured, so a later flip back to
                    // unverified never cancels work already under way.
                    .onChange(of: auth.isIdentityVerified) { _, verified in
                        guard verified else { return }
                        Task {
                            await appEnv.resumeStagedScansIfNeeded()
                            await appEnv.processPendingShare()
                            await appEnv.syncIfPossible()
                        }
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        // Foregrounding re-runs the full sync + tick
                        // cycle. `PetStateEngine.tickAll` fires inside
                        // `syncIfPossible` so the day's mood snapshot
                        // + streak counters are materialized whenever
                        // the user opens the app.
                        guard newPhase == .active else { return }
                        // iOS retries a pending CKShare accept here; the macOS app delegate retries
                        // on application activation.
                        #if os(iOS)
                        Task { await appEnv.processPendingShare(); await appEnv.syncIfPossible() }
                        #else
                        Task { await appEnv.syncIfPossible() }
                        #endif
                    }
                    .sheet(item: $whatsNewRelease) { release in
                        WhatsNewSheet(initialRelease: release)
                    }
            }
        }
        // N2-E: the launch gate opens once the account is verified, whenever that happens (an offline
        // launch verifies later). Idempotent.
        .task(id: "\(auth.isIdentityVerified)|\(snapshotID(auth.state))|\(appEnv.gardenGuard.isReadable)") {
            guard FeatureFlags.canRunLiveAppStartup else { return }
            appEnv.resumeGuardAfterLaunch()
        }
        .onChange(of: isSignedIn) { _, signedIn in
            if !signedIn {
                workbenchModel.resetForScopeChange()
            }
        }
        .environment(gardenSession)
        .modifier(GardenSessionReconciler(session: gardenSession))
        .sheet(item: Binding(
            get: { pendingInviteCode.map { InviteRoute(code: $0) } },
            set: { newValue in pendingInviteCode = newValue?.code }
        )) { route in
            // Only present invite acceptance once the user is signed in;
            // otherwise the API call fails. The sheet shows the
            // confirmation step so the user can read the code while
            // the auth flow finishes.
            if case .signedIn = auth.state {
                InviteAcceptView(code: route.code)
            } else {
                signedOutInviteView(code: route.code)
            }
        }
    }

    @ViewBuilder
    private var signedInRoot: some View {
        Group {
            #if os(macOS)
            shellForSignedInWindow
            #else
            if WorkbenchShellPolicy.shouldShowWorkbench(
                isMac: false,
                idiom: workbenchDeviceIdiom,
                horizontalSizeClass: horizontalSizeClass
            ) {
                shellForSignedInWindow
            } else {
                MainTabView()
            }
            #endif
        }
        .onChange(of: appEnv.activeGardenHouseholdID) { _, _ in workbenchModel.resetForScopeChange() }
    }

    private var shellForSignedInWindow: some View {
        WorkbenchShell(model: workbenchModel)
            .focusedSceneValue(\.workbenchModel, workbenchModel)
    }

    private var workbenchDeviceIdiom: WorkbenchDeviceIdiom {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
        #else
        .other
        #endif
    }

    private var isSignedIn: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    @ViewBuilder
    private func signedOutInviteView(code: String) -> some View {
        // Retired invite links are a dead flow — don't prompt sign-in to redeem one.
        // Scrolls, and expands past `.medium`, so large text never clips the OK button.
        ScrollView {
            VStack(spacing: 16) {
                InviteRetirementNotice()
                Button("OK") {
                    pendingInviteCode = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
        }
        .presentationDetents([.medium, .large])
    }

    /// Decide the What's New sheet once per launch. Never stacks on a pending
    /// invite/CKShare sheet — if one is up, defer to the next launch. Fresh
    /// installs baseline silently (no popup for a version never upgraded from).
    private func presentWhatsNewIfNeeded() {
        guard pendingInviteCode == nil else { return }
        let current = AppInfo.currentBuild
        let defaults = DevicePreferences.store
        let seen = WhatsNewGate.lastSeenBuild(defaults: defaults)
        if let release = WhatsNewGate.releaseToAutoPresent(
            releases: ChangelogData.releases, lastSeenBuild: seen, currentBuild: current) {
            WhatsNewGate.markSeen(build: release.build, defaults: defaults)
            whatsNewRelease = release
        } else if seen == nil {
            WhatsNewGate.markSeen(build: current, defaults: defaults)
        }
    }

    /// Stable identity for the `.task(id:)` so we kick a sync once per
    /// sign-in transition and not every state mutation.
    private func snapshotID(_ state: AuthController.State) -> String {
        switch state {
        case .signedIn(_, let household): return "signedIn:\(household.id)"
        case .signedOut: return "signedOut"
        case .authenticating: return "authenticating"
        case .needsICloud(let block): return "needsICloud:\(block)"
        case .choosingGarden(let choice): return "choosingGarden:\(choice.reason)"
        case .failed(let m): return "failed:\(m)"
        }
    }
}

private struct InviteRoute: Identifiable {
    let code: String
    var id: String { code }
}

// MARK: - R1 Phase-0 LIVE CloudKit spike harness (DEBUG only, launch-arg gated — inert in normal use)
//
// Drive from the command line:
//   xcrun simctl launch <udid> app.seedkeep.ios --ck-spike asset-engine (gate 0c, one sim)
//   xcrun simctl launch <udid> app.seedkeep.ios --ck-spike roundtrip   (gate 1, one sim)
//   xcrun simctl launch <udid> app.seedkeep.ios --ck-spike merge       (gate 1b, one sim)
//   xcrun simctl launch <udid> app.seedkeep.ios --ck-spike owner       (gate 2 owner)
//   xcrun simctl launch <udid> app.seedkeep.ios --ck-spike participant (gate 2, the OTHER sim/account)
//
// Result is os_log'd (subsystem app.seedkeep.cloud, category Spike, marker "CKSPIKE-RESULT") AND
// written to Documents/ck-spike-result.txt (read back via `simctl get_app_container … data`).
#if DEBUG
enum CKSpike {
    /// Active spike mode from `--ck-spike <mode>` or the `CK_SPIKE` env var; nil = normal app.
    static var mode: String? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ck-spike"), i + 1 < args.count { return args[i + 1] }
        return ProcessInfo.processInfo.environment["CK_SPIKE"]
    }

    static var resultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ck-spike-result.txt")
    }
}

struct CKSpikeView: View {
    let mode: String
    @State private var result = "running…"
    private let log = Logger(subsystem: "app.seedkeep.cloud", category: "Spike")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("CloudKit spike — \(mode)").font(.headline)
                Text(result).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .task { await run() }
    }

    private func run() async {
        let r = await runSeedkeepSpike(mode: mode)
        result = r
        log.log("CKSPIKE-RESULT mode=\(mode, privacy: .public) :: \(r, privacy: .public)")
        try? r.write(to: CKSpike.resultURL, atomically: true, encoding: .utf8)
    }
}
#endif
