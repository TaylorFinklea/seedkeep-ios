import SwiftUI
import SwiftData
import SeedkeepKit
import OSLog
import SeedkeepCloudKit

@main
struct SeedkeepApp: App {
    @State private var environment = AppEnvironment.live()
    @State private var pendingInviteCode: String?
    @State private var pendingHandoff: AccountDeletionHandoffLink?
    // Pure-SwiftUI app otherwise — this delegate exists only to route scenes through ShareSceneDelegate
    // so CKShare acceptance is delivered (WindowGroup doesn't surface it on the app delegate).
    @UIApplicationDelegateAdaptor(SeedkeepAppDelegate.self) private var appDelegate

    init() {
        configureTabBarAppearance()
    }

    /// Apply the IM Fell English SC small-caps font to tab bar labels
    /// while keeping the native liquid-glass tab bar chrome. The
    /// PostScript name has underscores (not what the filename suggests).
    private func configureTabBarAppearance() {
        guard let smallCapsFont = UIFont(name: "IM_FELL_English_SC", size: 10) else { return }
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: smallCapsFont,
            .kern: 1.2
        ]
        UITabBarItem.appearance().setTitleTextAttributes(labelAttrs, for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes(labelAttrs, for: .selected)
    }

    var body: some Scene {
        WindowGroup {
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
    }

    @ViewBuilder private var mainRoot: some View {
        RootView(pendingInviteCode: $pendingInviteCode, pendingHandoff: $pendingHandoff)
            .environment(environment)
            .environment(environment.auth)
            .modelContainer(environment.container)
            // Force light mode while we validate the Herbarium palette
            // on-device. Dark variants exist in HerbColor but are gated
            // off until they've been verified screen-by-screen.
            .preferredColorScheme(.light)
            .task {
                appDelegate.environment = environment   // let the scene delegate drive participant adopt
                // BEFORE restoring the session, and deliberately not gated
                // on it: an account deletion that committed but whose
                // response was lost took this device's session with it, so
                // restore will 401 and every signed-in code path stays out
                // of reach. The receipt lookup needs no credentials and is
                // the only thing that can finish that deletion.
                await environment.recoverCommittedAccountDeletion()
                await environment.auth.restoreSession()
                await environment.processPendingShare()  // cold-launch: adopt a share tapped while terminated
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
            .onChange(of: environment.incomingHandoffLink) { _, link in
                if let link { pendingHandoff = link; environment.incomingHandoffLink = nil }
            }
    }

    private func route(_ link: IncomingLink?) {
        switch link {
        case .invite(let code): pendingInviteCode = code
        case .gardenHandoff(let handoff): pendingHandoff = handoff
        case nil: break
        }
    }
}

struct RootView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.scenePhase) private var scenePhase
    @Binding var pendingInviteCode: String?
    @Binding var pendingHandoff: AccountDeletionHandoffLink?
    @State private var whatsNewRelease: ChangelogRelease?
    /// Per-session acknowledgement that the successor-resume sheet was
    /// closed. The checkpoint it comes from is durable, so without this the
    /// sheet would reopen the instant it is dismissed.
    @State private var resumeDismissed = false
    /// The fingerprint of whichever handoff presentation is currently on
    /// screen, recorded the moment it appears — the ONLY reliable way to
    /// know what a later dismissal is closing, since a `.sheet(item:)`
    /// setter always receives `nil` regardless of which item it was.
    @State private var presentedHandoffID: String?

