import CoreGraphics

/// Pure helpers for the bed canvas's placement labels: the order they are considered in, and which
/// of them are drawn so that no two drawn labels overlap.
enum BedLabelLayout {
    /// A placement's position in feet, used to order its label.
    struct Anchor: Equatable {
        let id: String
        let x: Double
        let y: Double
    }

    /// The label priority: the top of the drawn bed first (y descending), then left first (x
    /// ascending), then id.
    static func order(_ anchors: [Anchor]) -> [String] {
        anchors.sorted { a, b in
            if a.y != b.y { return a.y > b.y }
            if a.x != b.x { return a.x < b.x }
            return a.id < b.id
        }
        .map(\.id)
    }

    /// The ids whose labels are drawn. Walks `order` and keeps a label only if its rectangle
    /// doesn't intersect one already kept, so an earlier label wins. Ids without a frame, and ids
    /// missing from `order`, are left out.
    static func visibleIDs(frames: [String: CGRect], order: [String]) -> Set<String> {
        var kept: [CGRect] = []
        var visible: Set<String> = []
        for id in order {
            guard let rect = frames[id], !visible.contains(id) else { continue }
            guard !kept.contains(where: { intersects($0, rect) }) else { continue }
            kept.append(rect)
            visible.insert(id)
        }
        return visible
    }

    /// Whether two rectangles share interior area. Rectangles that only touch along an edge don't
    /// intersect, and an empty rectangle intersects nothing.
    /// How far to shift a label sideways so it stays inside a canvas of `width`, at least `margin`
    /// from each edge. A label wider than the room left aligns to the left margin.
    static func insideShift(for frame: CGRect, width: CGFloat, margin: CGFloat) -> CGFloat {
        if frame.width > width - 2 * margin { return margin - frame.minX }
        if frame.minX < margin { return margin - frame.minX }
        if frame.maxX > width - margin { return (width - margin) - frame.maxX }
        return 0
    }

    private static func intersects(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }
}
