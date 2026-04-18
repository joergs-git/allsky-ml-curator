import SwiftUI

/// Right-hand status sidebar, permanently docked to the main window.
/// Replaces the old popover. Everything is visible at a glance: the
/// rating distribution with tier-coloured star rows, big accuracy /
/// coverage numbers, a live-colour sync block, and a conditional
/// "Analysis helper" section that only renders the tips that apply
/// to the current state.
///
/// Height: scroll view occupies everything between the toolbar and
/// the window bottom. Width is set by the caller (ContentView) so
/// the panel is easy to hide / resize later.
struct InfoSidePanel: View {

    let items: [ImageLibrary.ImageListItem]
    let selectedIds: Set<Int64>
    let embeddedCount: Int
    @ObservedObject var classifier: ClassifierEngine
    @ObservedObject var sync: SyncEngine
    let nightMode: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBlock
                Divider()
                ratingSection
                Divider()
                classifierSection
                Divider()
                embeddingSection
                Divider()
                syncSection
                if !analysisTips.isEmpty {
                    Divider()
                    analysisHelperSection
                }
                Spacer(minLength: 24)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .background(AppColors.bgToolbar(nightMode))
    }

    // MARK: - Header

    private var headerBlock: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.85), .purple.opacity(0.75)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                Image(systemName: "camera.metering.matrix")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AllSky ML Curator")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColors.fg(nightMode))
                Text("live status")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
            }
            Spacer()
        }
    }

    // MARK: - Rating section

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Rating", icon: "star.leadinghalf.filled")

            BigMetric(
                label: "rated",
                primary: "\(ratedCount)",
                secondary: "of \(items.count) · \(percent(ratedCount, items.count))",
                accent: ratedRatioColor,
                nightMode: nightMode
            )

            VStack(alignment: .leading, spacing: 4) {
                ForEach([RatingClass.clear, .thin, .some, .mostly, .fullCloud], id: \.self) { cls in
                    starRow(for: cls, count: classCount(for: cls))
                }
            }

            if unratedCount > 0 {
                HStack {
                    Text("unrated")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.fgDim(nightMode))
                    Spacer()
                    Text("\(unratedCount)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            if selectedIds.count > 0 {
                HStack {
                    Text("selected")
                        .font(.caption)
                        .foregroundStyle(AppColors.fgDim(nightMode))
                    Spacer()
                    Text("\(selectedIds.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppColors.fg(nightMode))
                }
            }
        }
    }

    private func starRow(for cls: RatingClass, count: Int) -> some View {
        let color = AppColors.tier(cls, night: nightMode)
        return HStack(spacing: 8) {
            HStack(spacing: 1) {
                ForEach(0..<cls.rawValue, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(color)
                }
                ForEach(0..<(5 - cls.rawValue), id: \.self) { _ in
                    Image(systemName: "star")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(AppColors.fgVeryDim(nightMode))
                }
            }
            .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(cls.shortName)
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
                    .lineLimit(1)
                Text(cls.coverageHint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppColors.fgVeryDim(nightMode))
            }
            Spacer()
            Text("\(count)")
                .font(.system(.body, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? color : AppColors.fgVeryDim(nightMode))
        }
    }

    // MARK: - Classifier

    private var classifierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Classifier", icon: "brain.head.profile")

            if classifier.isTraining {
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("training…")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.blue)
                }
            } else if let summary = classifier.summary {
                // Headline number = 5-fold CV accuracy (honest
                // generalisation), falls back to train accuracy when
                // the dataset is too small to split into five usable
                // folds. `trainAccuracy` is kept as a detail row for
                // comparison — a large gap between the two indicates
                // overfitting.
                let headline = summary.cvAccuracy ?? summary.trainAccuracy
                BigMetric(
                    label: summary.cvAccuracy != nil
                        ? "5-fold CV accuracy"
                        : "train accuracy (CV skipped)",
                    primary: "\(Int(headline * 100))%",
                    secondary: "on \(summary.sampleCount) labels",
                    accent: accuracyColor(headline),
                    nightMode: nightMode
                )
                detailRow("Train accuracy",
                          "\(Int(summary.trainAccuracy * 100))%")
                if let cv = summary.cvAccuracy {
                    let gap = Int((summary.trainAccuracy - cv) * 100)
                    if gap > 10 {
                        detailRow("Overfit gap", "+\(gap) pts (train > CV)")
                    }
                }
                detailRow("Last trained",
                          summary.trainedAt.formatted(date: .omitted, time: .shortened))
                detailRow("Duration", String(format: "%.0f ms", summary.durationSeconds * 1000))
                detailRow("Class counts", classCountsBreakdown(summary.classCounts))

                if let metrics = summary.classMetrics, !metrics.isEmpty {
                    classMetricsTable(metrics)
                }
                if let confusion = summary.confusionMatrix {
                    confusionMatrixView(confusion)
                }
            } else if let coverage = classifier.lastCoverage {
                let classesSeen = coverage.classCounts.filter { $0 > 0 }.count
                BigMetric(
                    label: "ready to train",
                    primary: "\(coverage.withEmbedding)",
                    secondary: "of \(coverage.totalRated) rated · \(classesSeen)/5 classes",
                    accent: classesSeen >= 2 ? .green : .orange,
                    nightMode: nightMode
                )
                Text("Hit ⌘T to train on the current set.")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
            } else {
                Text("No rated frames yet — start rating and coverage will appear here.")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
            }

            if let error = classifier.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Classifier metrics helpers

    /// Per-class Precision / Recall / F1 table. Uses the class tier
    /// colour in the leftmost cell so the rows visually tie to the
    /// rating stars above.
    private func classMetricsTable(
        _ metrics: [ClassifierEngine.ClassMetrics]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PER-CLASS QUALITY")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(AppColors.fgDim(nightMode))
                .padding(.top, 4)
            HStack(spacing: 0) {
                Text("cls").frame(width: 30, alignment: .leading)
                Text("n").frame(width: 44, alignment: .trailing)
                Text("P").frame(width: 42, alignment: .trailing)
                Text("R").frame(width: 42, alignment: .trailing)
                Text("F1").frame(width: 42, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppColors.fgDim(nightMode))
            ForEach(metrics, id: \.ratingClass) { row in
                HStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(
                                AppColors.tier(row.ratingClass, night: nightMode)
                            )
                        Text("\(row.ratingClass.rawValue)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppColors.fg(nightMode))
                    }
                    .frame(width: 30, alignment: .leading)
                    Text("\(row.support)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                    metricCell(row.precision).frame(width: 42, alignment: .trailing)
                    metricCell(row.recall).frame(width: 42, alignment: .trailing)
                    metricCell(row.f1).frame(width: 42, alignment: .trailing)
                }
                .foregroundStyle(AppColors.fg(nightMode))
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func metricCell(_ value: Float) -> some View {
        let percent = Int((value * 100).rounded())
        Text("\(percent)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(accuracyColor(value))
    }

    /// Compact 5×5 confusion matrix visual. Diagonal cells shade
    /// green (correct predictions), off-diagonal shade red (confusion),
    /// intensity scaled by count. Axis labels mirror the tier colours.
    private func confusionMatrixView(_ matrix: [Int]) -> some View {
        let K = 5
        let maxValue = max(1, matrix.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("CONFUSION (true → predicted)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(AppColors.fgDim(nightMode))
                .padding(.top, 8)
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    Color.clear.frame(width: 16, height: 18)
                    ForEach(0..<K, id: \.self) { col in
                        axisLabel(for: col)
                            .frame(width: 36, height: 18)
                    }
                }
                ForEach(0..<K, id: \.self) { row in
                    HStack(spacing: 1) {
                        axisLabel(for: row)
                            .frame(width: 16, height: 22)
                        ForEach(0..<K, id: \.self) { col in
                            let count = matrix[row * K + col]
                            confusionCell(
                                count: count,
                                isDiagonal: row == col,
                                maxValue: maxValue
                            )
                            .frame(width: 36, height: 22)
                        }
                    }
                }
            }
        }
    }

    private func axisLabel(for index: Int) -> some View {
        let cls = RatingClass(rawValue: index + 1) ?? .unrated
        return Text("\(index + 1)")
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundStyle(AppColors.tier(cls, night: nightMode))
    }

    private func confusionCell(
        count: Int, isDiagonal: Bool, maxValue: Int
    ) -> some View {
        let intensity = maxValue > 0 ? Double(count) / Double(maxValue) : 0
        let colour: Color = isDiagonal
            ? Color.green.opacity(0.15 + 0.65 * intensity)
            : (count == 0 ? AppColors.bgControl(nightMode)
                          : Color.red.opacity(0.1 + 0.55 * intensity))
        return ZStack {
            Rectangle().fill(colour)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppColors.fg(nightMode))
        }
    }

    // MARK: - Embeddings

    private var embeddingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Embeddings", icon: "cpu")
            BigMetric(
                label: "cached sidecars",
                primary: "\(embeddedCount)",
                secondary: "Apple Vision FeaturePrint",
                accent: .blue,
                nightMode: nightMode
            )
            if let coverage = classifier.lastCoverage, coverage.totalRated > 0 {
                ProgressRow(
                    label: "Rated frames embedded",
                    current: coverage.withEmbedding,
                    total: coverage.totalRated,
                    tint: coverage.withEmbedding >= coverage.totalRated ? .green : .blue,
                    nightMode: nightMode
                )
            }
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Sync", icon: "icloud")
            HStack(spacing: 8) {
                Image(systemName: syncIconName)
                    .font(.title2)
                    .foregroundStyle(syncIconColor)
                    .symbolEffect(.pulse, options: .repeating, value: sync.status.isPushing)
                Text(sync.status.statusText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(syncIconColor)
            }
            if case .failed(let message) = sync.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .upToDate(let count, let at) = sync.status {
                detailRow("Rows pushed", "\(count)")
                detailRow("Last push", at.formatted(date: .omitted, time: .shortened))
            }
        }
    }

    // MARK: - Analysis helper

    private var analysisHelperSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Analysis helper", icon: "lightbulb", tint: .orange)
            ForEach(analysisTips, id: \.title) { tip in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tip.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppColors.fg(nightMode))
                    Text(tip.body)
                        .font(.caption)
                        .foregroundStyle(AppColors.fgDim(nightMode))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(nightMode ? 0.18 : 0.10))
                )
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(
        _ title: String, icon: String, tint: Color? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? AppColors.fgDim(nightMode))
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1)
                .foregroundStyle(tint ?? AppColors.fgDim(nightMode))
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption)
                .foregroundStyle(AppColors.fgDim(nightMode))
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppColors.fg(nightMode))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Derived

    private var ratedCount: Int {
        items.filter { ($0.label?.ratingClass ?? .unrated) != .unrated }.count
    }

    private var unratedCount: Int {
        items.count - ratedCount
    }

    private func classCount(for cls: RatingClass) -> Int {
        items.filter { ($0.label?.ratingClass ?? .unrated) == cls }.count
    }

    private var ratedRatioColor: Color {
        guard items.count > 0 else { return .gray }
        let ratio = Double(ratedCount) / Double(items.count)
        if ratio >= 0.98 { return .green }
        if ratio >= 0.5  { return .blue }
        return .orange
    }

    private func accuracyColor(_ accuracy: Float) -> Color {
        switch accuracy {
        case 0.7...:   return .green
        case 0.5..<0.7: return .blue
        case 0.3..<0.5: return .orange
        default:       return .red
        }
    }

    private var syncIconName: String {
        switch sync.status {
        case .idle, .notConfigured: return "icloud.slash"
        case .pushing:              return "arrow.up.circle"
        case .upToDate:             return "checkmark.icloud.fill"
        case .failed:               return "exclamationmark.icloud.fill"
        }
    }

    private var syncIconColor: Color {
        switch sync.status {
        case .upToDate: return .green
        case .pushing:  return .blue
        case .failed:   return .red
        default:        return .gray
        }
    }

    private func classCountsBreakdown(_ counts: [Int]) -> String {
        let labels = ["1", "2", "3", "4", "5"]
        let parts = zip(labels, counts)
            .filter { $0.1 > 0 }
            .map { "\($0.0): \($0.1)" }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    private func percent(_ n: Int, _ total: Int) -> String {
        guard total > 0 else { return "0 %" }
        return "\(Int(Double(n) * 100 / Double(total))) %"
    }

    // MARK: - Analysis helper tips

    private struct AnalysisTip: Hashable {
        let title: String
        let body: String
    }

    private var analysisTips: [AnalysisTip] {
        var result: [AnalysisTip] = []

        if sync.status == .notConfigured {
            result.append(AnalysisTip(
                title: "Supabase isn't configured",
                body: "Ratings are safe locally but won't sync to the shared astro-weather project. Preferences → Supabase → paste URL + anon key → Save."
            ))
        }
        if case .failed(let message) = sync.status {
            result.append(AnalysisTip(
                title: "Sync push failed",
                body: message
            ))
        }
        if items.isEmpty {
            result.append(AnalysisTip(
                title: "No frames indexed yet",
                body: "⌘O opens the ingest sheet. Pick the folder under your Synology mount, choose the camera type and image format, run Dry-run first to verify the count, then Ingest."
            ))
        }

        if let coverage = classifier.lastCoverage,
           coverage.totalRated > 0,
           coverage.withEmbedding < coverage.totalRated {
            let missing = coverage.totalRated - coverage.withEmbedding
            result.append(AnalysisTip(
                title: "Embedding catch-up in progress",
                body: "\(missing) rated frames don't have a cached Vision embedding yet. The launch-time warmer is processing them in the background — watch the Embeddings gauge fill."
            ))
        }

        if let coverage = classifier.lastCoverage, coverage.totalRated > 0 {
            let present = coverage.classCounts.filter { $0 > 0 }.count
            if present < 2 {
                result.append(AnalysisTip(
                    title: "Only one class rated so far",
                    body: "The classifier needs samples from at least two different classes to learn to separate them. Open another ingested day and rate at least one frame of a different class."
                ))
            } else if present < 4, coverage.totalRated > 200 {
                result.append(AnalysisTip(
                    title: "Class spread is narrow",
                    body: "Only \(present) of 5 classes are represented. Aim for ≥ 30 samples in every class — especially 1 (full clouds) and 5 (clear) which are usually the rare ones."
                ))
            }
            if coverage.totalRated >= 100 {
                let labels = ["1", "2", "3", "4", "5"]
                let smallClasses = zip(labels, coverage.classCounts)
                    .filter { $0.1 > 0 && $0.1 < 30 }
                    .map { "\($0.0) (\($0.1))" }
                    .joined(separator: ", ")
                if !smallClasses.isEmpty, present >= 2 {
                    result.append(AnalysisTip(
                        title: "Sparse classes — rate more of the rare ones",
                        body: "Classes with <30 samples: \(smallClasses). With the inverse-frequency × 3× clear-sky boost these already over-influence training; more samples stabilise predictions."
                    ))
                }
            }
        }

        if let summary = classifier.summary {
            let headlineAcc = summary.cvAccuracy ?? summary.trainAccuracy
            if headlineAcc < 0.4 {
                result.append(AnalysisTip(
                    title: "Generalisation accuracy is low (\(Int(headlineAcc * 100))%)",
                    body: "Near-random for 5 classes. Likely causes: (1) class distribution still very skewed, (2) the 3× clear-sky boost over-weights the rare classes, (3) embeddings cannot yet separate the visual tiers. Fix order: rate more of whichever class has the fewest samples, retrain, check whether accuracy climbs."
                ))
            } else if headlineAcc < 0.6 {
                result.append(AnalysisTip(
                    title: "Classifier getting started (\(Int(headlineAcc * 100))%)",
                    body: "Predictions are useful but not trustworthy yet. Scroll through the remaining unrated tiles — agree where the 🧠 badge matches, correct where it doesn't, retrain after every 30-50 corrections."
                ))
            } else {
                result.append(AnalysisTip(
                    title: "Classifier in good shape (\(Int(headlineAcc * 100))% on \(summary.sampleCount) labels)",
                    body: "Predictions on unrated frames should be plausible now. Toggle 'Only unrated' to see them."
                ))
            }

            // Overfit gap — train accuracy notably higher than CV
            // accuracy indicates the model memorises the training set
            // instead of generalising. Usually means the feature
            // space is narrow for the current class spread.
            if let cv = summary.cvAccuracy {
                let gap = summary.trainAccuracy - cv
                if gap > 0.15 {
                    result.append(AnalysisTip(
                        title: "Overfitting detected (+\(Int(gap * 100)) pts gap)",
                        body: "Train accuracy runs well above 5-fold CV — the classifier is memorising the training frames. Either rate more diverse samples (especially in the under-represented classes) or reduce the clear-sky boost via a future Preferences knob."
                    ))
                }
            }

            // Zero-recall surfaces per-class failure modes the
            // headline number hides — e.g. class 5 simply never
            // gets predicted, yet overall accuracy looks ok because
            // class 3 dominates.
            if let metrics = summary.classMetrics {
                let deadClasses = metrics.filter {
                    $0.support >= 10 && $0.recall < 0.1
                }
                if !deadClasses.isEmpty {
                    let names = deadClasses.map { "\($0.ratingClass.rawValue) (\($0.ratingClass.shortName))" }
                        .joined(separator: ", ")
                    result.append(AnalysisTip(
                        title: "Blind-spot classes",
                        body: "The classifier almost never predicts: \(names). Feature embedding may not discriminate them, or the class weights are pushing the decision boundary away. Consider rating more examples of these classes or adjusting the clear-sky boost."
                    ))
                }

                // Mirror the above for over-eager classes: precision
                // near zero with non-trivial support = false positives
                // drowning any real signal.
                let overCallers = metrics.filter {
                    $0.support >= 10 && $0.precision < 0.2 && $0.recall > 0
                }
                if !overCallers.isEmpty {
                    let names = overCallers.map { "\($0.ratingClass.rawValue)" }
                        .joined(separator: ", ")
                    result.append(AnalysisTip(
                        title: "False-positive heavy classes",
                        body: "Classes \(names) are predicted often but mostly wrong — precision below 20%. The model is over-eager, typically because inverse-frequency × clear-sky boost makes the gradient steer toward them. More samples in neighbour classes reduces this."
                    ))
                }
            }
        }

        if let coverage = classifier.lastCoverage, coverage.totalRated < 200 {
            result.append(AnalysisTip(
                title: "Autonomous mode locked",
                body: "Unlocks at ≥ 200 genuine human labels (you're at \(coverage.totalRated))."
            ))
        }

        return result
    }
}

// MARK: - Reusable pieces

struct BigMetric: View {
    let label: String
    let primary: String
    let secondary: String
    let accent: Color
    let nightMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(AppColors.fgDim(nightMode))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(primary)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProgressRow: View {
    let label: String
    let current: Int
    let total: Int
    let tint: Color
    let nightMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
                Spacer()
                Text("\(current) / \(total)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppColors.fg(nightMode))
            }
            ProgressView(
                value: Double(current),
                total: Double(max(total, 1))
            )
            .progressViewStyle(.linear)
            .tint(tint)
        }
    }
}
