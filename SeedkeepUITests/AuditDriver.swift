// Navigation, scrolling and measurement helpers for the R2d accessibility audit. Every wait is bounded and
// waits on an element; nothing sleeps for a fixed time.
import XCTest

struct AuditFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class AuditDriver {
    let app: XCUIApplication
    let configuration: AuditConfiguration

    /// Bounded waits, in seconds.
    static let readinessTimeout: TimeInterval = 30
    static let screenTimeout: TimeInterval = 15
    static let elementTimeout: TimeInterval = 10
    /// The most pages any scroll walks before it gives up, so a scroll that never ends still stops.
    static let maxPages = 20

    init(app: XCUIApplication, configuration: AuditConfiguration) {
        self.app = app
        self.configuration = configuration
    }

    func log(_ message: String) {
        print("[a11y-audit] \(message) config=\(configuration.rawValue)")
    }

    // MARK: - Elements

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = AuditDriver.elementTimeout) throws -> XCUIElement {
        guard element.waitForExistence(timeout: timeout) else {
            throw AuditFailure(description: "\(what) did not appear within \(Int(timeout)) s")
        }
        return element
    }

    func requireScreen(_ destination: AuditDestination) throws {
        try require(element(destination.screenIdentifier), destination.screenIdentifier, timeout: Self.screenTimeout)
    }

    /// Taps an element, refusing anything on the never-touch list.
    func tap(_ element: XCUIElement, _ what: String) throws {
        try require(element, what)
        let label = element.label
        if AuditManifest.neverTouchLabels.contains(where: { label.caseInsensitiveCompare($0) == .orderedSame }) {
            throw AuditFailure(description: "refused to activate never-touch element \"\(label)\" (\(what))")
        }
        element.tap()
    }

    // MARK: - Tabs

    /// Tab selections made by identifier and by label, reported in the summary.
    private(set) var tabsByIdentifier = 0
    private(set) var tabsByLabel = 0

    func selectTab(_ tab: AuditTab) throws {
        try require(app.tabBars.buttons[tab.title], "tab \(tab.title)")
        let byIdentifier = app.tabBars.buttons[tab.identifier]
        if byIdentifier.exists {
            tabsByIdentifier += 1
            try tap(byIdentifier, "tab \(tab.identifier)")
        } else {
            // Contract fallback: if `.tabItem` doesn't pass the identifier through, use the tab's label.
            tabsByLabel += 1
            log("NOTE \(tab.identifier) not on the tab button; selecting by label \"\(tab.title)\"")
            try tap(app.tabBars.buttons[tab.title], "tab \(tab.title)")
        }
    }

    // MARK: - Leaving a destination

    /// Returns to the destination's tab root: the nav bar back button for pushed screens, the sheet's own
    /// Close, Cancel or Done for sheets.
    func leave(_ destination: AuditDestination) throws {
        let labels: [String]
        switch destination {
        case .addSeed: labels = ["Cancel"]
        case .randomPick:
            // The compact Seeds list presents random pick without a Close button: swipe it down.
            try swipeDownSheet(destination)
            return try confirmLeft(destination)
        case .whatsNew: labels = ["Close"]
        case .windows: labels = ["Done"]
        case .journalEntry: labels = ["Cancel", "BackButton"]
        default: labels = ["BackButton", "Back"]
        }
        let bar = app.navigationBars
        var tapped = false
        for label in labels {
            let button = bar.buttons[label].firstMatch
            if button.exists {
                try tap(button, "\(label) on \(destination.rawValue)")
                tapped = true
                break
            }
        }
        if !tapped {
            // A pushed screen whose back button has no "BackButton" identifier: the bar's first button.
            guard !destination.isTabRoot, labels.contains("BackButton") else {
                throw AuditFailure(description: "no \(labels.joined(separator: "/")) button on \(destination.rawValue)")
            }
            try tap(bar.buttons.element(boundBy: 0), "back button on \(destination.rawValue)")
        }
        try confirmLeft(destination)
    }

    /// Swipes a sheet down from just below its top edge.
    func swipeDownSheet(_ destination: AuditDestination) throws {
        let sheet = element(destination.screenIdentifier)
        try require(sheet, destination.screenIdentifier)
        let frame = window.frame
        let startY = (sheet.frame.minY + 12 - frame.minY) / frame.height
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.02, startY)))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func confirmLeft(_ destination: AuditDestination) throws {
        let child = element(destination.screenIdentifier)
        guard child.waitForNonExistence(timeout: Self.screenTimeout) else {
            throw AuditFailure(description: "\(destination.screenIdentifier) still present after leaving it")
        }
        try requireScreen(AuditDestination(rawValue: destination.tab.rawValue)!)
    }

    // MARK: - Scrolling

    enum Direction { case down, up }

    private var window: XCUIElement { app.windows.firstMatch }

    /// The bottom of the usable area: the tab bar's top when one is showing.
    private func visibleBottom() -> CGFloat {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, !tabBar.frame.isEmpty { return tabBar.frame.minY }
        return window.frame.maxY
    }

    /// True when the element is on screen, inside the window and above the tab bar: wholly, or (for a
    /// row about to be tapped) at its centre.
    func isInView(_ element: XCUIElement, wholly: Bool = true) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        let bounds = window.frame
        if !wholly {
            // Hittable, and its centre (where a tap lands) clear of the tab bar.
            return element.isHittable && frame.midY < visibleBottom() - 8
        }
        return frame.minY >= bounds.minY && frame.maxY <= visibleBottom() && frame.minX >= bounds.minX
            && frame.maxX <= bounds.maxX
    }

    /// One drag of about half a screen. Returns false when nothing moved (the end of the content).
    @discardableResult
    func scrollPage(_ direction: Direction) throws -> Bool {
        let before = try settledFingerprint()
        let (start, end) = try dragPoints(direction)
        // The short press before the drag is below the long-press threshold, and holding at the end
        // stops the scroll's momentum, so each page moves by the drag distance only.
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 900),
                    thenHoldForDuration: 0.15)
        let after = try settledFingerprint()
        // An audit can relayout the screen (its Dynamic Type check), moving content back from the end.
        // So the end is also when a drag lands exactly where the previous drag landed.
        defer { lastDragResult = after }
        return after != before && after != lastDragResult
    }

    /// Where the previous page drag left the screen.
    private var lastDragResult: [String]?

    /// Starts a new scroll sequence, so a drag isn't compared with one made before leaving the screen.
    func resetScrollTracking() {
        lastDragResult = nil
    }

    /// The fingerprint once two snapshots in a row agree, so a bounce at the end of the content has
    /// settled. Each snapshot takes a fraction of a second, which spaces the reads; bounded.
    private func settledFingerprint() throws -> [String] {
        var last = try fingerprint()
        for _ in 0..<10 {
            let next = try fingerprint()
            if next == last { return next }
            last = next
        }
        throw AuditFailure(description: "the screen did not settle after a scroll")
    }

    /// Scrolls down, then up, until the element is in view.
    func scrollUntilInView(_ element: XCUIElement, _ what: String, wholly: Bool = true) throws {
        if isInView(element, wholly: wholly) { return }
        for direction in [Direction.down, .up] {
            resetScrollTracking()
            for _ in 0..<Self.maxPages {
                let moved = try scrollPage(direction)
                if isInView(element, wholly: wholly) { return }
                if !moved { break }
            }
        }
        throw AuditFailure(description: "could not scroll \(what) into view")
    }

    func scrollToTop() throws {
        resetScrollTracking()
        for _ in 0..<Self.maxPages {
            if try !scrollPage(.up) { return }
        }
        throw AuditFailure(description: "did not reach the top within \(Self.maxPages) pages")
    }

    /// What is on screen: each labelled element's type, label, identifier and frame.
    private func fingerprint() throws -> [String] {
        var lines: [String] = []
        let bounds = window.frame
        func walk(_ snapshot: XCUIElementSnapshot) {
            // Scroll indicators come and go with every drag, so they don't count as content moving.
            let isScrollBar = snapshot.label.localizedCaseInsensitiveContains("scroll bar")
            if (!snapshot.label.isEmpty || !snapshot.identifier.isEmpty), !isScrollBar,
               snapshot.frame.intersects(bounds) {
                let f = snapshot.frame.integral
                lines.append("\(snapshot.elementType.rawValue)|\(snapshot.label)|\(snapshot.identifier)|\(f.minX),\(f.minY),\(f.width),\(f.height)")
            }
            snapshot.children.forEach(walk)
        }
        walk(try app.snapshot())
        return lines
    }

    /// Element types a drag must not start on: controls a drag could change, and the bed canvas's dots
    /// (dragging one moves the planting). Text fields are safe: a drag scrolls and only a tap focuses.
    private static let unsafeDragTypes: Set<XCUIElement.ElementType> = [
        .switch, .toggle, .slider, .stepper, .segmentedControl, .picker, .pickerWheel, .datePicker, .map,
    ]

    /// A start and end point for a page drag, in a column whose start point is clear of unsafe elements.
    private func dragPoints(_ direction: Direction) throws -> (XCUICoordinate, XCUICoordinate) {
        var unsafe: [CGRect] = []
        func walk(_ snapshot: XCUIElementSnapshot) {
            if Self.unsafeDragTypes.contains(snapshot.elementType) || snapshot.label.contains("from the left") {
                unsafe.append(snapshot.frame.insetBy(dx: -16, dy: -16))
            }
            snapshot.children.forEach(walk)
        }
        walk(try app.snapshot())

        let frame = window.frame
        let bottom = min(visibleBottom(), frame.maxY) - frame.minY
        let low = (bottom - 24) / frame.height
        let high = 0.28
        for dx in [0.5, 0.88, 0.12, 0.96, 0.04] {
            for lowY in [low * 0.92, low * 0.8, low, low * 0.68] {
                let fromY = direction == .down ? lowY : high
                let toY = direction == .down ? high : lowY
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: fromY))
                if !unsafe.contains(where: { $0.contains(start.screenPoint) }) {
                    return (start, window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: toY)))
                }
            }
        }
        throw AuditFailure(description: "no drag start clear of controls")
    }

    // MARK: - Effective configuration

    /// The median luminance (0 to 1) of a grid sampled from a screenshot of the app. The page background
    /// covers most of every screen, so the median is the background's.
    func medianLuminance() throws -> Double {
        // The screenshot is of the Seedkeep app only, is not attached, and is discarded here.
        guard let image = app.screenshot().image.cgImage else {
            throw AuditFailure(description: "screenshot has no bitmap")
        }
        let width = 24, height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw AuditFailure(description: "could not sample the screenshot") }
        var values: [Double] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        values.sort()
        return values[values.count / 2]
    }

    /// The height of Today's screen title (not the tab button of the same name).
    func todayTitleHeight() throws -> CGFloat {
        let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", "Today"))
        try require(matches.firstMatch, "Today title")
        let bottom = visibleBottom()
        let heights = matches.allElementsBoundByIndex
            .map(\.frame)
            .filter { !$0.isEmpty && $0.maxY <= bottom }
            .map(\.height)
        guard let height = heights.max() else {
            throw AuditFailure(description: "no Today title above the tab bar")
        }
        return height
    }
}
