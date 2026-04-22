import AppKit
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
    @State private var copyFeedback: String?
    @State private var showHelp: Bool = false

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
            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: showHelp
                      ? "questionmark.circle.fill"
                      : "questionmark.circle")
            }
            .help("Show / hide the detailed explanation of what the sweep does and how to read the results.")
            if case let .finished(results) = classifier.sweepStatus {
                copyButton(for: results)
            }
            primaryButton
            Button("Close", action: onDismiss)
                .keyboardShortcut(.escape)
        }
        .padding(12)
    }

    /// Copy the full ranked results table to the system pasteboard
    /// as a markdown string. Saves the user from screenshotting the
    /// whole sheet every time — the text round-trips cleanly into
    /// chat / notes / github issues.
    private func copyButton(for results: [ClassifierEngine.SweepResult]) -> some View {
        Button {
            let md = Self.markdownReport(results: results)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(md, forType: .string)
            copyFeedback = "Copied!"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copyFeedback = nil
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copyFeedback == nil
                      ? "doc.on.clipboard"
                      : "checkmark")
                Text(copyFeedback ?? "Copy")
            }
        }
        .help("Copy the ranked results as a markdown table to the clipboard.")
    }

    /// Render the sweep result table as markdown — the exact shape I
    /// want to paste into chat. Winner row is **bold**, leak cells
    /// that would render red / orange in the UI get a warning emoji
    /// tag so the severity survives plaintext.
    static func markdownReport(
        results: [ClassifierEngine.SweepResult]
    ) -> String {
        let ranked = results.sorted { $0.compositeScore > $1.compositeScore }
        let winnerId = ranked.first?.id

        var lines: [String] = []
        lines.append("## Hyperparameter sweep — \(ranked.count) configs")
        lines.append("")
        if let first = ranked.first {
            lines.append(
                "Samples used: \(first.sampleCount) · "
                + "Fit time total: "
                + String(format: "%.1f s", results.map(\.durationSeconds).reduce(0, +))
            )
            lines.append("")
        }
        lines.append("| config | CV | cls-5 R | 5→1 | 5→4 | cls-1 P | MAE | score |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for r in ranked {
            let isWinner = r.id == winnerId
            let bold = isWinner ? "**" : ""
            let nameCell = "\(bold)\(r.configName)\(bold)"
            let scoreCell = "\(bold)\(String(format: "%.3f", r.compositeScore))\(bold)"
            func leak(_ count: Int, _ pct: Float) -> String {
                let p = String(format: "%.0f%%", pct * 100)
                let marker = pct > 0.25 ? " 🔴" : (pct > 0.10 ? " 🟠" : "")
                return "\(count) (\(p))\(marker)"
            }
            lines.append(
                "| \(nameCell)"
                + " | \(String(format: "%.1f %%", r.cvAccuracy * 100))"
                + " | \(String(format: "%.1f %%", r.class5Recall * 100))"
                + " | \(leak(r.class5ToClass1Count, r.class5ToClass1Pct))"
                + " | \(leak(r.class5ToClass4Count, r.class5ToClass4Pct))"
                + " | \(String(format: "%.1f %%", r.class1Precision * 100))"
                + " | \(String(format: "%.2f", r.meanAbsError))"
                + " | \(scoreCell) |"
            )
        }

        if let winner = ranked.first {
            lines.append("")
            lines.append("**Recommended: `\(winner.configName)`** — CV \(String(format: "%.1f %%", winner.cvAccuracy * 100)) · cls-5 recall \(String(format: "%.1f %%", winner.class5Recall * 100)) · 5→1 \(winner.class5ToClass1Count) (\(String(format: "%.1f %%", winner.class5ToClass1Pct * 100))) · 5→4 \(winner.class5ToClass4Count) (\(String(format: "%.1f %%", winner.class5ToClass4Pct * 100)))")

            // Emit the exact settings the winner would apply so the
            // report is actionable without re-running the sweep.
            let c = winner.config
            var settings: [String] = []
            if let boosts = c.classBoosts { settings.append("classBoosts=\(boosts)") }
            if let h = c.hiddenDim { settings.append("hiddenDim=\(h)") }
            if let lr = c.learningRate { settings.append("lr=\(lr)") }
            if let it = c.iterations { settings.append("iterations=\(it)") }
            if let l2 = c.l2 { settings.append("l2=\(l2)") }
            if c.moonVisibilityScale != 1 { settings.append("moonScale=\(c.moonVisibilityScale)") }
            if c.sunVisibilityScale != 1 { settings.append("sunScale=\(c.sunVisibilityScale)") }
            if c.reflectionRiskScale != 1 { settings.append("reflectionScale=\(c.reflectionRiskScale)") }
            if !settings.isEmpty {
                lines.append("")
                lines.append("Config: \(settings.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
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
            Text("Trains the classifier 12 times with different hyperparameters and per-sample feature scalings, then ranks them by a distance-aware composite score: **1 − MAE / 4**, where MAE is the mean absolute error in class-index units over the 5-fold CV confusion matrix. RatingClass is totally ordered (cloudiness is monotonic), so a 5 → 4 slip is scored much gentler than a 5 → 1 flip — 0.7.4 change from the prior binary-miss penalty. Each fit runs ~5 s on a Release build, so the full sweep takes about a minute.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Applies only to the current filter slice — e.g. if Night-only mode is on, the sweep trains on night frames and the winning config is the best for that slice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showHelp {
                helpSection
                    .padding(.top, 10)
            }
        }
    }

    /// Inline deep-dive help. Opens / closes via the `?` button in
    /// the header. Structured as question → answer blocks so the
    /// curator can skim and find the relevant bit.
    @ViewBuilder private var helpSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            helpBlock(
                title: "Why does this exist?",
                body: "A two-layer MLP can in principle learn the interaction `moon_phase × sin(moon_alt)` from raw aux features, but at our sample scale (~1.5 k clear-sky night frames) it demonstrably **didn't** — bright moon on clear sky kept being predicted as thin or full cloud. Hand-tuning one knob at a time was slow and opaque. The autopilot brute-forces 12 combinations and ranks them objectively."
            )
            helpBlock(
                title: "What the column headers mean",
                body: """
CV = 5-fold cross-validation accuracy (honest generalisation estimate).
cls-5 R = recall on truly clear frames — fraction correctly kept as clear.
5→1 = clear frames flipped to full clouds (worst-case leak: distance = 4).
5→4 = clear frames slipped to thin clouds (minor leak: distance = 1).
cls-1 P = precision on full-cloud predictions (when the model says "1", how often is it right).
MAE = mean absolute error in class-index units, averaged over every CV prediction. 0 = perfect, 4 = worst possible. ~0.3–0.5 is a well-tuned ordinal classifier at our data scale.
score = 1 − MAE / 4. Distance-aware composite; higher is better.
"""
            )
            helpBlock(
                title: "Why the score is distance-aware (0.7.4 change)",
                body: "The earlier composite (`CV − 0.5 × leak rate`) treated every mismatch equally: a 5 → 4 slip and a 5 → 1 flip both counted as one 'wrong'. But cloudiness is ordinal — mistaking 'clear' for 'thin cloud' is a much smaller downstream problem than mistaking it for 'full clouds'. The new composite uses ordinal distance (|predicted − actual|) so adjacent misses barely move the score and extreme flips are punished hard. Same goes for the matrix tile borders — amber for distance 1, orange for 2, deep-orange for 3, red for the 4-away worst case."
            )
            helpBlock(
                title: "What the 12 configs probe",
                body: """
3 axes × variants:
  (A) feature-scale — multiply moon / sun / reflection aux features by 10×, 50×, 100× so they dominate the first MLP layer instead of drowning in the 768-dim Vision embedding.
  (B) per-class boost — 1.5× or 2.0× on class-5 to make the model care more about getting clear right.
  (C) hidden-dim capacity — 256 or 512 hidden units for more non-linear room.
Plus a baseline (your current Preferences) and a kitchen-sink "aggro" config that stacks everything.
"""
            )
            helpBlock(
                title: "What Apply actually does",
                body: "Writes class-weight boosts, hidden-dim, learning rate, iterations, L2, AND the three feature-scale multipliers into Preferences → Training so subsequent ⌘T calls keep the new conditioning. Then kicks a fresh train() so the live model reflects the pick within ~5 s. No re-ingest or restart required. 'Baseline' winning means no change needed."
            )
            helpBlock(
                title: "When to re-run",
                body: "After every meaningful labeling pass (a few hundred new rated frames) or after toggling Night-only / Day-only mode — the sweep's answer is always 'best config for the current slice'. Also re-run after a label-quality audit where you correct a lot of existing labels — the right hyperparams shift as the training set gets cleaner."
            )
            helpBlock(
                title: "When it won't help",
                body: "If labels are the bottleneck (noisy / inconsistent human ratings), every config plateaus at the same ceiling. The leak-count columns are your tell — if all rows show similar 5→4 counts, the feature space genuinely can't separate those frames and more hyperparameter tuning won't change that. Go label-audit instead."
            )
        }
    }

    private func helpBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(.init(body))
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
                    columnHeader("cls-5 R")
                    columnHeader("5→1")
                    columnHeader("5→4")
                    columnHeader("cls-1 P")
                    columnHeader("MAE")
                    columnHeader("score")
                    columnHeader("")
                }
                Divider().gridCellColumns(9)
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
                        Text(String(format: "%.2f", r.meanAbsError))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(r.meanAbsError > 0.6 ? .red : (r.meanAbsError > 0.3 ? .orange : .primary))
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

    /// Write the config back to AppSettings (all fields including
    /// the per-feature scales) and kick off a regular retrain so
    /// the Preferences values and the live classifier immediately
    /// reflect the chosen settings. The 0.6.2 change is that
    /// feature-scale multipliers (moon / sun / reflection) now get
    /// persisted too and re-applied at vector-build time — prior to
    /// this the sweep's scaling was diagnostic only and a manual
    /// ⌘T silently regressed to baseline.
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
        // Persist the per-feature scales too — FeatureVectorBuilder
        // reads these on every vector build, so subsequent ⌘T calls
        // get the same feature conditioning the sweep discovered.
        AppSettings.shared.featureMoonVisibilityScale =
            Double(r.config.moonVisibilityScale)
        AppSettings.shared.featureSunVisibilityScale =
            Double(r.config.sunVisibilityScale)
        AppSettings.shared.featureReflectionRiskScale =
            Double(r.config.reflectionRiskScale)
        // Kick a retrain so the live model reflects the applied
        // config. The classifier gauge will show "training…" while
        // it runs; sweep sheet can close in parallel.
        Task { await classifier.train() }
        onDismiss()
    }
}