    var body: some View {
        ZStack {
            switch auth.state {
            case .signedOut, .failed:
                SignInView()
            case .authenticating:
                ProgressView("Signing you in…")
                    .progressViewStyle(.circular)
            case .signedIn:
                MainTabView()
                    .task(id: snapshotID(auth.state)) {
                        await appEnv.syncIfPossible()
                    }
                    .task {
                        presentWhatsNewIfNeeded()
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        // Foregrounding re-runs the full sync + tick
                        // cycle. `PetStateEngine.tickAll` fires inside
                        // `syncIfPossible` so the day's mood snapshot
                        // + streak counters are materialized whenever
                        // the user opens the app.
                        guard newPhase == .active else { return }
                        // Also drain any pending CKShare accept (a cold accept whose first attempt
                        // failed re-deposits the metadata; foregrounding retries it without a relaunch).
                        Task { await appEnv.processPendingShare(); await appEnv.syncIfPossible() }
                    }
                    .sheet(item: $whatsNewRelease) { release in
                        WhatsNewSheet(initialRelease: release)
                    }
            }
        }
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
        // A shared-garden handoff, presented only once there is an account
        // to accept it with. `AccountDeletionRootRoute` owns that decision
        // — a modal over `SignInView` would hide the sign-in the link is
        // waiting for, and the only way out of it would throw the
        // capability away. A handoff already accepted on this device
        // reopens the same surface with no token at all, which is the only
        // way back in after the single-use link has been spent.
        .sheet(item: Binding(
            get: { handoffRoute.presentation },
            set: { newValue in
                guard newValue == nil else { return }
                // `newValue` is always nil on dismiss, so the ONLY way to
                // know which presentation just closed is what we recorded
                // when it appeared. Comparing that recorded fingerprint —
                // not "is pendingHandoff non-nil" — is what lets a
                // rotated token that arrived while the old sheet was
                // still up survive this dismissal
                // (`AccountDeletionRootRoute.dismissalClearsPendingLink`).
                if presentedHandoffID == AccountDeletionRootRoute.Presentation.resumeID {
                    resumeDismissed = true
                } else if AccountDeletionRootRoute.dismissalClearsPendingLink(
                    dismissedID: presentedHandoffID, pendingLink: pendingHandoff) {
                    pendingHandoff = nil
                }
                presentedHandoffID = nil
            }
        )) { presentation in
            // The fingerprint is captured HERE, from the item SwiftUI is
            // actually instantiating this content for — never from the
            // parent's `handoffRoute` recomputing. A changed `Identifiable`
            // id on `.sheet(item:)` tears the old content down and
            // presents fresh content for the new id, so `onAppear` fires
            // in the same relative order dismissal does: if a rotated
            // link B replaces A while A is still on screen, A's teardown
            // (and its `set(nil)`, still comparing against A's
            // fingerprint) happens before B's `onAppear` overwrites it —
            // exactly the ordering `AccountDeletionRootRoute
            // .dismissalClearsPendingLink` depends on. Tracking the
            // DESIRED route via `onChange` instead would update the
            // fingerprint the instant the route recomputes, which can run
            // ahead of what is actually still rendered.
            AccountDeletionHandoffAcceptView(model: appEnv.accountDeletionFlow,
                                             link: presentation.link)
                .onAppear { presentedHandoffID = presentation.id }
        }
        .onChange(of: isSignedIn) { _, signedIn in
            // Sign-in is what a held link and a relaunched successor
            // checkpoint were both waiting for.
            if signedIn { appEnv.accountDeletionFlow.reload() }
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    private var handoffRoute: AccountDeletionRootRoute {
        AccountDeletionRootRoute.decide(
            pendingLink: pendingHandoff,
            isSignedIn: isSignedIn,
            hasHandoffInProgress: !resumeDismissed
                && appEnv.accountDeletionFlow.hasHandoffInProgress)
    }

    @ViewBuilder
    private func signedOutInviteView(code: String) -> some View {
        // Retired invite links are a dead flow — don't prompt sign-in to redeem one.
        VStack(spacing: 16) {
            InviteRetirementNotice()
            Button("OK") {
                pendingInviteCode = nil
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
        .presentationDetents([.medium])
    }

    /// Decide the What's New sheet once per launch. Never stacks on a pending
    /// invite/handoff/CKShare sheet — if one is up, defer to the next launch. Fresh
    /// installs baseline silently (no popup for a version never upgraded from).
    private func presentWhatsNewIfNeeded() {
        guard pendingInviteCode == nil, pendingHandoff == nil else { return }
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

    /// Stable identity for the `.task(id:)` so we kick a sync once per
    /// sign-in transition and not every state mutation.
    private func snapshotID(_ state: AuthController.State) -> String {
        switch state {
        case .signedIn(_, let household): return "signedIn:\(household.id)"
        case .signedOut: return "signedOut"
        case .authenticating: return "authenticating"
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
//   xcrun simctl launch <udid> app.seedkeep.ios --ck-spike asset-transfer-destination (gate 0b successor)
//   xcrun simctl launch <udid> app.seedkeep.ios --ck-spike asset-transfer-source      (gate 0b source)
//   xcrun simctl launch <udid> app.seedkeep.ios --ck-spike asset-transfer-cleanup     (gate 0b successor verify/cleanup)
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
        let r: String
        if AccountDeletionGate0bSpike.handles(mode) {
            r = await AccountDeletionGate0bSpike.run(mode: mode)
        } else {
            r = await runSeedkeepSpike(mode: mode)
        }
        result = r
        log.log("CKSPIKE-RESULT mode=\(mode, privacy: .public) :: \(r, privacy: .public)")
        try? r.write(to: CKSpike.resultURL, atomically: true, encoding: .utf8)
    }
}
#endif
