import AppKit
import SwiftUI

/// Full-window single-image inspection. Opens when the curator presses
/// Enter on a matrix tile — gives a close look at one frame with the
/// cropped sky disk at full display resolution and a metadata sidebar
/// that surfaces every ephemeris / sensor field on the `ImageRecord`
/// plus the classifier's full probability vector.
///
/// Keyboard:
///   - ←/→           navigate to the previous / next item in the same
///                   filtered list the matrix is showing
///   - 0–5           apply a class rating to the current frame
///   - R / T         toggle the reflection / transitional flag
///   - Esc / Return  dismiss back to the matrix
struct InspectionView: View {

    // MARK: - Inputs

    let items: [ImageLibrary.ImageListItem]
    @Binding var index: Int
    let prediction: ClassifierEngine.Prediction?
    let nightMode: Bool
    let onMutation: () async -> Void
    let onDismiss: () -> Void

    /// Confidence arm mirrored from the matrix: `q` / `c` prefixes the
    /// very next digit with a quick / certain confidence annotation.
    @State private var pendingConfidence: Int?

    /// Cloud-motion vector between the previous and current frames.
    /// Lazy: recomputed whenever the inspected index changes, cleared
    /// during the recompute so the UI flips to "calculating" rather
    /// than stale.
    @State private var motion: CloudMotionDetector.Motion?
    @State private var motionComputing: Bool = false

    /// Full-resolution decoded frame for the inspected tile. Kept in
    /// SwiftUI state + loaded via a detached task (`loadFullImage`)
    /// because the synchronous `NSImage(contentsOf:)` path on a
    /// sandboxed main-actor call silently fails on SMB mounts even
    /// when the BookmarkStore has granted access to the parent
    /// folder — thumbnails survive because `ThumbnailCache` already
    /// goes through `CGImageSourceCreateWithURL` on a detached task.
    /// We now mirror that pattern for the inspection view.
    @State private var fullImage: NSImage?
    @State private var fullImageFailed: Bool = false

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                leftMetadataPane
                    .frame(width: 320, height: geo.size.height)
                    .background(AppColors.bg(nightMode))

                Divider()

                imagePane
                    .frame(
                        width: max(480, geo.size.width - 320 - 340),
                        height: geo.size.height
                    )
                    .background(AppColors.bg(nightMode))

                Divider()

