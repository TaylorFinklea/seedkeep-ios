import CoreGraphics
import Foundation

/// Pure helpers for moving a placement on the bed canvas: the half-foot grid, the bed bounds, the
/// no-op rule, the feet text and VoiceOver label, and the room for an enlarged hit area.
///
/// Bed coordinates put (0, 0) at the bottom-left corner, with x growing right and y growing up,
/// both in feet. Drag and the accessibility move actions both move through `moved`.
enum BedPlacementMath {
    /// The grid step in feet. Positions snap to it, and each accessibility move is one step.
    static let step: Double = 0.5

    /// Moves a placement by (`dx`, `dy`) feet in bed coordinates (a positive `dy` is up), then
    /// snaps and clamps each axis into the bed. Returns nil when the result is the current
    /// position, so a no-op writes nothing.
    static func moved(
        x: Double,
        y: Double,
        dx: Double,
        dy: Double,
        widthFeet: Double,
        lengthFeet: Double
    ) -> (x: Double, y: Double)? {
        // Only a moving axis snaps, so a one-axis move leaves an older off-grid value on the other
        // axis alone.
        let newX = dx == 0 ? x : snapped(x + dx, extent: widthFeet)
        let newY = dy == 0 ? y : snapped(y + dy, extent: lengthFeet)
        guard newX != x || newY != y else { return nil }
        return (newX, newY)
    }

    /// Rounds `value` to the nearest grid point, then clamps it to [0, the last grid point within
    /// `extent`]. A 2.3 ft bed's last grid point is 2.0, because 2.5 lies outside it.
    static func snapped(_ value: Double, extent: Double) -> Double {
        let grid = (value / step).rounded() * step
        if grid <= 0 { return 0 }
        let lastPoint = max(0, (extent / step).rounded(.down) * step)
        return min(grid, lastPoint)
    }

    /// A position in feet as text: "2" for a whole number, "2.5" otherwise.
    static func feetText(_ feet: Double) -> String {
        if feet.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(feet))" }
        return String(format: "%.1f", feet)
    }

    /// The VoiceOver label for a placement: "<name>, <x> feet from the left, <y> feet from the
    /// bottom". An empty name is left out.
    static func accessibilityLabel(name: String, x: Double, y: Double) -> String {
        let position = "\(distance(x)) from the left, \(distance(y)) from the bottom"
        return name.isEmpty ? position : "\(name), \(position)"
    }

    /// "1 foot", otherwise "<n> feet" ("0 feet", "0.5 feet", "2.5 feet").
    private static func distance(_ feet: Double) -> String {
        feet == 1 ? "1 foot" : "\(feetText(feet)) feet"
    }

    /// Whether the dot at `index` can take a hit area of `hitDiameter` without that area reaching
    /// another dot. The area reaches a dot when their centers are closer than the sum of their
    /// radii, so a dot that only touches the area's edge is allowed. `centers` are the screen
    /// centers of every dot, in the same order as the placements.
    static func canEnlargeHitArea(
        at index: Int,
        centers: [CGPoint],
        dotDiameter: CGFloat,
        hitDiameter: CGFloat
    ) -> Bool {
        let reach = (dotDiameter + hitDiameter) / 2
        let center = centers[index]
        return centers.indices.allSatisfy { other in
            guard other != index else { return true }
            let dx = centers[other].x - center.x
            let dy = centers[other].y - center.y
            return dx * dx + dy * dy >= reach * reach
        }
    }
}
