import Foundation

/// Streaming autonomous rater. Walks the filtered image list, looks up
/// each unrated item's cached classifier prediction, and commits
/// `source='auto'` labels one at a time so the curator can watch the
/// matrix fill in live. Frames without a prediction or below the
/// confidence threshold stay unrated — human attention goes to the
/// ambiguous tail rather than to frames the model is confident about.
///
/// Flow in the UI:
///   1. ⌘⇧A (or toolbar button) calls `stream(on:onBatch:)`.
///   2. Rater iterates the pre-filtered work list; commits an auto
///      label per item; bumps `progress` after every write.
///   3. `onBatch` fires every `batchSize` items (default 8) so
///      ContentView can reload the grid and the new ratings animate
///      in visibly, without a per-item DB round-trip for a thousand
///      tiny reload calls.
///   4. Pressing the button a second time, or ⌘. / Esc routed by the
///      caller, flips `stopRequested` and the loop bails after the
///      current item.
///
/// Gates (plan §7.F10): minimum human-label count and a trained
/// classifier are both required before the loop starts; autonomous
/// mode stays locked on a fresh install until the curator has put
/// real work in.
@MainActor
final class AutonomousRater: ObservableObject {

    // MARK: - Singleton

    static let shared = AutonomousRater()
    private init() {}

    // MARK: - Types

    struct RunSummary: Equatable, Sendable {
        var applied: Int
        var skippedLowConfidence: Int
        var skippedNoPrediction: Int
        var consideredUnrated: Int
        var wasStopped: Bool
        var completedAt: Date

        var userMessage: String {
            let verb = wasStopped ? "Stopped after applying" : "Applied"
            if applied == 0 {
                return "Nothing applied. \(skippedLowConfidence) frame(s) below the confidence threshold, \(skippedNoPrediction) without a classifier prediction."
            }
            var tail = ""
            if skippedLowConfidence > 0 {
                tail += " \(skippedLowConfidence) skipped below threshold."
            }
            if skippedNoPrediction > 0 {
                tail += " \(skippedNoPrediction) skipped without a prediction."
            }
            return "\(verb) \(applied) auto rating(s) across \(consideredUnrated) unrated frame(s)." + tail
        }
    }

    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
        /// Fractional completion 0…1 — convenient for a progress bar.
        var fraction: Double {
            total > 0 ? Double(done) / Double(total) : 0
        }
    }

    enum RunError: LocalizedError {
        case insufficientHumanLabels(have: Int, need: Int)
        case noClassifier
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .insufficientHumanLabels(let have, let need):
                return "Auto-rate locked until \(need) human labels exist — currently \(have). Keep rating manually to unlock."
            case .noClassifier:
                return "No trained classifier yet. Press ⌘T to train before running auto-rate."
            case .alreadyRunning:
                return "Auto-rate is already running."
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var progress: Progress?
    @Published private(set) var lastSummary: RunSummary?
    @Published private(set) var lastError: RunError?

    // MARK: - Config

    /// Frames committed between UI reload pings. Small enough to feel
    /// animated, large enough to avoid drowning the matrix in reload
    /// work for multi-thousand-image sessions.
    private let batchSize = 8
    /// Pause between batches — keeps the grid re-layout smooth while
    /// still flushing hundreds of frames per minute in practice.
    private let pauseBetweenBatchesNs: UInt64 = 30_000_000    // 30 ms

    private var stopRequested: Bool = false

    // MARK: - Control

    /// Flag the running stream to bail after the current item. Safe to
    /// call from any MainActor context — if nothing is streaming the
    /// call is a no-op.
    func stop() {
        stopRequested = true
    }

    // MARK: - Entry point

    /// Gate, score, then stream auto-ratings. Publishes `progress`
    /// every write; calls `onBatch` every `batchSize` items so the
    /// caller (ContentView) can refresh the displayed list.
    func stream(
        on items: [ImageLibrary.ImageListItem],
        onBatch: @escaping () async -> Void
    ) async -> Result<RunSummary, RunError> {
        guard !isRunning else {
            lastError = .alreadyRunning
            return .failure(.alreadyRunning)
        }
        isRunning = true
        stopRequested = false
        progress = nil
        defer {
            isRunning = false
            progress = nil
        }

        // --- Gates ---------------------------------------------------
        let humanLabels = await ImageLibrary.shared.humanLabelCount()
        let gate = AppSettings.shared.autonomousMinLabels
        guard humanLabels >= gate else {
            let err = RunError.insufficientHumanLabels(
                have: humanLabels, need: gate
            )
            lastError = err
            return .failure(err)
        }

        let predictions = ClassifierEngine.shared.predictions
        guard !predictions.isEmpty else {
            lastError = .noClassifier
            return .failure(.noClassifier)
        }

        let threshold = Float(AppSettings.shared.autonomousConfidenceThreshold)

        // --- Build the work list once -------------------------------
        var work: [(id: Int64, ratingClass: RatingClass)] = []
        var consideredUnrated = 0
        var skippedLow = 0
        var skippedNoPred = 0

        for item in items {
            let cls = item.label?.ratingClass ?? .unrated
            guard cls == .unrated else { continue }
            consideredUnrated += 1

            guard let prediction = predictions[item.id] else {
                skippedNoPred += 1
                continue
            }
            guard prediction.topProbability >= threshold else {
                skippedLow += 1
                continue
            }
            work.append((item.id, prediction.topClass))
        }

        // --- Streaming commit loop ----------------------------------
        progress = Progress(done: 0, total: work.count)
        var applied = 0

        for (index, pair) in work.enumerated() {
            if stopRequested { break }

            await ImageLibrary.shared.setAutoRating(
                pair.ratingClass, forImageIds: [pair.id]
            )
            applied += 1
            progress = Progress(done: applied, total: work.count)

            if (index + 1) % batchSize == 0 {
                await onBatch()
                try? await Task.sleep(nanoseconds: pauseBetweenBatchesNs)
            }
        }
        // Final flush so the last partial batch renders before the
        // alert fires.
        await onBatch()

        let summary = RunSummary(
            applied: applied,
            skippedLowConfidence: skippedLow,
            skippedNoPrediction: skippedNoPred,
            consideredUnrated: consideredUnrated,
            wasStopped: stopRequested,
            completedAt: Date()
        )
        lastSummary = summary
        lastError = nil
        return .success(summary)
    }
}
