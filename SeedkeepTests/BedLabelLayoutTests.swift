import CoreGraphics
import Testing
@testable import Seedkeep

/// Tests for `BedLabelLayout`: the label priority order, and the overlap rule that decides which
/// labels are drawn.
@Suite("Bed canvas — label layout")
struct BedLabelLayoutTests {
    private static func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 40, _ height: CGFloat = 16) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Overlap rule

    @Test func separatedLabelsAreAllVisible() {
        let frames = ["a": Self.rect(0, 0), "b": Self.rect(100, 0), "c": Self.rect(0, 50)]
        let visible = BedLabelLayout.visibleIDs(frames: frames, order: ["a", "b", "c"])
        #expect(visible == ["a", "b", "c"])
    }

    @Test func aLaterOverlappingLabelIsHidden() {
        let frames = ["first": Self.rect(0, 0), "second": Self.rect(20, 4)]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["first", "second"]) == ["first"])
    }

    @Test func theEarlierLabelInTheOrderWins() {
        let frames = ["a": Self.rect(0, 0), "b": Self.rect(20, 0)]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["b", "a"]) == ["b"])
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["a", "b"]) == ["a"])
    }

    @Test func rectanglesTouchingAlongAVerticalEdgeAreBothVisible() {
        // The right edge of `left` (x 40) meets the left edge of `right`: touching, not intersecting.
        let frames = ["left": Self.rect(0, 0), "right": Self.rect(40, 0)]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["left", "right"]) == ["left", "right"])
    }

    @Test func rectanglesTouchingAlongAHorizontalEdgeAreBothVisible() {
        // The bottom edge of `upper` (y 16) meets the top edge of `lower`.
        let frames = ["upper": Self.rect(0, 0), "lower": Self.rect(0, 16)]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["upper", "lower"]) == ["upper", "lower"])
    }

    @Test func overlappingLabelIsHiddenWhileAClearLaterLabelIsKept() {
        // `middle` overlaps `first`, so it is hidden. `last` clears `first`, so it is kept.
        let frames = [
            "first": Self.rect(0, 0),
            "middle": Self.rect(30, 0),
            "last": Self.rect(80, 0),
        ]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["first", "middle", "last"]) == ["first", "last"])
    }

    @Test func aHiddenLabelDoesNotBlockLaterLabels() {
        // `b` is hidden by `a`. `c` overlaps `b` but not `a`, so `c` is kept.
        let frames = [
            "a": Self.rect(0, 0),
            "b": Self.rect(30, 0),
            "c": Self.rect(60, 0),
        ]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["a", "b", "c"]) == ["a", "c"])
    }

    // MARK: - Membership

    @Test func idsWithoutAFrameAreLeftOut() {
        let frames = ["a": Self.rect(0, 0)]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["missing", "a"]) == ["a"])
    }

    @Test func idsMissingFromTheOrderAreNotDrawn() {
        let frames = ["a": Self.rect(0, 0), "b": Self.rect(100, 0)]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: ["a"]) == ["a"])
    }

    @Test func noFramesGivesNoLabels() {
        #expect(BedLabelLayout.visibleIDs(frames: [:], order: []).isEmpty)
    }

    // MARK: - Priority order

    @Test func orderPutsTheTopOfTheBedFirst() {
        let anchors = [
            BedLabelLayout.Anchor(id: "bottom", x: 1, y: 0.5),
            BedLabelLayout.Anchor(id: "top", x: 1, y: 5),
            BedLabelLayout.Anchor(id: "middle", x: 1, y: 2),
        ]
        #expect(BedLabelLayout.order(anchors) == ["top", "middle", "bottom"])
    }

    @Test func orderBreaksTiesByXThenID() {
        let anchors = [
            BedLabelLayout.Anchor(id: "z", x: 1, y: 2),
            BedLabelLayout.Anchor(id: "a", x: 3, y: 2),
            BedLabelLayout.Anchor(id: "m", x: 1, y: 2),
        ]
        #expect(BedLabelLayout.order(anchors) == ["m", "z", "a"])
    }

    @Test func theTopLabelWinsWhenTwoOverlap() {
        // Listed bottom first, but the top one has priority.
        let anchors = [
            BedLabelLayout.Anchor(id: "low", x: 0, y: 1),
            BedLabelLayout.Anchor(id: "high", x: 0, y: 5),
        ]
        let frames = ["low": Self.rect(0, 0), "high": Self.rect(10, 0)]
        #expect(BedLabelLayout.visibleIDs(frames: frames, order: BedLabelLayout.order(anchors)) == ["high"])
    }
}
