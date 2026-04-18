import SwiftUI

/// Floating info panel triggered from the toolbar ⓘ button.
/// Formatted dashboard of everything the curator might want to know
/// at a glance — rating progress, classifier coverage + health,
/// embedding warm-up, sync status, and a couple of actionable hints
/// pulled from the current state.
struct InfoPopoverContent: View {

    let items: [ImageLibrary.ImageListItem]
    let selectedIds: Set<Int64>
    let embeddedCount: Int
    @ObservedObject var classifier: ClassifierEngine
    @ObservedObject var sync: SyncEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            section("Rating", icon: "star.leadinghalf.filled") {
                keyValueRow("Total frames", "\(items.count)")
                keyValueRow("Rated", "\(ratedCount) (\(percent(ratedCount, items.count)))")
                keyValueRow("Selected", "\(selectedIds.count)")
                if !classDistribution.isEmpty {
                    keyValueRow("Distribution", classDistribution)
                }
            }

            section("Embeddings", icon: "cpu") {
                // No percent here — `embeddedCount` sums every sidecar
                // on disk (all cameras, ingested or filtered out), so
                // dividing by the filtered `items.count` gave useless
                // numbers like 5310 %. The meaningful ratio lives in
                // the "Rated ↔ embedded" row right below.
                keyValueRow("Cached sidecars", "\(embeddedCount)")
                if let coverage = classifier.lastCoverage {
                    let pct = percent(coverage.withEmbedding, coverage.totalRated)
                    keyValueRow(
                        "Rated ↔ embedded",
                        "\(coverage.withEmbedding) of \(coverage.totalRated) (\(pct))"
                    )
                }
                keyValueRow("Pipeline", "Apple Vision FeaturePrint")
            }

