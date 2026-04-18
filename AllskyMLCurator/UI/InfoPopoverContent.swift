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
                keyValueRow(
                    "Cached sidecars",
                    "\(embeddedCount) (\(percent(embeddedCount, items.count)))"
                )
                if let coverage = classifier.lastCoverage {
                    keyValueRow(
                        "Rated ↔ embedded",
                        "\(coverage.withEmbedding) of \(coverage.totalRated)"
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

            if !hints.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Hints", systemImage: "lightbulb")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(hints, id: \.self) { hint in
                        Text("• \(hint)")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
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

    /// Contextual one-line hints shown only when they apply.
    private var hints: [String] {
        var result: [String] = []

        if sync.status == .notConfigured {
            result.append("Supabase isn't configured — ratings are safe locally but won't sync. Preferences → Supabase.")
        }
        if items.isEmpty {
            result.append("No frames indexed yet — ⌘O to ingest a folder.")
        }
        if let coverage = classifier.lastCoverage {
            if coverage.withEmbedding < coverage.totalRated {
                let missing = coverage.totalRated - coverage.withEmbedding
                result.append("\(missing) rated frames still need embeddings. Background warmer is catching up; ⌘T works once coverage is ≥ 2 classes.")
            }
            let seen = coverage.classCounts.filter { $0 > 0 }.count
            if seen < 2, coverage.totalRated > 0 {
                result.append("Rate at least one frame of a second class so the classifier can learn to separate — e.g. set aside a known clear-sky night and key '5'.")
            }
        }
        if classifier.summary != nil,
           let coverage = classifier.lastCoverage,
           coverage.totalRated < 200 {
            result.append("< 200 human labels — predictions are still rough. Autonomous mode unlocks at 200+.")
        }
        return result
    }
}
