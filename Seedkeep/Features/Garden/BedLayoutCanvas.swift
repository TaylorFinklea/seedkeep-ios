import SwiftUI
import SeedkeepKit

/// Top-down view of a bed with placed planting events. Renders the bed
/// rectangle scaled to fit the available space (proportional to the bed's
/// width_feet × length_feet), then plots each event with x_feet/y_feet
/// set as a dot, with a faded ring around it whose radius is the plant's
/// required spacing pulled from the catalog (plant_spacing_inches / 2).
/// Overlapping rings give a visual cue that the layout is over-packed.
///
/// When `onMove` is provided, dots become draggable. Drag-end snaps the
/// new position to the nearest half-foot, clamps within bed bounds, and
/// fires the callback so the caller can persist via the sync engine.
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
    /// Optional drag-end handler. When non-nil, dots respond to pan
    /// gestures and report the new (x, y) in feet at drop-time.
    var onMove: ((_ id: String, _ newX: Double, _ newY: Double) -> Void)? = nil

    /// Onscreen padding so the bed doesn't kiss the canvas edges.
    private let inset: CGFloat = 16

    /// Live drag offset per dot, in screen points. Reset on drop.
    @State private var liveOffsets: [String: CGSize] = [:]

    var body: some View {
        GeometryReader { geo in
            let drawable = CGSize(
                width: geo.size.width - inset * 2,
                height: geo.size.height - inset * 2
            )
            // Fit the bed inside the drawable area preserving aspect.
            let scale: Double = {
                guard widthFeet > 0, lengthFeet > 0 else { return 0 }
                let sx = drawable.width / widthFeet
                let sy = drawable.height / lengthFeet
                return min(sx, sy)
            }()
            let bedW = widthFeet * scale
            let bedH = lengthFeet * scale
            let originX = inset + (drawable.width - bedW) / 2
            // Bed origin (0,0) is bottom-left in feet; SwiftUI canvas y
            // grows downward. So screen-y = origin + (length - y) * scale.
            let originY = inset + (drawable.height - bedH) / 2

            ZStack(alignment: .topLeading) {
                // Bed rectangle
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.brown.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.brown.opacity(0.07))
                    )
                    .frame(width: bedW, height: bedH)
                    .offset(x: originX - inset, y: originY - inset)
                    .padding(inset)

                // Footprint scale label in the corner.
                Text("\(Self.fmt(widthFeet))′ × \(Self.fmt(lengthFeet))′")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: .capsule)
                    .offset(x: originX, y: originY)

                // Each placement
                ForEach(placements) { p in
                    placementView(p,
                                   scale: scale,
                                   originX: originX,
                                   originY: originY,
                                   bedW: bedW,
                                   bedH: bedH)
                }
            }
        }
        .frame(height: canvasHeight)
        .background(Color(.systemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func placementView(
        _ p: Placement,
        scale: Double,
        originX: CGFloat,
        originY: CGFloat,
        bedW: CGFloat,
        bedH: CGFloat
    ) -> some View {
        let offset = liveOffsets[p.id] ?? .zero
        let cx = originX + p.x * scale + offset.width
        // Flip y so feet-origin (bottom-left) reads naturally.
        let cy = originY + (lengthFeet - p.y) * scale + offset.height
        let draggable = onMove != nil

        // Spacing ring (only if we have meaningful spacing).
        if p.spacingFeet > 0 {
            let diameter = max(8, p.spacingFeet * scale)
            Circle()
                .stroke(p.isSowing ? HerbColor.sepia.opacity(0.5) : Color.gray.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .background(
                    Circle().fill(p.isSowing ? HerbColor.sepia.opacity(0.12) : Color.gray.opacity(0.10))
                )
                .frame(width: diameter, height: diameter)
                .position(x: cx, y: cy)
                .allowsHitTesting(false)
        }

        // Dot itself — draggable when onMove is wired up.
        Circle()
            .fill(p.isSowing ? HerbColor.sepia : Color.gray)
            .frame(width: draggable ? 18 : 12, height: draggable ? 18 : 12)
            .shadow(color: .black.opacity(0.18), radius: draggable ? 2 : 0)
            .position(x: cx, y: cy)
            .gesture(draggable ? dragGesture(for: p, scale: scale,
                                              originX: originX, originY: originY,
                                              bedW: bedW, bedH: bedH) : nil)

        // Label below the dot — only render if there's room
        // so we don't overflow off the canvas.
        if !p.label.isEmpty, cy + 18 <= originY + bedH + inset {
            Text(p.label)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.thinMaterial, in: .capsule)
                .position(x: cx, y: cy + 16)
                .allowsHitTesting(false)
        }
    }

    private func dragGesture(
        for p: Placement,
        scale: Double,
        originX: CGFloat,
        originY: CGFloat,
        bedW: CGFloat,
        bedH: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                liveOffsets[p.id] = value.translation
            }
            .onEnded { value in
                liveOffsets[p.id] = .zero
                // Convert translation back to feet, apply, snap to half-foot,
                // clamp inside the bed.
                let dxFeet = value.translation.width / scale
                let dyFeet = value.translation.height / scale
                let candidateX = p.x + dxFeet
                // Y is flipped — moving down on-screen reduces y_feet.
                let candidateY = p.y - dyFeet
                let snappedX = snap(candidateX, max: widthFeet)
                let snappedY = snap(candidateY, max: lengthFeet)
                onMove?(p.id, snappedX, snappedY)
            }
    }

    /// Clamp to [0, max] and snap to 0.5-foot increments. The snap keeps
    /// the placements lining up on a half-foot grid, which feels natural
    /// for raised beds + matches the slider step in AddPlantingEventView.
    private func snap(_ value: Double, max: Double) -> Double {
        let clamped = min(Swift.max(0, value), max)
        return (clamped * 2).rounded() / 2
    }

    /// Pick a canvas height that gives the bed reasonable presence.
    private var canvasHeight: CGFloat {
        guard widthFeet > 0, lengthFeet > 0 else { return 120 }
        // Roughly cap at 280 for tall (length > width) beds; 200 for
        // square/wide. Tweakable; the canvas auto-fits anyway.
        return lengthFeet > widthFeet ? 280 : 200
    }

    private static func fmt(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }
}
