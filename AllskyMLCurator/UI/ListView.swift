import AppKit
import SwiftUI

/// Compact table view of the same filtered image set the matrix
/// shows. Trades the thumbnail grid for a scannable list with
/// filename, capture time, camera, rating, and ingest timestamp —
/// the right view mode for triage tasks ("which of these 200 files
/// shouldn't be here?") where a visual grid is less useful than a
/// name + date you can skim.
///
/// The selection model is identical to `MatrixView` (stable anchor,
/// cursor tracked by ID) so `selectedIds` round-trips cleanly between
/// the two views. Removal works the same way: Delete / ⌘⌫ prompts
/// the same confirmation dialog that `MatrixView` uses, and the
/// rating / flag keys are all wired.
struct ListView: View {

    // MARK: - Inputs

    let items: [ImageLibrary.ImageListItem]
    let nightMode: Bool
    let predictions: [Int64: ClassifierEngine.Prediction]
    let onSelectionChange: (Set<Int64>) -> Void
    let onMutation: () async -> Void
    let onInspect: (Int) -> Void

    // MARK: - State

    @State private var selectedIds: Set<Int64> = []
    @State private var cursorId: Int64?
    @State private var anchorId: Int64?
    @FocusState private var isFocused: Bool
    @State private var deletePrompt: DeletePrompt?

    struct DeletePrompt: Identifiable {
        let id = UUID()
        let ids: [Int64]
        var count: Int { ids.count }
    }

    private var cursorIndex: Int {
        guard let cursorId,
              let idx = items.firstIndex(where: { $0.id == cursorId })
        else { return 0 }
        return idx
    }