            section("Classifier", icon: "brain.head.profile") {
                if classifier.isTraining {
                    keyValueRow("State", "training…")
                } else if let summary = classifier.summary {
                    keyValueRow("Last trained", summary.trainedAt.formatted(date: .abbreviated, time: .shortened))
                    keyValueRow("Training samples", "\(summary.sampleCount)")
                    keyValueRow("Train accuracy", "\(Int(summary.trainAccuracy * 100))%")
                    keyValueRow("Duration", String(format: "%.0f ms", summary.durationSeconds * 1000))
                    keyValueRow("Class counts", classCountsBreakdown(summary.classCounts))
                } else {
                    keyValueRow("State", "untrained")
                    if let coverage = classifier.lastCoverage {
                        let present = coverage.classCounts.filter { $0 > 0 }.count
                        keyValueRow("Classes seen", "\(present) of 5 — need ≥ 2 to train")
                    }
                }
                if let error = classifier.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Sync to Supabase", icon: "icloud") {
                keyValueRow("State", sync.status.statusText)
                if case .upToDate(let count, let at) = sync.status {
                    keyValueRow("Last push", at.formatted(date: .omitted, time: .shortened))
                    keyValueRow("Rows pushed", "\(count)")
                }
                if case .failed(let message) = sync.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            if !analysisTips.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Analysis helper", systemImage: "lightbulb")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(analysisTips, id: \.title) { tip in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tip.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(tip.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    /// A single actionable tip shown inside the Analysis Helper block.
    /// `title` reads like a headline, `body` spells out what the user
    /// can try next.
    private struct AnalysisTip: Hashable {
        let title: String
        let body: String
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.metering.matrix")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("AllSky ML Curator")
                    .font(.headline)
                Text("live status overview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section template

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
            content()
        }
    }

    private func keyValueRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Derived state

    private var ratedCount: Int {
        items.filter { ($0.label?.ratingClass ?? .unrated) != .unrated }.count
    }

    /// Human-readable class-spread summary drawn from the current
    /// matrix contents (not the classifier's coverage snapshot which
    /// may lag).
    private var classDistribution: String {
        var counts = [Int](repeating: 0, count: 6)
        for item in items {
            counts[item.label?.ratingClass.rawValue ?? 0] += 1
        }
        return classCountsDistribution(counts)
    }

    private func classCountsDistribution(_ counts: [Int]) -> String {
        var parts: [String] = []
        let labels = ["0 unrated", "1 full", "2 mostly", "3 some", "4 thin", "5 clear"]
        for (i, label) in labels.enumerated() where counts[i] > 0 {
            parts.append("\(label): \(counts[i])")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    private func classCountsBreakdown(_ counts: [Int]) -> String {
        let labels = ["1", "2", "3", "4", "5"]
        var parts: [String] = []
        for (i, label) in labels.enumerated() where counts[i] > 0 {
            parts.append("\(label): \(counts[i])")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    private func percent(_ n: Int, _ total: Int) -> String {
        guard total > 0 else { return "0 %" }
        return "\(Int(Double(n) * 100 / Double(total))) %"
    }

    /// Rich, context-aware advice shown as the "Analysis helper"
    /// block. Rules inspect every engine's state and surface only the
    /// tips that currently apply — so the user sees concrete next
    /// actions instead of a laundry list.
    private var analysisTips: [AnalysisTip] {
        var result: [AnalysisTip] = []

        // --- Configuration / data gaps ---------------------------------

        if sync.status == .notConfigured {
            result.append(AnalysisTip(
                title: "Supabase isn't configured",
                body: "Ratings are safe locally but won't sync to the shared astro-weather project. Preferences → Supabase → paste URL + anon key → Save."
            ))
        }
        if case .failed(let message) = sync.status {
            result.append(AnalysisTip(
                title: "Sync push failed",
                body: "\(message)\n\nIf the error mentions HTTP 409 / duplicate key the curator is already at the latest build that sends `on_conflict=image_path` — pull main and retry. For other errors paste the message into a bug report; the full text is selectable above."
            ))
        }
        if items.isEmpty {
            result.append(AnalysisTip(
                title: "No frames indexed yet",
                body: "⌘O opens the ingest sheet. Pick the folder under your Synology mount, choose the camera type and image format, run Dry-run first to verify the count, then Ingest."
            ))
        }

        // --- Embedding readiness ---------------------------------------

        if let coverage = classifier.lastCoverage,
           coverage.totalRated > 0,
           coverage.withEmbedding < coverage.totalRated {
            let missing = coverage.totalRated - coverage.withEmbedding
            result.append(AnalysisTip(
                title: "Embedding catch-up in progress",
                body: "\(missing) rated frames don't have a cached Vision embedding yet. The launch-time warmer is processing them in the background — watch the Embeddings gauge fill. Training needs ≥ 2 classes of embedded frames to succeed."
            ))
        }

        // --- Class spread ---------------------------------------------

        if let coverage = classifier.lastCoverage, coverage.totalRated > 0 {
            let present = coverage.classCounts.filter { $0 > 0 }.count
            if present < 2 {
                result.append(AnalysisTip(
                    title: "Only one class rated so far",
                    body: "The classifier needs samples from at least two different classes to learn to separate them. If the night was genuinely fully cloudy, open another ingested day and rate at least one clear or thin frame."
                ))
            } else if present < 4, coverage.totalRated > 200 {
                result.append(AnalysisTip(
                    title: "Class spread is narrow",
                    body: "Only \(present) of 5 classes are represented. The classifier will work but won't tell apart the missing tiers. Aim for ≥ 30 samples in every class — especially 1 (full clouds) and 5 (clear) which are usually the rare ones."
                ))
            }
            if coverage.totalRated >= 100 {
                let minPopulated = coverage.classCounts.filter { $0 > 0 }.min() ?? 0
                if minPopulated < 30 && present >= 2 {
                    let labels = ["1", "2", "3", "4", "5"]
                    let smallClasses = zip(labels, coverage.classCounts)
                        .filter { $0.1 > 0 && $0.1 < 30 }
                        .map { "\($0.0) (\($0.1))" }
                        .joined(separator: ", ")
                    result.append(AnalysisTip(
                        title: "Thin tails — rate more of the rare classes",
                        body: "Classes with <30 samples: \(smallClasses). With the inverse-frequency × 3× clear-sky boost they already over-influence training; more samples stabilise predictions. Toggle 'Only unrated' and look for frames that match those categories."
                    ))
                }
            }
        }

        // --- Training outcome -----------------------------------------

        if let summary = classifier.summary {
            let acc = summary.trainAccuracy
            if acc < 0.4 {
                result.append(AnalysisTip(
                    title: "Training accuracy is low (\(Int(acc * 100))%)",
                    body: "Near-random for 5 classes. Likely causes: (1) class distribution still very skewed, (2) the 3× clear-sky boost over-weights the rare classes and pushes the classifier to predict 4/5 too often, (3) thin tails in 1 or 5. Fix order: rate more of whichever class has the fewest samples, retrain, and check whether accuracy climbs."
                ))
            } else if acc < 0.6 {
                result.append(AnalysisTip(
                    title: "Classifier getting started (\(Int(acc * 100))%)",
                    body: "Predictions are useful but not trustworthy yet. Scroll through the remaining unrated tiles with 'Only unrated' on — agree where the 🧠 badge matches, correct where it doesn't, and retrain after every 30-50 corrections."
                ))
            } else {
                result.append(AnalysisTip(
                    title: "Classifier in good shape (\(Int(acc * 100))% on \(summary.sampleCount) labels)",
                    body: "Predictions on unrated frames should be plausible now. Toggle 'Only unrated' to see them — and if anything still looks weird, open the Classifier chip to retrain, or raise the minimum class coverage first."
                ))
            }
        }

        // --- Autonomous-mode gate -------------------------------------

        if let coverage = classifier.lastCoverage, coverage.totalRated < 200 {
            result.append(AnalysisTip(
                title: "Autonomous mode locked",
                body: "Unlocks at ≥ 200 genuine human labels (you're at \(coverage.totalRated)). Once there, ⌘⇧A will hand the stream to the classifier — it labels, you just press A to confirm a page or a digit to override."
            ))
        }

        return result
    }
}
