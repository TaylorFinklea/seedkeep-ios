import SwiftUI
import SeedkeepKit

/// Top-down view of a bed with placed planting events. Renders the bed
/// rectangle scaled to fit the available space (proportional to the bed's
/// width_feet × length_feet), then plots each event with x_feet/y_feet
/// set as a dot, with a faded ring around it whose radius is the plant's
/// required spacing pulled from the catalog (plant_spacing_inches / 2).
/// Overlapping rings give a visual cue that the layout is over-packed.
///
/// When `onMove` is provided, dots become draggable. A drag or a move action
/// goes through `BedPlacementMath.moved` (half-foot grid, clamped to the bed),
/// and the callback fires only when the position changes, so the caller can
/// persist via the sync engine. Each placement is one accessibility element;
/// with `onMove`, it also gets Move left/right/up/down actions.
struct BedLayoutCanvas: View {
    /// One thing to plot inside the bed. Spacing in feet, computed from
    /// the catalog's plant_spacing_inches (zero or nil = just a dot).
    struct Placement: Identifiable, Equatable {
        let id: String
        let x: Double        // feet
        let y: Double        // feet
        let spacingFeet: Double
        let label: String
        let isSowing: Bool
    }

    let widthFeet: Double
    let lengthFeet: Double
    let placements: [Placement]
    /// Optional move handler. When non-nil, dots respond to drags and get
    /// move actions, and report the new (x, y) in feet.
    var onMove: ((_ id: String, _ newX: Double, _ newY: Double) -> Void)? = nil

    /// Onscreen padding so the bed doesn't kiss the canvas edges.
    private let inset: CGFloat = 16
    /// Dot diameter when draggable, and when not.
    private let dotSize: CGFloat = 18
    private let plainDotSize: CGFloat = 12
    /// Hit area of a draggable dot, where it doesn't reach a neighbour's dot.
    private let hitSize: CGFloat = 44
    /// Distance from a dot's center down to its label's top edge.
    private let labelGap: CGFloat = 11
    /// Id under which the footprint label's frame is reported, so planting labels avoid it.
    private static let footprintID = "__footprint"

    /// Coordinate space that label frames are reported in.
    private static let canvasSpace = "bedCanvas"

    /// Live drag offset per dot, in screen points. Reset on drop.
    @State private var liveOffsets: [String: CGSize] = [:]
    /// Label frames from the last layout, in the canvas's coordinate space.
    @State private var labelFrames: [String: CGRect] = [:]

