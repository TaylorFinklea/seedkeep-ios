import CoreGraphics
import Testing
@testable import Seedkeep

/// Tests for `BedPlacementMath`: the half-foot grid, the bed bounds, the no-op rule, each move
/// direction, the feet text and VoiceOver label, and the hit-area room check.
@Suite("Bed canvas — placement math")
struct BedPlacementMathTests {
    // MARK: - Grid and bounds

    @Test func snapsToTheHalfFootGrid() {
        #expect(BedPlacementMath.snapped(1.2, extent: 10) == 1.0)
        #expect(BedPlacementMath.snapped(1.3, extent: 10) == 1.5)
        #expect(BedPlacementMath.snapped(2.0, extent: 10) == 2.0)
    }

    @Test func clampsToTheLastGridPointInsideTheBed() {
        // A 2.3 ft bed's last grid point is 2.0. The old clamp-before-round gave 2.5.
        #expect(BedPlacementMath.snapped(2.5, extent: 2.3) == 2.0)
        #expect(BedPlacementMath.snapped(2.3, extent: 2.3) == 2.0)
        #expect(BedPlacementMath.snapped(9, extent: 2.3) == 2.0)
    }

    @Test func clampsNegativePositionsToZero() {
        #expect(BedPlacementMath.snapped(-0.4, extent: 4) == 0)
        #expect(BedPlacementMath.snapped(-3, extent: 4) == 0)
    }

    @Test func movedClampsAtTheFarEdgeOfAnOddSizedBed() {
        let result = BedPlacementMath.moved(
            x: 1.5, y: 1, dx: 2, dy: 0, widthFeet: 2.3, lengthFeet: 6
        )
        #expect(result?.x == 2.0)
        #expect(result?.y == 1.0)
    }

    @Test func movedClampsAtTheNearEdge() {
        let result = BedPlacementMath.moved(
            x: 0.5, y: 0.5, dx: -2, dy: -2, widthFeet: 4, lengthFeet: 4
        )
        #expect(result?.x == 0)
        #expect(result?.y == 0)
    }

    @Test func draggedPositionLandsOnTheGrid() {
        // 1.0 + 0.9 = 1.9, which rounds to 2.0.
        let result = BedPlacementMath.moved(
            x: 1.0, y: 1.0, dx: 0.9, dy: 0, widthFeet: 4, lengthFeet: 4
        )
        #expect(result?.x == 2.0)
    }

    // MARK: - No-op

    @Test func noOpReturnsNil() {
        // No movement at all.
        #expect(BedPlacementMath.moved(x: 1, y: 1, dx: 0, dy: 0, widthFeet: 4, lengthFeet: 4) == nil)
        // Against the left wall.
        #expect(BedPlacementMath.moved(x: 0, y: 2, dx: -0.5, dy: 0, widthFeet: 4, lengthFeet: 4) == nil)
        // Against the top of the bed.
        #expect(BedPlacementMath.moved(x: 2, y: 4, dx: 0, dy: 0.5, widthFeet: 4, lengthFeet: 4) == nil)
        // At the last grid point of a 2.3 ft bed: a move right stays at 2.0.
        #expect(BedPlacementMath.moved(x: 2.0, y: 1, dx: 0.5, dy: 0, widthFeet: 2.3, lengthFeet: 6) == nil)
    }

    // MARK: - Directions

    @Test func moveLeftDecreasesX() {
        let result = BedPlacementMath.moved(x: 2, y: 2, dx: -0.5, dy: 0, widthFeet: 10, lengthFeet: 10)
        #expect(result?.x == 1.5)
        #expect(result?.y == 2)
    }

    @Test func moveRightIncreasesX() {
        let result = BedPlacementMath.moved(x: 2, y: 2, dx: 0.5, dy: 0, widthFeet: 10, lengthFeet: 10)
        #expect(result?.x == 2.5)
        #expect(result?.y == 2)
    }

    @Test func moveUpIncreasesY() {
        // Bed y grows upward, so a positive dy moves the placement up the drawn bed.
        let result = BedPlacementMath.moved(x: 2, y: 2, dx: 0, dy: 0.5, widthFeet: 10, lengthFeet: 10)
        #expect(result?.x == 2)
        #expect(result?.y == 2.5)
    }

    @Test func moveDownDecreasesY() {
        let result = BedPlacementMath.moved(x: 2, y: 2, dx: 0, dy: -0.5, widthFeet: 10, lengthFeet: 10)
        #expect(result?.x == 2)
        #expect(result?.y == 1.5)
    }

