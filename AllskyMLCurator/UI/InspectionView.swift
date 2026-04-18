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

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                imagePane
                    .frame(
                        width: max(320, geo.size.width - 360),
                        height: geo.size.height
                    )
                    .background(AppColors.bg(nightMode))

                Divider()

                metadataPane
                    .frame(width: 360, height: geo.size.height)
                    .background(AppColors.bg(nightMode))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
    }

    // MARK: - Panes

    /// Left pane: the actual JPEG loaded at full resolution. No
    /// zenith-mask is applied here — the curator is inspecting a
    /// specific frame and usually wants to see every detail, including
    /// the burned-in overlay text. The ML pipeline still sees the
    /// masked version elsewhere.
    private var imagePane: some View {
        Group {
            if let item = currentItem,
               let nsImage = NSImage(
                contentsOf: URL(fileURLWithPath: item.image.filePath)
               ) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(AppColors.fgDim(nightMode))
                    Text(currentItem?.image.filePath ?? "nothing selected")
                        .font(.caption)
                        .foregroundStyle(AppColors.fgDim(nightMode))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    /// Right pane: readable tables of the stuff that matters when
    /// deciding whether a prediction looks right.
    private var metadataPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                timeBlock
                ephemerisBlock
                sensorBlock
                ratingBlock
                predictionBlock
                Spacer(minLength: 20)
            }
            .padding(20)
        }
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

    private var ratingBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Rating")
            if let item = currentItem, let label = item.label {
                metaRow("Class", "\(label.ratingClass.rawValue) — \(label.ratingClass.shortName)")
                metaRow("Source", label.source.rawValue)
                metaRow("Sample weight", String(format: "%.2f", label.sampleWeight))
                if label.reflectionFlag { metaRow("Flags", "R (reflection)") }
                if label.transitionalFlag { metaRow("Flags", "T (transitional)") }
            } else {
                Text("unrated")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
            }
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
                ForEach(0..<5, id: \.self) { rawMinusOne in
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
        case "0": applyRating(.unrated,   to: id);   return .handled
        case "1": applyRating(.fullCloud, to: id);   return .handled
        case "2": applyRating(.mostly,    to: id);   return .handled
        case "3": applyRating(.some,      to: id);   return .handled
        case "4": applyRating(.thin,      to: id);   return .handled
        case "5": applyRating(.clear,     to: id);   return .handled
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