    var body: some View {
        GeometryReader { geo in
            let fit = bedFit(in: geo.size)
            let centers = placements.map { center(of: $0, in: fit) }
            let enlarged = enlargedIDs(centers: centers)
            let labels = labelSlots(fit: fit)
            // Frames as drawn: each shifted to stay inside the canvas. The footprint label comes first,
            // so a planting label that would cover it is the one hidden.
            let shifted = labelFrames.mapValues {
                $0.offsetBy(dx: BedLabelLayout.insideShift(for: $0, width: geo.size.width, margin: 4), dy: 0)
            }
            // A label that would run past the canvas's bottom edge isn't drawn.
            .filter { $0.value.maxY <= geo.size.height - 2 }
            let visible = BedLabelLayout.visibleIDs(
                frames: shifted,
                order: [Self.footprintID] + BedLabelLayout.order(labels.map {
                    BedLabelLayout.Anchor(id: $0.id, x: $0.placement.x, y: $0.placement.y)
                })
            )

            ZStack(alignment: .topLeading) {
                // Bed rectangle. Decorative: the placements carry the accessibility.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(WBColor.muted, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(WBColor.line.opacity(0.5))
                    )
                    .frame(width: fit.bedWidth, height: fit.bedHeight)
                    .offset(x: fit.originX - inset, y: fit.originY - inset)
                    .padding(inset)
                    .accessibilityHidden(true)

                // Footprint scale label in the corner.
                Text("\(BedPlacementMath.feetText(widthFeet))′ × \(BedPlacementMath.feetText(lengthFeet))′")
                    .font(.caption2.monospaced())
                    .foregroundStyle(WBColor.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: .capsule)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: BedLabelFramesKey.self,
                                value: [Self.footprintID: geo.frame(in: .named(Self.canvasSpace))]
                            )
                        }
                    }
                    .offset(x: fit.originX, y: fit.originY)
                    .accessibilityLabel("\(BedPlacementMath.feetText(widthFeet)) by \(BedPlacementMath.feetText(lengthFeet)) feet")

                // Each placement's spacing ring and dot.
                ForEach(placements) { p in
                    placementMarks(p, fit: fit, enlarged: enlarged.contains(p.id))
                }

                // Labels sit above the dots, so no dot is drawn over one.
                labelLayer(labels, visible: visible, width: geo.size.width)
            }
            // The drawing is to scale, so its text stops growing at the largest standard size; at
            // accessibility sizes, labels would cover the plantings. Each planting's name stays in its
            // VoiceOver label and in the events list below.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: Self.canvasSpace)
            .onPreferenceChange(BedLabelFramesKey.self) { frames in
                // Write only on change, so the layout settles.
                if labelFrames != frames { labelFrames = frames }
            }
        }
        .frame(height: canvasHeight)
        .background(WBColor.panel2)
        .clipShape(.rect(cornerRadius: 10))
    }

    /// A placement's spacing ring and dot. The dot is the one accessibility element for the placement.
    @ViewBuilder
    private func placementMarks(_ p: Placement, fit: Fit, enlarged: Bool) -> some View {
        let base = center(of: p, in: fit)
        let offset = liveOffsets[p.id] ?? .zero
        let center = CGPoint(x: base.x + offset.width, y: base.y + offset.height)
        let draggable = onMove != nil
        let dot: CGFloat = draggable ? dotSize : plainDotSize
        let hit: CGFloat = draggable && enlarged ? hitSize : dot

        // Spacing ring (only if we have meaningful spacing).
        if p.spacingFeet > 0 {
            let diameter = max(8, CGFloat(p.spacingFeet) * fit.scale)
            centered(
                Circle()
                    .stroke(p.isSowing ? WBColor.accent.opacity(0.5) : WBColor.faint.opacity(0.6),
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .background(
                        Circle().fill(p.isSowing ? WBColor.accent.opacity(0.12) : WBColor.faint.opacity(0.10))
                    )
                    .frame(width: diameter, height: diameter)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true),
                on: center,
                size: diameter
            )
        }

        // Dot. Draggable dots sit in a hit area of `hit` points.
        let dotView = Circle()
            .fill(p.isSowing ? WBColor.accent : WBColor.muted)
            .frame(width: dot, height: dot)
            .shadow(color: .black.opacity(0.18), radius: draggable ? 2 : 0)
            .frame(width: hit, height: hit)
            .contentShape(Circle())
            .gesture(draggable ? dragGesture(for: p, fit: fit) : nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BedPlacementMath.accessibilityLabel(name: p.label, x: p.x, y: p.y))
        centered(movable(dotView, p), on: center, size: hit)
    }

    /// Adds the four move actions when moving is enabled. Each moves one step.
    @ViewBuilder
    private func movable<V: View>(_ view: V, _ p: Placement) -> some View {
        if onMove != nil {
            view
                .accessibilityAction(named: "Move left") { move(p, dx: -BedPlacementMath.step, dy: 0) }
                .accessibilityAction(named: "Move right") { move(p, dx: BedPlacementMath.step, dy: 0) }
                .accessibilityAction(named: "Move up") { move(p, dx: 0, dy: BedPlacementMath.step) }
                .accessibilityAction(named: "Move down") { move(p, dx: 0, dy: -BedPlacementMath.step) }
        } else {
            view
        }
    }

    /// Moves `view` so its center sits on `point`, keeping its own size. A `.position`ed view spans
    /// the whole canvas, which would give VoiceOver the canvas as the element's frame.
    private func centered<V: View>(_ view: V, on point: CGPoint, size: CGFloat) -> some View {
        view.offset(x: point.x - size / 2, y: point.y - size / 2)
    }

    /// Moves a placement by (`dx`, `dy`) feet in bed coordinates through `BedPlacementMath.moved`.
    /// A no-op calls nothing.
    private func move(_ p: Placement, dx: Double, dy: Double) {
        guard let onMove, let target = BedPlacementMath.moved(
            x: p.x, y: p.y, dx: dx, dy: dy, widthFeet: widthFeet, lengthFeet: lengthFeet
        ) else { return }
        onMove(p.id, target.x, target.y)
    }

    private func dragGesture(for p: Placement, fit: Fit) -> some Gesture {
        // In the canvas's space: the dot's own space moves with the live offset, which would make
        // the translation chase itself.
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                liveOffsets[p.id] = value.translation
            }
            .onEnded { value in
                liveOffsets[p.id] = .zero
                guard fit.scale > 0 else { return }
                // Screen y grows downward and bed y grows up, so a downward drag lowers y.
                let dx = Double(value.translation.width / fit.scale)
                let dy = -Double(value.translation.height / fit.scale)
                move(p, dx: dx, dy: dy)
            }
    }

    // MARK: - Labels

    /// A label and its center. The center follows a drag.
    private struct LabelSlot: Identifiable {
        let placement: Placement
        let point: CGPoint
        var id: String { placement.id }
    }

    /// The placements that have a label which fits in the canvas.
    private func labelSlots(fit: Fit) -> [LabelSlot] {
        placements.compactMap { p in
            guard !p.label.isEmpty else { return nil }
            let base = center(of: p, in: fit)
            let offset = liveOffsets[p.id] ?? .zero
            let dotY = base.y + offset.height
            guard dotY + dotSize <= fit.originY + fit.bedHeight + inset else { return nil }
            return LabelSlot(placement: p, point: CGPoint(x: base.x + offset.width, y: dotY + labelGap))
        }
    }

    /// The labels, in two passes. The first draws every label at zero opacity so that each frame is
    /// measured, whether or not it is shown. The second draws only the `visible` labels. Measurement
    /// doesn't depend on visibility, so the layout settles. Labels are hidden from accessibility:
    /// the placement's element names them.
    @ViewBuilder
    private func labelLayer(_ labels: [LabelSlot], visible: Set<String>, width: CGFloat) -> some View {
        ForEach(labels) { slot in
            belowDot(
                labelText(slot.placement)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: BedLabelFramesKey.self,
                                value: [slot.id: geo.frame(in: .named(Self.canvasSpace))]
                            )
                        }
                    },
                at: slot.point,
                maxWidth: width - 8
            )
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        ForEach(labels.filter { visible.contains($0.id) }) { slot in
            let shift = labelFrames[slot.id].map {
                BedLabelLayout.insideShift(for: $0, width: width, margin: 4)
            } ?? 0
            belowDot(labelText(slot.placement), at: slot.point, maxWidth: width - 8)
                .offset(x: shift)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    /// Places `label` with its top edge at `point`, centered horizontally, so it hangs below its dot.
    /// It is at most `maxWidth` wide; a longer name truncates instead of running off the canvas.
    private func belowDot(_ label: some View, at point: CGPoint, maxWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: max(maxWidth, 1), height: 1)
            .overlay(alignment: .top) { label.fixedSize(horizontal: false, vertical: true) }
            .position(point)
    }

    private func labelText(_ p: Placement) -> some View {
        Text(p.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(WBColor.ink)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.thinMaterial, in: .capsule)
    }

    // MARK: - Geometry

    /// The bed's fit in a canvas: points per foot, and where the bed's top-left corner sits.
    private struct Fit {
        let scale: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        let bedWidth: CGFloat
        let bedHeight: CGFloat
    }

    /// Fits the bed inside the canvas, keeping its proportions and centring it.
    private func bedFit(in size: CGSize) -> Fit {
        let drawableWidth = size.width - inset * 2
        let drawableHeight = size.height - inset * 2
        let scale: CGFloat = (widthFeet > 0 && lengthFeet > 0)
            ? min(drawableWidth / CGFloat(widthFeet), drawableHeight / CGFloat(lengthFeet))
            : 0
        let bedWidth = CGFloat(widthFeet) * scale
        let bedHeight = CGFloat(lengthFeet) * scale
        return Fit(
            scale: scale,
            originX: inset + (drawableWidth - bedWidth) / 2,
            originY: inset + (drawableHeight - bedHeight) / 2,
            bedWidth: bedWidth,
            bedHeight: bedHeight
        )
    }

    /// A placement's screen center, without any live drag offset. Bed y grows up, so
    /// screenY = originY + (lengthFeet - y) * scale.
    private func center(of p: Placement, in fit: Fit) -> CGPoint {
        CGPoint(
            x: fit.originX + CGFloat(p.x) * fit.scale,
            y: fit.originY + CGFloat(lengthFeet - p.y) * fit.scale
        )
    }

    /// The ids of the draggable dots whose hit area can grow to `hitSize` without reaching another dot.
    private func enlargedIDs(centers: [CGPoint]) -> Set<String> {
        guard onMove != nil else { return [] }
        let indices = placements.indices.filter { index in
            BedPlacementMath.canEnlargeHitArea(
                at: index,
                centers: centers,
                dotDiameter: dotSize,
                hitDiameter: hitSize
            )
        }
        return Set(indices.map { placements[$0].id })
    }

    /// Pick a canvas height that gives the bed reasonable presence.
    private var canvasHeight: CGFloat {
        guard widthFeet > 0, lengthFeet > 0 else { return 120 }
        // Roughly cap at 280 for tall (length > width) beds; 200 for
        // square/wide. Tweakable; the canvas auto-fits anyway.
        return lengthFeet > widthFeet ? 280 : 200
    }
}

/// Label frames by placement id, in the bed canvas's coordinate space.
private struct BedLabelFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