    private var anchorIndex: Int {
        guard let anchorId,
              let idx = items.firstIndex(where: { $0.id == anchorId })
        else { return cursorIndex }
        return idx
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(for: item, index: index)
                                .id(item.id)
                                .onTapGesture {
                                    handleClick(item: item, index: index)
                                }
                        }
                    }
                }
            }
            .background(AppColors.bg(nightMode))
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
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Rating").frame(width: 64, alignment: .leading)
            Text("Filename").frame(width: 260, alignment: .leading)
            Text("Camera").frame(width: 90, alignment: .leading)
            Text("Captured (UTC)").frame(width: 180, alignment: .leading)
            Text("Added")         .frame(width: 180, alignment: .leading)
            Text("Predicted").frame(width: 120, alignment: .leading)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppColors.fgDim(nightMode))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.bgToolbar(nightMode))
    }

    // MARK: - Row

    private func row(
        for item: ImageLibrary.ImageListItem, index: Int
    ) -> some View {
        let isSelected = selectedIds.contains(item.id)
        let isCursor = item.id == cursorId
        let ratingClass = item.label?.ratingClass ?? .unrated
        let prediction = predictions[item.id]
        return HStack(spacing: 8) {
            ratingChip(ratingClass).frame(width: 64, alignment: .leading)
            Text(filenameOnly(item.image.filePath))
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(AppColors.fg(nightMode))
                .frame(width: 260, alignment: .leading)
            Text(cameraLabel(item.image.cameraSource))
                .font(.caption.monospaced())
                .foregroundStyle(AppColors.fgDim(nightMode))
                .frame(width: 90, alignment: .leading)
            Text(Self.dateFormatter.string(from: item.image.captureUtc))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppColors.fgDim(nightMode))
                .frame(width: 180, alignment: .leading)
            Text(Self.dateFormatter.string(from: item.image.createdAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppColors.fgVeryDim(nightMode))
                .frame(width: 180, alignment: .leading)
            predictionCell(prediction)
                .frame(width: 120, alignment: .leading)
            flagCell(item.label)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? AppColors.selection(nightMode).opacity(0.25)
                : Color.clear
        )
        .overlay(
            isCursor
                ? Rectangle()
                    .stroke(AppColors.selection(nightMode), lineWidth: 2)
                : nil
        )
    }

    private func ratingChip(_ cls: RatingClass) -> some View {
        Group {
            if cls == .unrated {
                Text("—")
                    .font(.caption.monospaced())
                    .foregroundStyle(AppColors.fgVeryDim(nightMode))
            } else {
                HStack(spacing: 1) {
                    ForEach(0..<cls.rawValue, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppColors.tier(cls, night: nightMode))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func predictionCell(
        _ prediction: ClassifierEngine.Prediction?
    ) -> some View {
        if let prediction {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption2.weight(.bold))
                Text("\(prediction.topClass.rawValue)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(String(format: "(%.0f%%)", prediction.topProbability * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppColors.fgDim(nightMode))
            }
            .foregroundStyle(AppColors.tier(prediction.topClass, night: nightMode))
        } else {
            Text("—")
                .font(.caption.monospaced())
                .foregroundStyle(AppColors.fgVeryDim(nightMode))
        }
    }

    @ViewBuilder
    private func flagCell(_ label: LabelRecord?) -> some View {
        HStack(spacing: 4) {
            if label?.reflectionFlag == true {
                Text("R")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(AppColors.reflectionFlag(nightMode))
                    .clipShape(Capsule())
            }
            if label?.transitionalFlag == true {
                Text("T")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(AppColors.transitionalFlag(nightMode))
                    .clipShape(Capsule())
            }
        }
    }

    private func filenameOnly(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func cameraLabel(_ source: ImageRecord.CameraSource) -> String {
        switch source {
        case .colorAllskyJpg: return "color"
        case .monoAllskyJpg:  return "mono jpg"
        case .monoAllskyFits: return "mono fits"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Selection (same model as MatrixView)

    private func handleClick(
        item: ImageLibrary.ImageListItem, index: Int
    ) {
        isFocused = true
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selectedIds.contains(item.id) { selectedIds.remove(item.id) }
            else                             { selectedIds.insert(item.id) }
            cursorId = item.id
            anchorId = item.id
        } else if modifiers.contains(.shift) {
            cursorId = item.id
            selectedIds = linearRange(fromAnchor: anchorIndex, toCursor: index)
        } else {
            selectedIds = [item.id]
            cursorId = item.id
            anchorId = item.id
        }
        onSelectionChange(selectedIds)
    }

    /// Plain linear range between two indices — the list has no
    /// column structure, so Shift+arrow / Shift+click just picks
    /// everything between lo and hi inclusive.
    private func linearRange(
        fromAnchor anchor: Int, toCursor cursor: Int
    ) -> Set<Int64> {
        guard !items.isEmpty else { return [] }
        let clampedAnchor = max(0, min(items.count - 1, anchor))
        let clampedCursor = max(0, min(items.count - 1, cursor))
        let lo = min(clampedAnchor, clampedCursor)
        let hi = max(clampedAnchor, clampedCursor)
        return Set(items[lo...hi].map(\.id))
    }

    private func handleKey(
        _ press: KeyPress, proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let pageStep = 20

        switch press.key {
        case .upArrow:
            moveCursor(by: -1, extend: shift, proxy: proxy); return .handled
        case .downArrow:
            moveCursor(by: +1, extend: shift, proxy: proxy); return .handled
        case .pageUp:
            moveCursor(by: -pageStep, extend: shift, proxy: proxy); return .handled
        case .pageDown:
            moveCursor(by: +pageStep, extend: shift, proxy: proxy); return .handled
        case .home:
            moveCursor(to: 0,                extend: shift, proxy: proxy); return .handled
        case .end:
            moveCursor(to: items.count - 1,  extend: shift, proxy: proxy); return .handled
        default: break
        }

        if press.modifiers.contains(.command), press.characters == "a" {
            guard let first = items.first, let last = items.last else {
                return .handled
            }
            selectedIds = Set(items.map(\.id))
            anchorId = first.id
            cursorId = last.id
            onSelectionChange(selectedIds)
            return .handled
        }

        if press.key == .return {
            if items.indices.contains(cursorIndex) {
                onInspect(cursorIndex)
            }
            return .handled
        }

        if press.key == .delete || press.key == .deleteForward {
            if !selectedIds.isEmpty {
                deletePrompt = DeletePrompt(ids: Array(selectedIds))
                return .handled
            }
            return .ignored
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
        let targetId = items[newIndex].id
        cursorId = targetId
        if extend {
            selectedIds = linearRange(fromAnchor: anchorIndex, toCursor: newIndex)
        } else {
            selectedIds = [targetId]
        }
        onSelectionChange(selectedIds)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(targetId, anchor: .center)
        }
    }

    // MARK: - Reconciliation (same logic as MatrixView)

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

        if let aid = anchorId, liveIds.contains(aid) {
            // still live
        } else {
            anchorId = cursorId
        }

        // See MatrixView.reconcileSelectionState for the invariants.
        if selectedIds.isEmpty, let cid = cursorId {
            selectedIds = [cid]
        }

        onSelectionChange(selectedIds)
        if cursorId != previousCursorId, let cid = cursorId {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(cid, anchor: .center)
            }
        }
    }

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

    // MARK: - Actions

    private enum OrthogonalFlag { case reflection, transitional }

    private func applyRating(_ cls: RatingClass) {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        Task {
            await ImageLibrary.shared.setRating(cls, forImageIds: ids)
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

    private func confirmDelete(_ ids: [Int64]) {
        Task {
            _ = await ImageLibrary.shared.deleteImages(ids)
            await onMutation()
        }
    }
}
