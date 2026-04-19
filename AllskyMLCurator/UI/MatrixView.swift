import AppKit
import SwiftUI

/// The keyboard-first allsky rating matrix. Shows a large grid of
/// thumbnails, applies ratings via number keys, and navigates with
/// arrow keys.
///
/// # Selection model — what each action does, and what it doesn't
///
/// The model is "stable anchor, moving cursor":
///
///   - A **plain click** on a tile sets cursor = anchor = clicked;
///     the selection collapses to `{clicked}`.
///   - A **Cmd+click** toggles the clicked tile in the selection;
///     cursor = anchor = clicked (so a later Shift+arrow extends
///     from this fresh pick).
///   - A **Shift+click** keeps the anchor pinned and selects the
///     row-aligned range from anchor to clicked.
///   - A **plain arrow / page / home / end** moves the cursor and
///     collapses selection to `{cursor}`, but the anchor does
///     *not* move. That's the important part: the anchor is the
///     tile the user last deliberately picked, and keyboard nav
///     alone never reassigns it. You can page through the library
///     and Shift+arrow or Shift+click back to extend a range from
///     your original pick.
///   - **Shift+arrow / PageUp / PageDown / Home / End** extends
///     from the stable anchor to the new cursor using the
///     row-aligned rectangle (so Shift+Down fills whole rows).
///   - **Shift+Left / Shift+Right** is the exception: it mutates
///     the selection by exactly one tile (insert on move-away,
///     remove on move-back), so a multi-row block built with
///     Shift+Down survives horizontal trimming.
///   - **Cmd+A** selects everything, anchor ← first, cursor ← last.
///
/// # Cursor persistence across list changes
///
/// Cursor and anchor are kept as **item IDs**, not list indices.
/// When the underlying list changes — filter flip, a rated block
/// disappearing from "only unrated", a re-ingest — the cursor ID
/// survives; its new index is recomputed on the fly. If the cursor
/// tile was among the removed items, `reconcileSelectionState`
/// walks the OLD list for the nearest surviving neighbour (next
/// successor first, then predecessor), so the cursor lands on the
/// *next tile you were about to rate*, not "back at the top" or
/// "a kilometre up" as the index-based model used to do.
struct MatrixView: View {

    // MARK: - Inputs

    let items: [ImageLibrary.ImageListItem]
    let columns: Int
    let nightMode: Bool
    let predictions: [Int64: ClassifierEngine.Prediction]
    let onSelectionChange: (Set<Int64>) -> Void
    let onMutation: () async -> Void
    let onInspect: (Int) -> Void

    // MARK: - State

    @State private var selectedIds: Set<Int64> = []

    /// The tile the cursor is currently on. Tracked by ID so a list
    /// refresh doesn't leave the cursor pointing at the wrong tile.
    @State private var cursorId: Int64?

    /// The tile Shift+anything extends from. Stable: plain arrow /
    /// page / home / end leave this alone — only click / Cmd+click /
    /// Cmd+A / rating-landing-on-empty-list touch it.
    @State private var anchorId: Int64?

    @FocusState private var isFocused: Bool

    /// Confidence prefix (Q = quick / 1, C = certain / 3). Consumed
    /// exactly once by the next digit press; toggles off if the same
    /// prefix key is pressed twice.
    @State private var pendingConfidence: Int?

    /// Set by ⌘⌫ / Delete. Holds the IDs the user asked to remove
    /// plus their count, and drives the confirmation alert. `nil`
    /// means no deletion pending.
    @State private var deletePrompt: DeletePrompt?

    struct DeletePrompt: Identifiable {
        let id = UUID()
        let ids: [Int64]
        var count: Int { ids.count }
    }

    // MARK: - Derived indices

    private var cursorIndex: Int {
        guard let cursorId,
              let idx = items.firstIndex(where: { $0.id == cursorId })
        else { return 0 }
        return idx
    }

