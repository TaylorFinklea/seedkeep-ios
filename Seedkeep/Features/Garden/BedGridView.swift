import SwiftUI

/// A bed's square-foot grid. Each square is one button: tap, click, Space and Return all call
/// `onActivate`, and arrow keys move focus between squares on iPad and Mac. Rows are lazy, so focus
/// moves scroll the target row into view (building it) before focusing its square. The selected event's square
/// carries the Move left/right/up/down accessibility actions. Cells are at least 44pt and grow with
/// Dynamic Type without a cap; at accessibility sizes the date line is hidden and the events list
/// carries the full text.
struct BedGridView: View {
    let size: GridSize
    /// `GardenGrid.squares` for the bed. A missing square is empty.
    let squares: [GridSquare: SquareContents]
    let mode: GardenSession.Mode
    let selectedEventID: String?
    /// The brush seed's name, for the painting hint.
    let brushSeedName: String?
    /// The moving event's subject, for the moving hint.
    let movingSeedName: String?
    /// The event's seed name, or nil for a seedless event.
    let seedName: (GridEvent) -> String?
    let onActivate: (GridSquare) -> Void
    let onMoveSelected: (GardenInteraction.Direction) -> Void
    /// Set to a square to focus it (and scroll it into view), e.g. after details close or a delete.
    /// The grid sets it back to nil.
    @Binding var focusRequest: GridSquare?

    @FocusState private var focused: GridSquare?
    @AccessibilityFocusState private var accessibilityFocused: GridSquare?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledCell: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var spacing: CGFloat = 4

    private var cellSize: CGFloat { max(WBMetrics.touchTarget, scaledCell) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                // Lazy rows keep a 50 × 50 bed to the rows on screen; each row is scrolled to by its
                // index (`.id(row)`) before one of its squares is focused.
                LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(0..<size.rows, id: \.self) { row in
                        HStack(spacing: spacing) {
                            ForEach(0..<size.columns, id: \.self) { column in
                                cell(GridSquare(column: column, rowFromTop: row), proxy: proxy)
                            }
                        }
                        .id(row)
                    }
                }
                .padding(spacing)
            }
            .onChange(of: focused) { _, square in
                guard let square else { return }
                withAnimation { proxy.scrollTo(square, anchor: nil) }
            }
            // `initial`: a request set before this grid was built (its row recycled, or the grid
            // rebuilt behind a sheet) is honoured when it appears.
            .onChange(of: focusRequest, initial: true) { _, square in
                guard let square else { return }
                focusRequest = nil
                focus(square, proxy: proxy, accessibility: true)
            }
        }
        .accessibilityIdentifier("garden.grid")
    }

    private func cell(_ square: GridSquare, proxy: ScrollViewProxy) -> some View {
        let contents = squares[square] ?? .empty
        let holdsSelection = selectedEventID.map { id in contents.events.contains { $0.id == id } } ?? false
        return Button {
            onActivate(square)
        } label: {
            BedGridCell(
                contents: contents,
                seedName: seedName,
                isSelected: holdsSelection,
                showsDateLine: !dynamicTypeSize.isAccessibilitySize,
                side: cellSize
            )
        }
        .buttonStyle(.plain)
        .id(square)
        .focused($focused, equals: square)
        .accessibilityFocused($accessibilityFocused, equals: square)
        // Space isn't handled here: the focused Button already activates on Space (macOS keyboard
        // navigation, iPad Full Keyboard Access), and handling it too could activate twice. A Button
        // that isn't the default one doesn't take Return, so Return is handled here.
        .onKeyPress(keys: [.return]) { _ in
            onActivate(square)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            moveFocus(from: square, key: press.key, proxy: proxy)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GardenText.cellLabel(square: square, contents: contents, seedName: seedName))
        .accessibilityHint(GardenText.cellHint(
            mode: mode, contents: contents, brushSeedName: brushSeedName, movingSeedName: movingSeedName
        ) ?? "")
        .accessibilityAddTraits(holdsSelection ? [.isButton, .isSelected] : .isButton)
        .modifier(MoveActions(enabled: holdsSelection, onMove: onMoveSelected))
        .accessibilityIdentifier("garden.grid.r\(square.rowFromTop + 1).s\(square.column + 1)")
    }

    private func moveFocus(from square: GridSquare, key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        let direction: GardenInteraction.Direction
        switch key {
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        default: return .ignored
        }
        let next = direction.step(square)
        guard GardenGrid.contains(next, in: size) else { return .handled }
        focus(next, proxy: proxy, accessibility: false)
        return .handled
    }

    /// Focuses a square that may sit in a lazy row not built yet: scrolls its row into view first,
    /// then focuses (and scrolls to) the square on the next run-loop turn, once the row exists. A move
    /// within the focused row skips the row scroll, so the grid doesn't jump sideways.
    private func focus(_ square: GridSquare, proxy: ScrollViewProxy, accessibility: Bool) {
        if focused?.rowFromTop != square.rowFromTop { proxy.scrollTo(square.rowFromTop, anchor: nil) }
        Task { @MainActor in
            focused = square
            if accessibility { accessibilityFocused = square }
            proxy.scrollTo(square, anchor: nil)
        }
    }
}

/// The four accessibility Move actions, on the cell holding the selected event.
private struct MoveActions: ViewModifier {
    let enabled: Bool
    let onMove: (GardenInteraction.Direction) -> Void

