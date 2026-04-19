import Combine
import Foundation

/// Two-phase Vision FeaturePrint warmer that catches up every rated
/// and unrated frame whose `.fp` sidecar is missing.
///
/// Split out of `ContentView.warmRatedEmbeddings` in 0.4.1 so it can
/// be retriggered mid-session without restarting the app — the
/// launch-time `.task` modifier snapshotted the rated list exactly
/// once, which left every frame the user rated *during* the session
/// silently unembedded. A second `run()` after a long rating burst
/// re-snapshots the DB and picks up the newly-rated gap.
///
/// Phase order (rated → unrated) is preserved: rated frames feed the
/// training set and get priority (without them ⌘T has nothing to
/// learn from); unrated frames feed prediction (without their
/// sidecars the matrix can't show brain badges). During the unrated
/// phase `ClassifierEngine.refreshPredictions()` fires every 100 new
/// embeddings so brain badges appear progressively rather than in
/// one all-or-nothing jump at the end.
///
/// Re-entrancy: `run()` is a no-op while a previous pass is still
/// executing, so clicking the Embeddings chip twice (or combining it
/// with the launch-time trigger) never spawns parallel warmers.
@MainActor
final class EmbeddingWarmer: ObservableObject {

    // MARK: - Singleton

    static let shared = EmbeddingWarmer()
    private init() {}

    // MARK: - Observable state

    enum Phase: String, Sendable {
        case idle
        case scanning   // fetching rated/unrated lists from the DB
        case rated      // iterating rated frames
        case unrated    // iterating unrated frames
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var done: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var newlyEmbedded: Int = 0
    @Published private(set) var lastFinishedAt: Date?
    @Published private(set) var lastSummary: String?

    // MARK: - Private

    private var currentTask: Task<Void, Never>?

    // MARK: - Public API

    /// Start a fresh two-phase warm pass. No-op if one is already
    /// running — the caller gets the existing progress instead.
    func run() {
        guard !isRunning else { return }
        isRunning = true
        phase = .scanning
        done = 0
        total = 0
        newlyEmbedded = 0
        lastSummary = nil

        currentTask = Task { [weak self] in
            await self?.performRun()
            await MainActor.run {
                self?.isRunning = false
                self?.phase = .idle
                self?.currentTask = nil
                self?.lastFinishedAt = Date()
            }
        }
    }

    /// Cancel the in-flight pass. Safe to call when idle.
    func cancel() {
        currentTask?.cancel()
    }

    // MARK: - Worker

    private func performRun() async {
        let rated = await ImageLibrary.shared.fetchRatedImages()
        let unrated = await ImageLibrary.shared.fetchUnratedImages()

        // Heavy work (Vision + SMB reads) must stay off MainActor.
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.warmPhase(
                images: rated,
                phaseMarker: .rated,
                refreshPredictionsEvery: nil
            )
            await self.warmPhase(
                images: unrated,
                phaseMarker: .unrated,
                refreshPredictionsEvery: 100
            )

            // Final prediction refresh even if the last batch didn't
            // hit the 100-frame tick — otherwise the freshly-embedded
            // tail stays brain-less until the next ⌘T.
            await ClassifierEngine.shared.refreshPredictions()
        }.value

        let summary = "\(newlyEmbedded) new embedding(s) written."
        await MainActor.run { self.lastSummary = summary }
    }

    /// Walk one phase of images, generating embeddings for anything
    /// that doesn't already have a `.fp` sidecar on disk. Updates the
    /// observable counters on MainActor after every frame so the
    /// Preferences progress view advances live.
    nonisolated private func warmPhase(
        images: [ImageRecord],
        phaseMarker: Phase,
        refreshPredictionsEvery: Int?
    ) async {
        await MainActor.run {
            self.phase = phaseMarker
            self.done = 0
            self.total = images.count
        }

        var newThisPhase = 0
        for image in images {
            if Task.isCancelled { return }

            let alreadyCached = EmbeddingPipeline.shared
                .sidecarExists(for: image.filePath)
            if !alreadyCached {
                _ = await EmbeddingPipeline.shared.generate(
                    for: image.filePath,
                    cameraType: image.cameraSource.cameraType
                )
                newThisPhase += 1
                if let every = refreshPredictionsEvery,
                   newThisPhase.isMultiple(of: every) {
                    await ClassifierEngine.shared.refreshPredictions()
                }
            }

            await MainActor.run {
                self.done += 1
                if !alreadyCached { self.newlyEmbedded += 1 }
            }
        }
    }
}