    /// Anchor index, falling back to cursor when the anchor item is
    /// missing (so a freshly reconciled view never has a dangling
    /// anchor pointing off into space).
    private var anchorIndex: Int {
        guard let anchorId,
              let idx = items.firstIndex(where: { $0.id == anchorId })
        else { return cursorIndex }
        return idx
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 80), spacing: 2),
              count: columns)
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            MatrixTileCell(
                                item: item,
                                isSelected: selectedIds.contains(item.id),
                                isCursor: item.id == cursorId,
                                prediction: predictions[item.id],
                                nightMode: nightMode
                            )
                            .id(item.id)
                            .onTapGesture {
                                handleClick(item: item, index: index)
                            }
                            .contextMenu {
                                contextMenu(for: item)
                            }
                        }
                    }
                    .padding(4)
                }

                if let pending = pendingConfidence {
                    confidenceHUD(pending)
                        .padding(12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear {
                isFocused = true
                if cursorId == nil, let first = items.first {
                    cursorId = first.id
                    anchorId = first.id
                    selectedIds = [first.id]
                    onSelectionChange(selectedIds)
                }
            }
            .onChange(of: items.map(\.id)) { oldIds, newIds in
                reconcileSelectionState(
                    oldIds: oldIds, newIds: newIds, proxy: proxy
                )
            }
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleKey(press, proxy: proxy)
            }
            .alert(item: $deletePrompt) { prompt in
                Alert(
                    title: Text("Remove \(prompt.count) image\(prompt.count == 1 ? "" : "s") from the library?"),
                    message: Text("The image index row, every label, every prediction, and the cached thumbnail + embedding sidecar will be deleted locally. Supabase rows stay — re-ingest would push them back. This cannot be undone locally without re-ingest."),
                    primaryButton: .destructive(Text("Remove")) {
                        confirmDelete(prompt.ids)
                    },
                    secondaryButton: .cancel()
                )
            }
            // ⌘⌫ comes through the Edit → Delete Selected menu
            // command registered at App.commands level; it posts
            // `.deleteSelectedImagesRequested` which we handle here.
            // Every selection-aware view listens, and whichever one
            // currently holds a non-empty selection is the one that
            // presents the confirm alert (the others early-return).
            .onReceive(NotificationCenter.default.publisher(
                for: .deleteSelectedImagesRequested
            )) { _ in
                requestDeleteSelection()
            }
        }
    }

    private func requestDeleteSelection() {
        guard !selectedIds.isEmpty else { return }
        deletePrompt = DeletePrompt(ids: Array(selectedIds))
    }

    /// Per-tile context menu. Right-clicking a tile that's **not**
    /// already in the selection shifts the selection onto it first,
    /// so "Delete 1 highlighted image" always reflects the tile the
    /// user actually clicked. Clicking inside an existing selection
    /// deletes the whole set.
    @ViewBuilder
    private func contextMenu(
        for item: ImageLibrary.ImageListItem
    ) -> some View {
        let effectiveIds = selectedIds.contains(item.id)
            ? selectedIds
            : [item.id]
        let count = effectiveIds.count
        Button("Delete \(count) highlighted image\(count == 1 ? "" : "s")",
               systemImage: "trash") {
            if !selectedIds.contains(item.id) {
                selectedIds = [item.id]
                cursorId = item.id
                anchorId = item.id
                onSelectionChange(selectedIds)
            }
            deletePrompt = DeletePrompt(ids: Array(effectiveIds))
        }
    }

    // MARK: - Deletion

    private func confirmDelete(_ ids: [Int64]) {
        Task {
            _ = await ImageLibrary.shared.deleteImages(ids)
            await onMutation()
        }
    }

    // MARK: - Reconciliation on list change

    /// Called whenever `items` changes: filter flip, rated block
    /// disappearing from the "only unrated" view, a fresh ingest.
    ///
    ///   1. Prune selection of any IDs the new list doesn't carry.
    ///   2. If the cursor item is still present, nothing to do — its
    ///      derived index resolves on the fly.
    ///   3. If the cursor item was removed, pick the nearest surviving
    ///      neighbour in the **old** list: first the next successor
    ///      (so rating a block of unrated frames lands the cursor on
    ///      the next unrated frame in capture order), then the
    ///      predecessor as a fallback.
    ///   4. Anchor: if its item was removed, collapse to cursor so
    ///      the next Shift+arrow extends from a live tile.
    ///   5. Scroll the cursor back into view — without this, SwiftUI
    ///      can leave the viewport wherever it was, which after a
    ///      big filter change looks like the whole list jumped.
    private func reconcileSelectionState(
        oldIds: [Int64], newIds: [Int64], proxy: ScrollViewProxy
    ) {
        guard !newIds.isEmpty else {
            selectedIds.removeAll()
            cursorId = nil
            anchorId = nil
            onSelectionChange(selectedIds)
            return
        }
        let liveIds = Set(newIds)
        selectedIds.formIntersection(liveIds)

        // Cursor: preserve by ID, else nearest survivor, else first.
        let previousCursorId = cursorId
        if let cid = cursorId, liveIds.contains(cid) {
            // still live
        } else if let cid = cursorId,
                  let replacement = Self.nearestSurvivor(
                    of: cid, in: oldIds, live: liveIds) {
            cursorId = replacement
        } else {
            cursorId = newIds.first
        }

        // Anchor: keep if live, else collapse to cursor.
        if let aid = anchorId, liveIds.contains(aid) {
            // still live
        } else {
            anchorId = cursorId
        }

        // Selection invariant: the cursor tile is always selected.
        // Without this, the very first items-populate (empty → list)
        // would leave the selection empty and the curator's first
        // digit press would rate nothing. Also protects against a
        // rating batch that strips out every previously-selected
        // tile — landing an empty set on the next tile would require
        // an extra click before keys work again.
        if selectedIds.isEmpty, let cid = cursorId {
            selectedIds = [cid]
        }

        onSelectionChange(selectedIds)

        // Snap the scroll view onto the cursor *only* when the cursor
        // actually moved. A full scroll reset on every items tick
        // used to fight the user's manual scrolling: they'd scroll a
        // few rows, a sync or coverage refresh would bump items'
        // array identity, and the viewport would snap back to the
        // cursor. Now the scroll only follows a deliberate cursor
        // change (list change that dropped the cursor tile, or an
        // initial populate).
        if cursorId != previousCursorId, let cid = cursorId {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(cid, anchor: .center)
            }
        }
    }

    /// Walk the OLD list from the stale ID outward — forward first
    /// (natural successor in capture order), then backward — looking
    /// for the nearest item that survived into the new list.
    private static func nearestSurvivor(
        of stale: Int64, in oldIds: [Int64], live: Set<Int64>
    ) -> Int64? {
        guard let idx = oldIds.firstIndex(of: stale) else { return nil }
        if idx + 1 < oldIds.count {
            for i in (idx + 1)..<oldIds.count where live.contains(oldIds[i]) {
                return oldIds[i]
            }
        }
        if idx > 0 {
            for i in stride(from: idx - 1, through: 0, by: -1)
            where live.contains(oldIds[i]) {
                return oldIds[i]
            }
        }
        return nil
    }

    // MARK: - Click handling

    private func handleClick(item: ImageLibrary.ImageListItem, index: Int) {
        isFocused = true
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            // Individual toggle. Anchor + cursor land on clicked so
            // the next Shift+arrow extends from here.
            if selectedIds.contains(item.id) { selectedIds.remove(item.id) }
            else                             { selectedIds.insert(item.id) }
            cursorId = item.id
            anchorId = item.id
        } else if modifiers.contains(.shift) {
            // Extend from the anchor to the clicked tile. Anchor stays
            // put; cursor lands on the clicked tile.
            cursorId = item.id
            selectedIds = rowAlignedSelection(
                fromAnchor: anchorIndex, toCursor: index
            )
        } else {
            // Plain click — single-tile selection, anchor = cursor.
            selectedIds = [item.id]
            cursorId = item.id
            anchorId = item.id
        }
        onSelectionChange(selectedIds)
    }

    /// Row-aligned rectangle between two indices. Single-row ranges
    /// are contiguous (just the tiles between lo and hi). Multi-row
    /// ranges fill every intermediate row from column 0 to the last
    /// column, so Shift+Down selects a full horizontal strip rather
    /// than a diagonal sliver the column-major arithmetic would
    /// otherwise produce.
    private func rowAlignedSelection(
        fromAnchor anchor: Int, toCursor cursor: Int
    ) -> Set<Int64> {
        guard !items.isEmpty else { return [] }
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

        if press.key == .escape, pendingConfidence != nil {
            withAnimation(.easeInOut(duration: 0.12)) {
                pendingConfidence = nil
            }
            return .handled
        }

        switch press.key {
        case .leftArrow:
            if shift { shiftHorizontalStep(-1, proxy: proxy) }
            else     { moveCursor(by: -1, extend: false, proxy: proxy) }
            return .handled
        case .rightArrow:
            if shift { shiftHorizontalStep(+1, proxy: proxy) }
            else     { moveCursor(by: +1, extend: false, proxy: proxy) }
            return .handled
        case .upArrow:
            moveCursor(by: -columns,   extend: shift, proxy: proxy)
            return .handled
        case .downArrow:
            moveCursor(by: +columns,   extend: shift, proxy: proxy)
            return .handled
        case .pageUp:
            moveCursor(by: -pageStep,  extend: shift, proxy: proxy)
            return .handled
        case .pageDown:
            moveCursor(by: +pageStep,  extend: shift, proxy: proxy)
            return .handled
        case .home:
            moveCursor(to: 0,                extend: shift, proxy: proxy)
            return .handled
        case .end:
            moveCursor(to: items.count - 1,  extend: shift, proxy: proxy)
            return .handled
        default: break
        }

        if press.modifiers.contains(.command) {
            switch press.characters {
            case "a":
                guard let first = items.first, let last = items.last else {
                    return .handled
                }
                selectedIds = Set(items.map(\.id))
                anchorId = first.id
                cursorId = last.id
                onSelectionChange(selectedIds)
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .center)
                }
                return .handled
            default: break
            }
        }

        // ⌘⌫ (Cmd+Backspace) — the macOS idiom for "delete the
        // selected items". Confirms via alert; no silent destructive
        // action. Also accepts bare ⌫ so a curator with muscle memory
        // from Finder / Mail doesn't have to learn a different
        // combo. A selection is required — we don't delete a single
        // cursor tile that isn't selected.
        if press.key == .delete || press.key == .deleteForward {
            if !selectedIds.isEmpty {
                deletePrompt = DeletePrompt(ids: Array(selectedIds))
                return .handled
            }
            return .ignored
        }

        if press.key == .return {
            if items.indices.contains(cursorIndex) {
                onInspect(cursorIndex)
            }
            return .handled
        }

        switch press.characters {
        case "0": applyRatingConsumingPending(.unrated);   return .handled
        case "1": applyRatingConsumingPending(.fullCloud); return .handled
        case "2": applyRatingConsumingPending(.mostly);    return .handled
        case "3": applyRatingConsumingPending(.some);      return .handled
        case "4": applyRatingConsumingPending(.thin);      return .handled
        case "5": applyRatingConsumingPending(.clear);     return .handled
        case "r", "R": toggleFlag(.reflection);   return .handled
        case "t", "T": toggleFlag(.transitional); return .handled
        case "q", "Q":
            withAnimation(.easeInOut(duration: 0.12)) {
                pendingConfidence = (pendingConfidence == 1) ? nil : 1
            }
            return .handled
        case "c", "C":
            withAnimation(.easeInOut(duration: 0.12)) {
                pendingConfidence = (pendingConfidence == 3) ? nil : 3
            }
            return .handled
        default: return .ignored
        }
    }

    private func applyRatingConsumingPending(_ cls: RatingClass) {
        let confidence = pendingConfidence
        if pendingConfidence != nil {
            withAnimation(.easeInOut(duration: 0.12)) {
                pendingConfidence = nil
            }
        }
        applyRating(cls, confidence: confidence)
    }

    // MARK: - Cursor movement

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
        let targetId = items[newIndex].id
        cursorId = targetId
        if extend {
            // Shift+nav: extend selection from the stable anchor
            // through the new cursor.
            selectedIds = rowAlignedSelection(
                fromAnchor: anchorIndex, toCursor: newIndex
            )
        } else {
            // Plain nav: cursor moves, selection collapses to the
            // cursor tile. Anchor does NOT move — that's what lets
            // the user page through the library and Shift+click or
            // Shift+arrow back to the original pick.
            selectedIds = [targetId]
        }
        onSelectionChange(selectedIds)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(targetId, anchor: .center)
        }
    }

    /// Surgical ±1 cell modification for Shift+Left / Shift+Right.
    /// Does **not** use the row-aligned rectangle — a multi-row
    /// block built with Shift+Down should survive horizontal trims.
    private func shiftHorizontalStep(
        _ delta: Int, proxy: ScrollViewProxy
    ) {
        guard !items.isEmpty else { return }
        let oldIndex = cursorIndex
        let newIndex = max(0, min(items.count - 1, oldIndex + delta))
        guard newIndex != oldIndex else { return }

        let anchorIdx = anchorIndex
        let oldDistance = abs(oldIndex - anchorIdx)
        let newDistance = abs(newIndex - anchorIdx)

        if newDistance > oldDistance {
            // Moving farther from the anchor — extend onto the new
            // cell. Set.insert is a no-op when the cell was already
            // in a row-aligned block, which is the exact case the
            // next shrink-step guard handles below.
            selectedIds.insert(items[newIndex].id)
        } else if newDistance < oldDistance {
            // Moving back toward the anchor. Only remove the cell
            // we're leaving (oldIndex) when it's at the *far edge*
            // of the current selection — i.e., no cell further from
            // the anchor is also selected. Otherwise the cursor was
            // navigating inside an existing row-aligned block
            // (Shift+Down built a multi-row rectangle, now
            // Shift+Left steps back inside it), and removing
            // oldIndex would silently drill holes in the block.
            let direction = oldIndex >= anchorIdx ? 1 : -1
            let beyondIdx = oldIndex + direction
            let beyondIsSelected = items.indices.contains(beyondIdx)
                && selectedIds.contains(items[beyondIdx].id)
            if !beyondIsSelected {
                selectedIds.remove(items[oldIndex].id)
            }
        } else {
            // Distances equal can only happen with a single step
            // across the anchor (oldIndex and newIndex on opposite
            // sides). Swap the two.
            selectedIds.remove(items[oldIndex].id)
            selectedIds.insert(items[newIndex].id)
        }

        cursorId = items[newIndex].id
        onSelectionChange(selectedIds)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(items[newIndex].id, anchor: .center)
        }
    }

    // MARK: - Rating writes

    private enum OrthogonalFlag { case reflection, transitional }

    private func applyRating(
        _ ratingClass: RatingClass, confidence: Int? = nil
    ) {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        Task {
            await ImageLibrary.shared.setRating(
                ratingClass, forImageIds: ids, confidence: confidence
            )
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

    // MARK: - HUD

    private func confidenceHUD(_ confidence: Int) -> some View {
        let label = confidence == 1 ? "quick" : "certain"
        let tint: Color = confidence == 1 ? .orange : .green
        return HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text("Next digit: \(label)")
                .font(.caption.weight(.semibold))
            Text("(Esc to cancel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(AppColors.bgToolbar(nightMode)))
        .overlay(Capsule().stroke(tint.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}