    func body(content: Content) -> some View {
        content
            // Keep the action container attached in both states so selection doesn't replace the focused button.
            .accessibilityActions {
                if enabled {
                    Button(GardenInteraction.Direction.left.actionName) { onMove(.left) }
                    Button(GardenInteraction.Direction.right.actionName) { onMove(.right) }
                    Button(GardenInteraction.Direction.up.actionName) { onMove(.up) }
                    Button(GardenInteraction.Direction.down.actionName) { onMove(.down) }
                }
            }
    }
}

/// One square's face: the shown event's kind colour, an abbreviation, a "+N" badge and a date or
/// "done" line. Selected squares get an accent ring; frost-flagged ones a warn ring and a frost glyph,
/// so frost is never colour alone.
struct BedGridCell: View {
    let contents: SquareContents
    let seedName: (GridEvent) -> String?
    let isSelected: Bool
    let showsDateLine: Bool
    let side: CGFloat

    @ScaledMetric(relativeTo: .caption) private var glyphSize: CGFloat = 11

    static func background(for contents: SquareContents) -> Color {
        guard let shown = contents.shownEvent else { return WBColor.panel2 }
        if contents.isAllDone { return WBColor.kindNote }
        return kindColour(shown.kind)
    }

    static func kindColour(_ kind: String) -> Color {
        switch kind {
        case "sowing": return WBColor.kindSowing
        case "transplant": return WBColor.kindTransplant
        case "harvest": return WBColor.kindHarvest
        default: return WBColor.kindNote
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WBMetrics.radiusSmall)
        ZStack {
            shape.fill(Self.background(for: contents))
            if let shown = contents.shownEvent {
                VStack(spacing: 2) {
                    Text(GardenText.abbreviation(GardenText.subject(seedName: seedName(shown), kind: shown.kind)))
                        .font(.wbCallout.weight(.semibold))
                        .foregroundStyle(WBColor.ink)
                    if showsDateLine {
                        Text(shown.isCompleted ? "done" : GardenText.shortDay(shown.plannedFor))
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.muted)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(4)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .topTrailing) {
            if contents.events.count > 1 {
                Text("+\(contents.events.count - 1)")
                    .font(.wbCaption.weight(.semibold))
                    .foregroundStyle(WBColor.ink)
                    .padding(.horizontal, 4)
                    .background(WBColor.panel, in: Capsule())
                    .overlay(Capsule().strokeBorder(WBColor.line, lineWidth: 1))
                    .padding(2)
            }
        }
        .overlay(alignment: .topLeading) {
            if contents.isFrostFlagged {
                Image(systemName: "snowflake")
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(WBColor.warnInk)
                    .padding(3)
                    .background(WBColor.warn, in: Circle())
                    .padding(2)
            }
        }
        .overlay {
            if contents.isFrostFlagged {
                shape.inset(by: isSelected ? 3 : 0).strokeBorder(WBColor.warn, lineWidth: 2)
            }
        }
        .overlay {
            shape.strokeBorder(isSelected ? WBColor.accent : WBColor.line, lineWidth: isSelected ? 3 : 1)
        }
        .contentShape(shape)
    }
}

/// The bar shown while painting or moving, on every layout: what the mode does, a Details button while
/// painting, and Stop or Cancel.
struct GardenModeBar: View {
    let mode: GardenSession.Mode
    let brushSeedName: String?
    let movingSeedName: String?
    let hasSelection: Bool
    let onDetails: () -> Void
    let onStop: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch mode {
        case .idle:
            EmptyView()
        case .painting:
            bar(
                text: brushSeedName.map { "Painting with \($0)" } ?? "Painting",
                showsDetails: true,
                stopLabel: "Stop"
            )
        case .moving:
            bar(
                text: GardenText.moveBanner(seedName: movingSeedName ?? "this planting"),
                showsDetails: false,
                stopLabel: "Cancel"
            )
        }
    }

    private func bar(text: String, showsDetails: Bool, stopLabel: String) -> some View {
        let label = Text(text)
            .font(.wbCallout.weight(.semibold))
            .foregroundStyle(WBColor.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        return Group {
            // At accessibility sizes the text takes the full width and the buttons go below it, side by side
            // when they fit and stacked when they don't, so no word is split across lines.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: WBMetrics.gap) {
                    label
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: WBMetrics.gap) { buttons(showsDetails: showsDetails, stopLabel: stopLabel) }
                        VStack(alignment: .leading, spacing: WBMetrics.gap) {
                            buttons(showsDetails: showsDetails, stopLabel: stopLabel)
                        }
                    }
                }
            } else {
                HStack(spacing: WBMetrics.gap) {
                    label
                    buttons(showsDetails: showsDetails, stopLabel: stopLabel)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(WBColor.accentSoft, in: RoundedRectangle(cornerRadius: WBMetrics.radiusControl))
        .overlay(RoundedRectangle(cornerRadius: WBMetrics.radiusControl).strokeBorder(WBColor.line, lineWidth: 1))
    }

    @ViewBuilder
    private func buttons(showsDetails: Bool, stopLabel: String) -> some View {
        // The minimum frame and the hit shape sit inside each label, so the whole target grows.
        if showsDetails {
            Button(action: onDetails) {
                Text("Details")
                    .frame(minHeight: WBMetrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(!hasSelection)
            .accessibilityIdentifier("garden.modeBar.details")
        }
        Button(action: onStop) {
            Text(stopLabel)
                .foregroundStyle(WBColor.accentInk)
                .frame(minHeight: WBMetrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(WBColor.accent)
        .accessibilityIdentifier("garden.modeBar.stop")
    }
}
