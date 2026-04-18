import AppKit
import SwiftUI

/// The keyboard-first allsky rating matrix. Shows a large grid of
/// thumbnails, applies ratings via number keys, and navigates with
/// arrow keys. The single-image inspection view is a later phase;
/// this phase gets the curator from ingest to a usable rating flow.
///
/// Designed for Mac Studio throughput — a day of frames is ~1400
/// tiles; `LazyVGrid` keeps memory stable by rendering only the
/// visible rows.
struct MatrixView: View {

    // MARK: - Inputs

    let items: [ImageLibrary.ImageListItem]
    let columns: Int
    let nightMode: Bool
    /// Classifier predictions keyed by imageId — forwarded per tile
    /// so a sweep over this dictionary is O(1) per row.
    let predictions: [Int64: ClassifierEngine.Prediction]

    /// Called when the selection changes. Exposed so the outer
    /// ContentView can render a status bar showing "X of Y selected".
    let onSelectionChange: (Set<Int64>) -> Void

    /// Called after a rating or flag write completes so the caller
    /// can refresh the image list.
    let onMutation: () async -> Void

    // MARK: - State

    @State private var selectedIds: Set<Int64> = []
    @State private var cursorIndex: Int = 0
    /// Stable anchor for Shift-based range selection. Only touched by
    /// plain (no-modifier) clicks, so the user can keyboard-navigate
    /// freely and still shift-click back to the anchor's position
    /// later. Standard macOS text/table selection model.
    @State private var selectionAnchor: Int = 0
    @FocusState private var isFocused: Bool

