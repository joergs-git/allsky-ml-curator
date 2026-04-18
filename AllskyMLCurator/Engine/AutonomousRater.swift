import Foundation

/// One-shot autonomous rating pass. Walks the given list of image list
/// items, looks up each unrated item's cached classifier prediction,
/// and commits `source='auto'` labels for those whose top probability
/// clears the configured threshold. Frames without a prediction or
/// below the threshold stay unrated so the curator keeps control over
/// the ambiguous tail.
///
/// v1 ships the one-click variant exposed in the toolbar. The stream
/// UX described in plan §7.F10 (animated per-tile tick, agree-with-page
/// shortcut, live session-agreement score) will layer on top of the
/// same primitives in a later iteration — the gating + batch-commit
/// logic here is the core the streaming version will reuse.
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
        var completedAt: Date

        var userMessage: String {
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
            return "Applied \(applied) auto rating(s) across \(consideredUnrated) unrated frame(s)." + tail
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
    @Published private(set) var lastSummary: RunSummary?
    @Published private(set) var lastError: RunError?

    // MARK: - Entry point

    /// Gate, score, and commit. Returns the summary on success or an
    /// error describing why the gate closed. `items` is the caller's
    /// current filtered matrix; running against the visible set lets
    /// the user confine auto-rating to (say) "only color camera,
    /// unrated, today's batch" without a separate scope toggle.
    func run(
        on items: [ImageLibrary.ImageListItem]
    ) async -> Result<RunSummary, RunError> {
        guard !isRunning else {
            lastError = .alreadyRunning
            return .failure(.alreadyRunning)
        }
        isRunning = true
        defer { isRunning = false }

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

        var consideredUnrated = 0
        var skippedLow = 0
        var skippedNoPred = 0
        // Collect per-class ID lists so we can reuse the existing
        // setAutoRating batch path (one DB write per class).
        var idsByClass: [RatingClass: [Int64]] = [:]

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
            idsByClass[prediction.topClass, default: []].append(item.id)
        }

        var applied = 0
        for (ratingClass, ids) in idsByClass {
            await ImageLibrary.shared.setAutoRating(
                ratingClass, forImageIds: ids
            )
            applied += ids.count
        }

        let summary = RunSummary(
            applied: applied,
            skippedLowConfidence: skippedLow,
            skippedNoPrediction: skippedNoPred,
            consideredUnrated: consideredUnrated,
            completedAt: Date()
        )
        lastSummary = summary
        lastError = nil
        return .success(summary)
    }
}
