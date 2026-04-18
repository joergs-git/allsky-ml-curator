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
            Text(cls.shortName)
                .font(.caption)
                .foregroundStyle(AppColors.fgDim(nightMode))
                .lineLimit(1)
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
                BigMetric(
                    label: "train accuracy",
                    primary: "\(Int(summary.trainAccuracy * 100))%",
                    secondary: "on \(summary.sampleCount) labels",
                    accent: accuracyColor(summary.trainAccuracy),
                    nightMode: nightMode
                )
                detailRow("Last trained",
                          summary.trainedAt.formatted(date: .omitted, time: .shortened))
                detailRow("Duration", String(format: "%.0f ms", summary.durationSeconds * 1000))
                detailRow("Class counts", classCountsBreakdown(summary.classCounts))
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
                        title: "Thin tails — rate more of the rare classes",
                        body: "Classes with <30 samples: \(smallClasses). With the inverse-frequency × 3× clear-sky boost these already over-influence training; more samples stabilise predictions."
                    ))
                }
            }
        }

        if let summary = classifier.summary {
            let acc = summary.trainAccuracy
            if acc < 0.4 {
                result.append(AnalysisTip(
                    title: "Training accuracy is low (\(Int(acc * 100))%)",
                    body: "Near-random for 5 classes. Likely causes: (1) class distribution still very skewed, (2) the 3× clear-sky boost over-weights the rare classes, (3) thin tails in 1 or 5. Fix order: rate more of whichever class has the fewest samples, retrain, check whether accuracy climbs."
                ))
            } else if acc < 0.6 {
                result.append(AnalysisTip(
                    title: "Classifier getting started (\(Int(acc * 100))%)",
                    body: "Predictions are useful but not trustworthy yet. Scroll through the remaining unrated tiles — agree where the 🧠 badge matches, correct where it doesn't, retrain after every 30-50 corrections."
                ))
            } else {
                result.append(AnalysisTip(
                    title: "Classifier in good shape (\(Int(acc * 100))% on \(summary.sampleCount) labels)",
                    body: "Predictions on unrated frames should be plausible now. Toggle 'Only unrated' to see them."
                ))
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