                rightRatingPane
                    .frame(width: 340, height: geo.size.height)
                    .background(AppColors.bg(nightMode))
            }
        }
        .frame(minWidth: 1320, minHeight: 780)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
        .task(id: index) {
            await recomputeMotion()
        }
        .task(id: index) {
            await loadFullImage()
        }
    }

    /// Robust async load using the same ImageIO path ThumbnailCache
    /// uses for thumbnails. `CGImageSourceCreateWithURL` + index 0
    /// → CGImage → NSImage goes through the sandbox-friendly read
    /// route that honours security-scoped bookmarks on SMB volumes.
    /// Main-actor-only state writes; decode happens on a detached
    /// worker so the UI doesn't stall on a 1-MB JPEG fetch from
    /// a slow mount.
    private func loadFullImage() async {
        fullImage = nil
        fullImageFailed = false
        guard let item = currentItem else {
            fullImageFailed = true
            return
        }
        let path = item.image.filePath
        let decoded: NSImage? = await Task.detached(priority: .userInitiated) {
            () -> NSImage? in
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return NSImage(
                cgImage: cg,
                size: NSSize(width: cg.width, height: cg.height)
            )
        }.value
        if let decoded {
            fullImage = decoded
        } else {
            fullImageFailed = true
        }
    }

    // MARK: - Panes

    /// Left pane: the actual JPEG loaded at full resolution. No
    /// zenith-mask is applied here — the curator is inspecting a
    /// specific frame and usually wants to see every detail, including
    /// the burned-in overlay text. The ML pipeline still sees the
    /// masked version elsewhere.
    private var imagePane: some View {
        Group {
            if let fullImage {
                Image(nsImage: fullImage)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else if fullImageFailed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(AppColors.fgDim(nightMode))
                    Text(currentItem?.image.filePath ?? "nothing selected")
                        .font(.caption)
                        .foregroundStyle(AppColors.fgDim(nightMode))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    if currentItem != nil {
                        Text("Couldn't decode the JPEG. Check that the volume is mounted and Preferences → Advanced → Grant folder access covers the parent directory.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.fgVeryDim(nightMode))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                }
                .padding()
            } else {
                // Loading state — small indeterminate spinner.
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

    /// Left pane (0.7.5): context metadata. Time + ephemeris +
    /// sensor + cloud motion. Fixed-width so the centre image pane
    /// can take the rest and the right pane shows the rating card.
    /// No ScrollView — blocks are compact enough to fit on any
    /// 780-pt-tall window without a scrollbar. Header here shows
    /// the index + close button.
    private var leftMetadataPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            timeBlock
            ephemerisBlock
            sensorBlock
            motionBlock
            Spacer()
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Right pane (0.7.5): the decision-makers. Big rating stars,
    /// label source / flags, classifier prediction bars, and a
    /// cheat-sheet for the keyboard commands. Keeps the curator's
    /// eye on the actual call-to-action (rate this frame) without
    /// scrolling past ephemeris metadata first.
    private var rightRatingPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            ratingHero
            Divider()
            predictionBlock
            Divider()
            keyHintBlock
            Spacer()
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Metadata blocks

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Inspection")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppColors.fg(nightMode))
                Text("\(index + 1) of \(items.count)")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var timeBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Time")
            if let item = currentItem {
                metaRow("Captured", Self.isoFormatter.string(from: item.image.captureUtc))
                metaRow("Time of day", item.image.timeOfDay.rawValue.replacingOccurrences(of: "_", with: " "))
                metaRow("Camera", item.image.cameraSource.rawValue)
            }
        }
    }

    private var ephemerisBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Ephemeris")
            if let item = currentItem {
                metaRow("Sun altitude", String(format: "%.2f°", item.image.sunAltDeg))
                metaRow("Sun azimuth", String(format: "%.1f°", item.image.sunAzDeg))
                metaRow("Moon altitude", String(format: "%.2f°", item.image.moonAltDeg))
                metaRow("Moon azimuth", String(format: "%.1f°", item.image.moonAzDeg))
                metaRow("Moon phase", String(format: "%.0f %%", item.image.moonPhase * 100))
                metaRow("Reflection risk", String(format: "%.2f", item.image.reflectionRiskScore))
                metaRow("Transitional risk", String(format: "%.2f", item.image.transitionalRiskScore))
            }
        }
    }

    private var sensorBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Sensor")
            if let item = currentItem {
                if let exp = item.image.exposureSec {
                    metaRow("Exposure", String(format: "%.2f s", exp))
                }
                if let gain = item.image.gain {
                    metaRow("Gain", String(format: "%.0f", gain))
                }
                if let tempC = item.image.sensorTempC {
                    metaRow("Sensor temp", String(format: "%.1f °C", tempC))
                }
                if let stable = item.image.aeStable {
                    metaRow("AE stable", stable ? "yes" : "no")
                }
                if item.image.exposureSec == nil,
                   item.image.gain == nil,
                   item.image.sensorTempC == nil,
                   item.image.aeStable == nil {
                    Text("no sensor sidecar metadata")
                        .font(.caption)
                        .foregroundStyle(AppColors.fgDim(nightMode))
                }
            }
        }
    }

    /// Cloud motion vs. the previous frame in the filtered list.
    /// Shown as an arrow indicating the direction clouds drifted
    /// between the two captures plus a text summary ("SW at 2.4 °/min").
    /// Stays silent when calibration is missing entirely, fallback to
    /// frame-local bearing when only the compass offset is absent.
    private var motionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Cloud motion")
            if motionComputing {
                Text("calculating…")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
            } else if let motion {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .rotationEffect(.degrees(motion.compassBearingDeg ?? motion.frameBearingDeg))
                        .foregroundStyle(AppColors.accent(nightMode))
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(motion.compassLabel) at \(String(format: "%.1f", motion.degreesPerMinute)) °/min")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppColors.fg(nightMode))
                        Text("over \(String(format: "%.0f", motion.secondsBetweenFrames)) s between frames")
                            .font(.caption)
                            .foregroundStyle(AppColors.fgDim(nightMode))
                    }
                }
            } else {
                Text("no previous frame in this filter — open a later tile to see motion.")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Big prominent rating card. 0.8.0 version shows the three
    /// colour-pill options (1 red unsuitable, 2 amber partial,
    /// 3 green suitable) with the current selection filled and the
    /// others outlined — mirrors the matrix-tile colour metaphor
    /// at a size that reads from across the room.
    private var ratingHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Rating")
            let currentCls: RatingClass = currentItem?.label?.ratingClass ?? .unrated
            HStack(spacing: 10) {
                ratingPill(.unsuitable, current: currentCls)
                ratingPill(.partial, current: currentCls)
                ratingPill(.suitable, current: currentCls)
            }
            if currentCls != .unrated {
                Text("\(currentCls.rawValue) — \(currentCls.shortName)  ·  \(currentCls.coverageHint)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppColors.tier(currentCls, night: nightMode))
                if let label = currentItem?.label {
                    metaRow("Source", label.source.rawValue)
                    metaRow("Sample weight", String(format: "%.2f", label.sampleWeight))
                    HStack(spacing: 8) {
                        if label.reflectionFlag {
                            flagChip("R", color: AppColors.reflectionFlag(nightMode))
                        }
                        if label.transitionalFlag {
                            flagChip("T", color: AppColors.transitionalFlag(nightMode))
                        }
                        if !label.reflectionFlag && !label.transitionalFlag {
                            Text("no flags")
                                .font(.caption)
                                .foregroundStyle(AppColors.fgDim(nightMode))
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                Text("UNRATED")
                    .font(.headline.weight(.black))
                    .foregroundStyle(AppColors.fgDim(nightMode))
                Text("Press 1 / 2 / 3 to rate this frame, R / T to flag, ←/→ to move to the next tile.")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One large pill in the rating hero. Filled + white digit when
    /// it matches the tile's current rating, tinted outline only
    /// otherwise so the unselected options read as clickable
    /// alternatives (even though they're actually keyboard-only).
    private func ratingPill(_ cls: RatingClass, current: RatingClass) -> some View {
        let isSelected = cls == current
        let tier = AppColors.tier(cls, night: nightMode)
        return Text("\(cls.rawValue)")
            .font(.system(size: 24, weight: .heavy, design: .rounded))
            .foregroundStyle(isSelected ? .white : tier)
            .frame(width: 52, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? tier : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(tier, lineWidth: isSelected ? 0 : 2)
            )
            .shadow(
                color: isSelected ? .black.opacity(0.3) : .clear,
                radius: 2, y: 1
            )
    }

    private func flagChip(_ symbol: String, color: Color) -> some View {
        Text(symbol)
            .font(.caption.weight(.black))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color)
            .clipShape(Capsule())
    }

    /// Compact keyboard cheat-sheet at the bottom of the right
    /// pane. Tells the curator "you don't have to close this sheet
    /// to rate and move on" — which is exactly the workflow the
    /// 0.7.5 redesign enables.
    private var keyHintBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Keyboard")
            VStack(alignment: .leading, spacing: 3) {
                keyLine("1 / 2 / 3", "Rate unsuitable / partial / suitable")
                keyLine("0", "Clear rating")
                keyLine("R", "Toggle reflection flag")
                keyLine("T", "Toggle transitional flag")
                keyLine("Q / C", "Arm quick / certain for next digit")
                keyLine("← / →", "Previous / next frame")
                keyLine("Esc", "Close inspection")
            }
        }
    }

    private func keyLine(_ keys: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(keys)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(AppColors.fg(nightMode))
                .frame(width: 56, alignment: .leading)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppColors.fgDim(nightMode))
        }
    }

    /// Classifier probabilities rendered as a horizontal bar chart —
    /// quickly tells the curator whether the top prediction is
    /// confident or the model is split between two neighbouring
    /// classes.
    private var predictionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Classifier prediction")
            if let prediction {
                ForEach(0..<3, id: \.self) { rawMinusOne in
                    let cls = RatingClass(rawValue: rawMinusOne + 1) ?? .unrated
                    let prob = prediction.probabilities.indices.contains(rawMinusOne)
                        ? prediction.probabilities[rawMinusOne]
                        : 0
                    let isTop = cls == prediction.topClass
                    HStack(spacing: 8) {
                        Text("\(cls.rawValue)")
                            .font(.body.monospacedDigit().weight(isTop ? .bold : .regular))
                            .frame(width: 16)
                            .foregroundStyle(AppColors.fg(nightMode))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(AppColors.fgDim(nightMode).opacity(0.15))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isTop ? AppColors.accent(nightMode) : AppColors.fgDim(nightMode))
                                    .frame(width: max(2, geo.size.width * CGFloat(prob)))
                            }
                        }
                        .frame(height: 12)
                        Text(String(format: "%.0f %%", prob * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.fgDim(nightMode))
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            } else {
                Text("no prediction — either the classifier isn't trained yet or this frame has no cached embedding.")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    private var currentItem: ImageLibrary.ImageListItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.fgDim(nightMode))
            .tracking(1.2)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.body)
                .foregroundStyle(AppColors.fgDim(nightMode))
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(AppColors.fg(nightMode))
                .textSelection(.enabled)
        }
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Esc while a confidence prefix is armed cancels the arm;
        // otherwise it closes the inspection sheet. Same ergonomic as
        // the matrix view.
        if press.key == .escape, pendingConfidence != nil {
            withAnimation(.easeInOut(duration: 0.12)) {
                pendingConfidence = nil
            }
            return .handled
        }

        switch press.key {
        case .leftArrow:
            if index > 0 { index -= 1 }
            return .handled
        case .rightArrow:
            if index < items.count - 1 { index += 1 }
            return .handled
        case .escape, .return:
            onDismiss()
            return .handled
        default: break
        }

        guard let item = currentItem, let id = item.image.id else {
            return .ignored
        }

        switch press.characters {
        case "0": applyRating(.unrated,    to: id);   return .handled
        case "1": applyRating(.unsuitable, to: id);   return .handled
        case "2": applyRating(.partial,    to: id);   return .handled
        case "3": applyRating(.suitable,   to: id);   return .handled
        // 4 / 5 are no-ops in the 0.8.0 3-class scheme — swallowed
        // so they don't propagate to any other handler and surprise
        // the curator. Could beep if we wanted.
        case "4", "5": return .handled
        case "r", "R":
            Task {
                await ImageLibrary.shared.toggleReflection(forImageIds: [id])
                await onMutation()
            }
            return .handled
        case "t", "T":
            Task {
                await ImageLibrary.shared.toggleTransitional(forImageIds: [id])
                await onMutation()
            }
            return .handled
        case "q", "Q":
            // Pass ⌘Q (app quit), ⌘⌥Q etc. through — the confidence
            // prefix is for plain keys only; swallowing every q
            // would block every Command-modified shortcut that
            // happens to have q in it.
            guard !press.modifiers.contains(.command) else {
                return .ignored
            }
            withAnimation(.easeInOut(duration: 0.12)) {
                pendingConfidence = (pendingConfidence == 1) ? nil : 1
            }
            return .handled
        case "c", "C":
            // Pass ⌘C (copy) through for the same reason.
            guard !press.modifiers.contains(.command) else {
                return .ignored
            }
            withAnimation(.easeInOut(duration: 0.12)) {
                pendingConfidence = (pendingConfidence == 3) ? nil : 3
            }
            return .handled
        default: return .ignored
        }
    }

    /// Recompute the cloud-motion arrow whenever the inspected index
    /// shifts. Picks the nearest earlier frame in the filtered list
    /// that shares the same camera, runs the Vision registration off
    /// the main actor, and publishes the result back when finished.
    private func recomputeMotion() async {
        guard let current = currentItem, index > 0 else {
            motion = nil
            motionComputing = false
            return
        }

        // Walk back to find a same-camera predecessor.
        var prevItem: ImageLibrary.ImageListItem?
        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            let candidate = items[candidateIndex]
            if candidate.image.cameraSource == current.image.cameraSource {
                prevItem = candidate
                break
            }
        }
        guard let prev = prevItem else {
            motion = nil
            motionComputing = false
            return
        }

        motionComputing = true
        motion = nil

        let seconds = current.image.captureUtc.timeIntervalSince(prev.image.captureUtc)
        let cameraType = current.image.cameraSource.cameraType
        let settings = AppSettings.shared
        let radius: Int
        let fov: Double
        let northOffset: Double
        switch cameraType {
        case .color:
            radius = settings.colorFisheyeRadiusPx
            fov = settings.colorFovDeg
            northOffset = settings.colorNorthOffsetDeg
        case .monochrome:
            radius = settings.monoFisheyeRadiusPx
            fov = settings.monoFovDeg
            northOffset = settings.monoNorthOffsetDeg
        }

        let prevPath = prev.image.filePath
        let currPath = current.image.filePath

        let result = await CloudMotionDetector.detect(
            previousPath: prevPath,
            currentPath: currPath,
            secondsBetween: seconds,
            cameraType: cameraType,
            fisheyeRadiusPx: radius,
            fovDeg: fov,
            northOffsetDeg: northOffset
        )

        // Only publish if the sheet still points at the same frame —
        // a quick navigation sequence can start a dozen tasks while
        // only the final one is still relevant.
        if currentItem?.id == current.id {
            motion = result
            motionComputing = false
        }
    }

    private func applyRating(_ cls: RatingClass, to id: Int64) {
        let confidence = pendingConfidence
        if pendingConfidence != nil {
            withAnimation(.easeInOut(duration: 0.12)) {
                pendingConfidence = nil
            }
        }
        Task {
            await ImageLibrary.shared.setRating(
                cls, forImageIds: [id], confidence: confidence
            )
            await onMutation()
        }
    }
}