    // MARK: - Feet text and accessibility label

    @Test func feetTextOmitsTheDecimalForWholeNumbers() {
        #expect(BedPlacementMath.feetText(2) == "2")
        #expect(BedPlacementMath.feetText(0) == "0")
        #expect(BedPlacementMath.feetText(2.5) == "2.5")
    }

    @Test func accessibilityLabelNamesThePlacementAndItsPosition() {
        #expect(
            BedPlacementMath.accessibilityLabel(name: "Tomato", x: 2.5, y: 3)
                == "Tomato, 2.5 feet from the left, 3 feet from the bottom"
        )
    }

    @Test func accessibilityLabelLeavesOutAnEmptyName() {
        #expect(
            BedPlacementMath.accessibilityLabel(name: "", x: 0, y: 0.5)
                == "0 feet from the left, 0.5 feet from the bottom"
        )
    }

    @Test func aOneAxisMoveLeavesTheOtherAxisAlone() {
        // An older off-grid x stays as it is when only y moves.
        let up = BedPlacementMath.moved(x: 1.3, y: 1, dx: 0, dy: 0.5, widthFeet: 4, lengthFeet: 8)
        #expect(up?.x == 1.3)
        #expect(up?.y == 1.5)
        // At the top edge, moving up is a no-op even with an off-grid x.
        #expect(BedPlacementMath.moved(x: 1.3, y: 8, dx: 0, dy: 0.5, widthFeet: 4, lengthFeet: 8) == nil)
    }

    @Test func oneFootIsSingular() {
        #expect(BedPlacementMath.accessibilityLabel(name: "Basil", x: 1, y: 1.5)
                == "Basil, 1 foot from the left, 1.5 feet from the bottom")
    }

    // MARK: - Enlarged hit area

    @Test func anIsolatedDotCanEnlargeItsHitArea() {
        let centers = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)]
        #expect(BedPlacementMath.canEnlargeHitArea(at: 0, centers: centers, dotDiameter: 18, hitDiameter: 44))
        #expect(BedPlacementMath.canEnlargeHitArea(at: 1, centers: centers, dotDiameter: 18, hitDiameter: 44))
    }

    @Test func aNeighbourJustOutsideTheReachAllowsEnlargement() {
        // The 44pt area has a 22pt radius and the 18pt dot a 9pt radius. At 31pt apart they just
        // touch, which is allowed.
        let centers = [CGPoint(x: 0, y: 0), CGPoint(x: 31, y: 0)]
        #expect(BedPlacementMath.canEnlargeHitArea(at: 0, centers: centers, dotDiameter: 18, hitDiameter: 44))
        #expect(BedPlacementMath.canEnlargeHitArea(at: 1, centers: centers, dotDiameter: 18, hitDiameter: 44))
    }

    @Test func aNeighbourInsideTheReachBlocksEnlargement() {
        let centers = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0)]
        #expect(!BedPlacementMath.canEnlargeHitArea(at: 0, centers: centers, dotDiameter: 18, hitDiameter: 44))
        #expect(!BedPlacementMath.canEnlargeHitArea(at: 1, centers: centers, dotDiameter: 18, hitDiameter: 44))
    }

    @Test func distanceIsMeasuredInBothAxes() {
        // (22, 22) is about 31.1pt away, which is outside the reach. (21, 21) is about 29.7pt, which is inside.
        let far = [CGPoint(x: 0, y: 0), CGPoint(x: 22, y: 22)]
        let near = [CGPoint(x: 0, y: 0), CGPoint(x: 21, y: 21)]
        #expect(BedPlacementMath.canEnlargeHitArea(at: 0, centers: far, dotDiameter: 18, hitDiameter: 44))
        #expect(!BedPlacementMath.canEnlargeHitArea(at: 0, centers: near, dotDiameter: 18, hitDiameter: 44))
    }

    @Test func onlyTheDotsWithRoomGetTheLargerArea() {
        // The first two dots are 20pt apart and block each other. The third is clear.
        let centers = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 200, y: 0)]
        let enlargeable = centers.indices.map {
            BedPlacementMath.canEnlargeHitArea(at: $0, centers: centers, dotDiameter: 18, hitDiameter: 44)
        }
        #expect(enlargeable == [false, false, true])
    }

    @Test func aDotOnTopOfAnotherBlocksEnlargement() {
        let centers = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]
        #expect(!BedPlacementMath.canEnlargeHitArea(at: 0, centers: centers, dotDiameter: 18, hitDiameter: 44))
    }
}
