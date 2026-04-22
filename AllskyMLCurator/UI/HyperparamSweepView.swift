import SwiftUI

/// Sheet that drives a hyperparameter sweep over the current training
/// set, displays per-config metrics live, and lets the user pick the
/// winner and apply it to `AppSettings`. Backed by
/// `ClassifierEngine.sweep()` — the heavy lifting (GD + 5-fold CV per
/// config) already runs on a detached task, so this view only
/// observes the published status and renders.
///
/// Opened from Preferences → Advanced → "Hyperparameter sweep".
struct HyperparamSweepView: View {

    @ObservedObject private var classifier = ClassifierEngine.shared
    let onDismiss: () -> Void

    @State private var runTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introBlock
                    statusBlock
                    if case let .finished(results) = classifier.sweepStatus {
                        resultsTable(results)
                        recommendationBlock(results)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .onDisappear {
            runTask?.cancel()
        }
    }

    // MARK: - Top bar

    private var header: some View {
        HStack {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hyperparameter autopilot")
                    .font(.title3.weight(.semibold))
                Text("Sweep ML settings, pick the winner, apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            primaryButton
            Button("Close", action: onDismiss)
                .keyboardShortcut(.escape)
        }
        .padding(12)
    }

    @ViewBuilder private var primaryButton: some View {
        switch classifier.sweepStatus {
        case .idle, .failed:
            Button("Run sweep") { startSweep() }
                .buttonStyle(.borderedProminent)
        case .running:
            Button("Cancel") {
                runTask?.cancel()
                classifier.resetSweepStatus()
            }
        case .finished:
            Button("Run again") { startSweep() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Body blocks

    private var introBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this does")
                .font(.headline)
            Text("Trains the classifier 12 times with different hyperparameters and per-sample feature scalings, then ranks them by a composite score: CV accuracy *minus* 0.5 × the class-5 → {1, 4} leak rate. The leak rate penalty targets the moon-glow misclassification pattern the 0.5.x audit flagged. Each fit runs ~5 s on a Release build, so the full sweep takes about a minute.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Applies only to the current filter slice — e.g. if Night-only mode is on, the sweep trains on night frames and the winning config is the best for that slice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusBlock: some View {
        switch classifier.sweepStatus {
        case .idle:
            EmptyView()

        case let .running(done, total, name):
            VStack(alignment: .leading, spacing: 8) {
                Text("Running \(done + 1) of \(total)…")
                    .font(.headline)
                ProgressView(
                    value: Double(done),
                    total: Double(max(total, 1))
                )
                .progressViewStyle(.linear)
                Text("Current: \(name)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        case .finished:
            EmptyView()

        case .failed(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
            }
            .font(.callout)
        }
    }

    private func resultsTable(_ results: [ClassifierEngine.SweepResult]) -> some View {
        let ranked = results.sorted { $0.compositeScore > $1.compositeScore }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Results (ranked by composite score, best first)")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    columnHeader("config")
                    columnHeader("CV")
                    columnHeader("cls-5 recall")
                    columnHeader("5→1")
                    columnHeader("5→4")
                    columnHeader("cls-1 P")
                    columnHeader("score")
                    columnHeader("")
                }
                Divider().gridCellColumns(8)
                ForEach(ranked) { r in
                    let isWinner = r.id == ranked.first?.id
                    GridRow {
                        Text(r.configName)
                            .font(.callout)
                            .fontWeight(isWinner ? .bold : .regular)
                        pctCell(r.cvAccuracy)
                        pctCell(r.class5Recall)
                        leakCell(r.class5ToClass1Count, r.class5ToClass1Pct)
                        leakCell(r.class5ToClass4Count, r.class5ToClass4Pct)
                        pctCell(r.class1Precision)
                        Text(String(format: "%.3f", r.compositeScore))
                            .font(.callout.monospacedDigit())
                            .fontWeight(isWinner ? .bold : .regular)
                        Button("Apply") { apply(r) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            Text("Samples used: \(results.first?.sampleCount ?? 0). Fit time: \(results.map(\.durationSeconds).reduce(0, +).formatted(.number.precision(.fractionLength(1)))) s total.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func recommendationBlock(
        _ results: [ClassifierEngine.SweepResult]
    ) -> some View {
        if let best = results.max(by: { $0.compositeScore < $1.compositeScore }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended: \(best.configName)")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("CV \(String(format: "%.1f %%", best.cvAccuracy * 100))  ·  Class-5 recall \(String(format: "%.1f %%", best.class5Recall * 100))  ·  5→1 \(best.class5ToClass1Count) (\(String(format: "%.1f %%", best.class5ToClass1Pct * 100)))  ·  5→4 \(best.class5ToClass4Count) (\(String(format: "%.1f %%", best.class5ToClass4Pct * 100)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Click Apply next to the row to write these values into Preferences → Training and retrain automatically. Baseline = your current Preferences; winning it means no change needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Cells

    private func columnHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func pctCell(_ v: Float) -> some View {
        Text(String(format: "%.1f %%", v * 100))
            .font(.callout.monospacedDigit())
    }

    private func leakCell(_ count: Int, _ pct: Float) -> some View {
        Text("\(count) (\(String(format: "%.0f%%", pct * 100)))")
            .font(.callout.monospacedDigit())
            .foregroundStyle(pct > 0.25 ? .red : (pct > 0.10 ? .orange : .primary))
    }

    // MARK: - Actions

    private func startSweep() {
        runTask?.cancel()
        let grid = ClassifierEngine.defaultSweepGrid()
        runTask = Task { @MainActor in
            _ = await classifier.sweep(grid)
        }
    }

    /// Write the config back to AppSettings where possible and kick
    /// off a regular retrain so the Preferences values and the live
    /// classifier immediately reflect the chosen settings. The
    /// feature-scaling part (moon/sun/reflection multipliers) is
    /// **not** persisted anywhere yet — we surface it here as a
    /// diagnostic; if the winning config uses a non-1 scale, the
    /// user is told to retrain manually via ⌘T after the sweep UI
    /// saves a note.
    private func apply(_ r: ClassifierEngine.SweepResult) {
        if let boosts = r.config.classBoosts {
            AppSettings.shared.classWeightBoosts = boosts
        }
        if let hidden = r.config.hiddenDim {
            AppSettings.shared.mlpHiddenDim = hidden
        }
        if let lr = r.config.learningRate {
            AppSettings.shared.trainingLearningRate = lr
        }
        if let iters = r.config.iterations {
            AppSettings.shared.trainingIterations = iters
        }
        if let l2 = r.config.l2 {
            AppSettings.shared.trainingL2 = l2
        }
        // Kick a retrain so the live model reflects the applied
        // config. The classifier gauge will show "training…" while
        // it runs; sweep sheet can close in parallel.
        Task { await classifier.train() }
        onDismiss()
    }
}
