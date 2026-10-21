// Launch arguments for the accessibility audit and sample-garden screenshots (R2d). `-SeedkeepAuditLaunch`
// is read in every build and means "this must be a sample-garden launch": `AppEnvironment.live()` fails closed
// otherwise. `-SeedkeepAppearance` is DEBUG-only and is read only together with `-SeedkeepFixture`.
import Foundation

enum AuditLaunch {
    static let auditArgument = "-SeedkeepAuditLaunch"
    #if DEBUG
    static let appearanceArgument = "-SeedkeepAppearance"
    #endif

    /// What `AppEnvironment.live()` does before it builds anything live.
    enum Decision: Equatable {
        case proceed
        /// The audit was requested, but this is not a sample-garden launch.
        case refuse
    }

    /// True when the launch asks for an audit run, in any build.
    static func requestsAudit(arguments: [String]) -> Bool {
        arguments.contains(auditArgument)
    }

    /// Fails closed. An audit launch must be sample-garden mode, so a Release build, or a DEBUG launch
    /// without `-SeedkeepFixture`, refuses to start the live app.
    static func decision(arguments: [String], sampleGarden: Bool) -> Decision {
        requestsAudit(arguments: arguments) && !sampleGarden ? .refuse : .proceed
    }

    #if DEBUG
    /// The appearance a sample-garden launch asks for: `light` or `dark` after `-SeedkeepAppearance`. Nil
    /// when `-SeedkeepFixture` is absent, the value is missing, or the value is anything else.
    static func appearanceOverride(arguments: [String]) -> AppAppearance? {
        guard arguments.contains(FixtureMode.launchArgument),
              let index = arguments.firstIndex(of: appearanceArgument),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case AppAppearance.light.rawValue: return .light
        case AppAppearance.dark.rawValue: return .dark
        default: return nil
        }
    }
    #endif
}
