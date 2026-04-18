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

    /// Called when the selection changes. Exposed so the outer
    /// ContentView can render a status bar showing "X of Y selected".
    let onSelectionChange: (Set<Int64>) -> Void

    /// Called after a rating or flag write completes so the caller
    /// can refresh the image list.
    let onMutation: () async -> Void

    // MARK: - State

    @State private var selectedIds: Set<Int64> = []
    @State private var cursorIndex: Int = 0
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
                    onSelectionChange(selectedIds)
                }
            }
            .onChange(of: items.map(\.id)) { _, _ in
                pruneStaleSelection()
            }
            .onKeyPress(phases: .down) { press in
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
            if selectedIds.contains(item.id) { selectedIds.remove(item.id) }
            else                             { selectedIds.insert(item.id) }
        } else if modifiers.contains(.shift),
                  let anchor = selectedIds.first,
                  let anchorIndex = items.firstIndex(where: { $0.id == anchor }) {
            let range = min(anchorIndex, index)...max(anchorIndex, index)
            selectedIds.formUnion(items[range].map(\.id))
        } else {
            selectedIds = [item.id]
        }
        onSelectionChange(selectedIds)
    }

    private func pruneStaleSelection() {
        let liveIds = Set(items.map(\.id))
        selectedIds.formIntersection(liveIds)
        if cursorIndex >= items.count { cursorIndex = max(0, items.count - 1) }
        onSelectionChange(selectedIds)
    }

    // MARK: - Keyboard

    private func handleKey(
        _ press: KeyPress, proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:       moveCursor(by: -1, extend: press.modifiers.contains(.shift), proxy: proxy); return .handled
        case .rightArrow:      moveCursor(by: +1, extend: press.modifiers.contains(.shift), proxy: proxy); return .handled
        case .upArrow:         moveCursor(by: -columns, extend: press.modifiers.contains(.shift), proxy: proxy); return .handled
        case .downArrow:       moveCursor(by: +columns, extend: press.modifiers.contains(.shift), proxy: proxy); return .handled
        default: break
        }

        if press.modifiers.contains(.command) {
            switch press.characters {
            case "a":
                selectedIds = Set(items.map(\.id))
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
        let newIndex = max(0, min(items.count - 1, cursorIndex + delta))
        cursorIndex = newIndex
        let targetId = items[newIndex].id
        if extend {
            selectedIds.insert(targetId)
        } else {
            selectedIds = [targetId]
        }
        onSelectionChange(selectedIds)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(targetId, anchor: .center)
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