    private var gridColumns: [GridItem] {
        // Tight spacing so adjacent same-rating tiles visually merge
        // their colored bands into a continuous bar.
        Array(
            repeating: GridItem(.flexible(minimum: 80), spacing: 2),
            count: columns
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        MatrixTileCell(
                            item: item,
                            isSelected: selectedIds.contains(item.id),
                            isCursor: index == cursorIndex,
                            prediction: predictions[item.id],
                            nightMode: nightMode
                        )
                        .id(item.id)
                        .onTapGesture {
                            handleClick(item: item, index: index)
                        }
                    }
                }
                .padding(4)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear {
                isFocused = true
                if selectedIds.isEmpty, let first = items.first {
                    selectedIds = [first.id]
                    cursorIndex = 0
                    selectionAnchor = 0
                    onSelectionChange(selectedIds)
                }
            }
            .onChange(of: items.map(\.id)) { _, _ in
                pruneStaleSelection()
            }
            .onKeyPress(phases: [.down, .repeat]) { press in
                // Including .repeat makes arrow keys + page keys
                // auto-advance while held down, matching the usual
                // macOS scrolling behaviour.
                handleKey(press, proxy: proxy)
            }
        }
    }

    // MARK: - Selection handling

    private func handleClick(item: ImageLibrary.ImageListItem, index: Int) {
        isFocused = true
        cursorIndex = index
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            // Toggle individual tile; anchor moves to the clicked
            // tile so the next shift-click/arrow extends from here.
            if selectedIds.contains(item.id) { selectedIds.remove(item.id) }
            else                             { selectedIds.insert(item.id) }
            selectionAnchor = index
        } else if modifiers.contains(.shift) {
            // Extend from the stable anchor to the clicked tile,
            // using the row-aligned rectangle so multi-row ranges
            // come out as horizontal strips instead of a diagonal.
            selectedIds = rowAlignedSelection(
                fromAnchor: selectionAnchor, toCursor: index
            )
        } else {
            // Plain click — move both anchor and cursor here, single
            // tile in the selection.
            selectedIds = [item.id]
            selectionAnchor = index
        }
        onSelectionChange(selectedIds)
    }

    private func pruneStaleSelection() {
        let liveIds = Set(items.map(\.id))
        selectedIds.formIntersection(liveIds)
        if cursorIndex >= items.count { cursorIndex = max(0, items.count - 1) }
        if selectionAnchor >= items.count { selectionAnchor = max(0, items.count - 1) }
        onSelectionChange(selectedIds)
    }

    /// Row-aligned rectangle between two indices. Single-row ranges
    /// are contiguous (just tiles between lo and hi). Multi-row
    /// ranges fill every intermediate row from column 0 to the last
    /// column, so Shift+Down selects a full horizontal strip rather
    /// than a diagonal sliver the column-major arithmetic would
    /// otherwise produce.
    private func rowAlignedSelection(
        fromAnchor anchor: Int, toCursor cursor: Int
    ) -> Set<Int64> {
        let clampedAnchor = max(0, min(items.count - 1, anchor))
        let clampedCursor = max(0, min(items.count - 1, cursor))
        let lo = min(clampedAnchor, clampedCursor)
        let hi = max(clampedAnchor, clampedCursor)
        let loRow = lo / columns
        let hiRow = hi / columns
        if loRow == hiRow {
            return Set(items[lo...hi].map(\.id))
        }
        let start = loRow * columns
        let end = min(items.count - 1, (hiRow + 1) * columns - 1)
        return Set(items[start...end].map(\.id))
    }

    // MARK: - Keyboard

    private func handleKey(
        _ press: KeyPress, proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        // A "page" is roughly five rows at the current column count —
        // close enough to one screen at typical window sizes without
        // measuring the scroll view.
        let pageStep = max(columns, columns * 5)

        switch press.key {
        case .leftArrow:
            // Shift+Left/Right mutate the selection by exactly one tile
            // (add or remove depending on whether we're moving away from
            // or back toward the anchor). The row-aligned rectangle
            // model is intentionally *not* used here — otherwise
            // pressing Shift+Left after Shift+Down would snap the
            // whole multi-row block back to a single row, surprising
            // the user who only wanted to trim one cell.
            if shift { shiftHorizontalStep(-1, proxy: proxy) }
            else     { moveCursor(by: -1, extend: false, proxy: proxy) }
            return .handled
        case .rightArrow:
            if shift { shiftHorizontalStep(+1, proxy: proxy) }
            else     { moveCursor(by: +1, extend: false, proxy: proxy) }
            return .handled
        case .upArrow:     moveCursor(by: -columns,   extend: shift, proxy: proxy); return .handled
        case .downArrow:   moveCursor(by: +columns,   extend: shift, proxy: proxy); return .handled
        case .pageUp:      moveCursor(by: -pageStep,  extend: shift, proxy: proxy); return .handled
        case .pageDown:    moveCursor(by: +pageStep,  extend: shift, proxy: proxy); return .handled
        case .home:        moveCursor(to: 0,                extend: shift, proxy: proxy); return .handled
        case .end:         moveCursor(to: items.count - 1,  extend: shift, proxy: proxy); return .handled
        default: break
        }

        if press.modifiers.contains(.command) {
            switch press.characters {
            case "a":
                selectedIds = Set(items.map(\.id))
                // Anchor the "select all" to position 0 so the next
                // shift-action collapses predictably.
                selectionAnchor = 0
                cursorIndex = items.isEmpty ? 0 : items.count - 1
                onSelectionChange(selectedIds)
                return .handled
            default: return .ignored
            }
        }

        switch press.characters {
        case "0": applyRating(.unrated);   return .handled
        case "1": applyRating(.fullCloud); return .handled
        case "2": applyRating(.mostly);    return .handled
        case "3": applyRating(.some);      return .handled
        case "4": applyRating(.thin);      return .handled
        case "5": applyRating(.clear);     return .handled
        case "r", "R": toggleFlag(.reflection);   return .handled
        case "t", "T": toggleFlag(.transitional); return .handled
        default: return .ignored
        }
    }

    private func moveCursor(
        by delta: Int, extend: Bool, proxy: ScrollViewProxy
    ) {
        guard !items.isEmpty else { return }
        moveCursor(to: cursorIndex + delta, extend: extend, proxy: proxy)
    }

    private func moveCursor(
        to targetIndex: Int, extend: Bool, proxy: ScrollViewProxy
    ) {
        guard !items.isEmpty else { return }
        let newIndex = max(0, min(items.count - 1, targetIndex))
        cursorIndex = newIndex
        let targetId = items[newIndex].id
        if extend {
            // Shift+navigation — extend from the anchor to the new
            // cursor. Anchor stays where it is so repeated Shift+arrow
            // presses grow/shrink the same block.
            selectedIds = rowAlignedSelection(
                fromAnchor: selectionAnchor, toCursor: newIndex
            )
        } else {
            // Plain navigation — collapse to a single tile AND move
            // the anchor with the cursor (classical Finder / Excel
            // behaviour). Without this the anchor goes stale and the
            // next Shift+arrow extends from the wrong origin.
            selectedIds = [targetId]
            selectionAnchor = newIndex
        }
        onSelectionChange(selectedIds)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(targetId, anchor: .center)
        }
    }

    /// Surgical ±1 cell modification for Shift+Left/Right. Independent
    /// of any row-aligned rectangle: when the cursor moves away from
    /// the anchor we insert the new cell; when it moves back toward
    /// the anchor we remove the cell we just left. This lets the user
    /// build a multi-row block with Shift+Down and then trim/extend a
    /// single tile at a time horizontally without collapsing the rest
    /// of the selection.
    private func shiftHorizontalStep(
        _ delta: Int, proxy: ScrollViewProxy
    ) {
        guard !items.isEmpty else { return }
        let oldIndex = cursorIndex
        let newIndex = max(0, min(items.count - 1, oldIndex + delta))
        guard newIndex != oldIndex else { return }

        let clampedAnchor = max(0, min(items.count - 1, selectionAnchor))
        let oldDistance = abs(oldIndex - clampedAnchor)
        let newDistance = abs(newIndex - clampedAnchor)

        if newDistance > oldDistance {
            // Moving farther from the anchor — extend the selection
            // onto the new cell.
            selectedIds.insert(items[newIndex].id)
        } else if newDistance < oldDistance {
            // Moving back toward the anchor — release the cell we're
            // leaving. The new cursor cell stays selected because it
            // was already covered by the prior row-aligned block.
            selectedIds.remove(items[oldIndex].id)
        } else {
            // Crossed the anchor with a single step (only possible at
            // |oldIndex - anchor| == 0 boundary). Swap the two.
            selectedIds.remove(items[oldIndex].id)
            selectedIds.insert(items[newIndex].id)
        }

        cursorIndex = newIndex
        onSelectionChange(selectedIds)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(items[newIndex].id, anchor: .center)
        }
    }

    // MARK: - Actions

    private enum OrthogonalFlag { case reflection, transitional }

    private func applyRating(_ ratingClass: RatingClass) {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        Task {
            await ImageLibrary.shared.setRating(ratingClass, forImageIds: ids)
            await onMutation()
        }
    }

    private func toggleFlag(_ flag: OrthogonalFlag) {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        Task {
            switch flag {
            case .reflection:   await ImageLibrary.shared.toggleReflection(forImageIds: ids)
            case .transitional: await ImageLibrary.shared.toggleTransitional(forImageIds: ids)
            }
            await onMutation()
        }
    }
}
