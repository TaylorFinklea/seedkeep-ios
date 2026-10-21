// Audit findings the R2d audit suppresses. Starts empty. Each entry needs a disposition, a reason and the
// condition for rechecking it; a "deferred defect" needs the owner's approval before it is added.
import XCTest

struct AuditAllowlistEntry: Sendable {
    enum Disposition: Sendable, CustomStringConvertible {
        /// A verified false positive.
        case acceptedLimitation
        /// A real defect fixed later, in the named phase. Needs the owner's approval.
        case deferredDefect(phase: String)

        var description: String {
            switch self {
            case .acceptedLimitation: "accepted limitation (verified false positive)"
            case .deferredDefect(let phase): "deferred defect (\(phase))"
            }
        }
    }

    /// How the entry names the element. A label and element type are used only when the element has
    /// no identifier.
    enum ElementMatch: Sendable, Equatable {
        case identifier(String)
        case labelAndType(label: String, type: XCUIElement.ElementType)
    }

    let destination: AuditDestination
    /// The recorded checkpoint name: `top`, `scrolled`, `page.<n>`, or an anchor's name.
    let checkpoint: String
    let auditType: XCUIAccessibilityAuditType
    let element: ElementMatch
    let configurations: Set<AuditConfiguration>
    let disposition: Disposition
    let reason: String
    let recheckWhen: String
}

enum AuditAllowlist {
    static let entries: [AuditAllowlistEntry] = []

    /// The index of the first entry matching an issue, or nil. An issue without an element never matches.
    static func match(
        destination: AuditDestination,
        checkpoint: String,
        auditType: XCUIAccessibilityAuditType,
        identifier: String?,
        label: String?,
        elementType: XCUIElement.ElementType?,
        configuration: AuditConfiguration,
        in entries: [AuditAllowlistEntry] = entries
    ) -> Int? {
        guard let elementType else { return nil }
        let hasIdentifier = !(identifier ?? "").isEmpty
        return entries.firstIndex { entry in
            guard entry.destination == destination,
                  entry.checkpoint == checkpoint,
                  entry.auditType == auditType,
                  entry.configurations.contains(configuration) else { return false }
            switch entry.element {
            case .identifier(let expected):
                return hasIdentifier && identifier == expected
            case .labelAndType(let expectedLabel, let expectedType):
                return !hasIdentifier && label == expectedLabel && elementType == expectedType
            }
        }
    }
}
