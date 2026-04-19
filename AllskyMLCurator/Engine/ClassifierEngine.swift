import Accelerate
import Foundation
import GRDB

/// Two-layer MLP head sitting on top of the Vision FeaturePrint
/// embeddings. 5 output classes (RatingClass 1…5), Dense → ReLU →
/// Dense → softmax, full-batch gradient descent via Accelerate
/// matmul, in-memory weights. No mini-batching, no momentum; at the
/// curator's scale (≤ a few tens of thousands of labels) convergence
/// still happens in a few seconds.
///
/// Architecture upgrade (0.4.2 → 0.5.0): the previous linear softmax
/// head collapsed on Rheine's 14.9k-label library — train accuracy
/// never rose past ~30 % because the "full clouds at bright day" vs
/// "clear at bright day" boundary in Vision FeaturePrint space isn't
/// linearly separable. Adding one hidden ReLU layer (default 128
/// units, live-tunable in Preferences → Training) gives the head
/// enough capacity to learn that non-linear cut without a heavy
/// framework dependency.
///
/// Training / prediction pipeline:
///
///   1. `train()` loads every image with a current human label,
///      reads cached embeddings, builds feature vectors, applies
///      inverse-frequency × per-class-boost sample weights, runs
///      ~200 iterations of full-batch softmax-CE GD over *both*
///      layers, and stores the resulting weights.
///   2. `predict(image:)` rebuilds the feature vector for one frame
///      and returns per-class probabilities + the top pick.
///
/// Every successful `train()` snapshot is persisted to the local
/// `model_versions` table (row keyed by a timestamped version string);
/// on app launch `restoreLatestModel()` rehydrates the most recent row
/// so predictions are warm immediately without a fresh retrain. The
/// blob format is a compact little-endian dump — magic + version 2 +
/// featureDim + hiddenDim + numClasses + W1 + b1 + W2 + b2 — decoded
/// in `decodeWeights(_:)`. Older `CMLW v1` (linear logreg) blobs are
/// silently rejected by the v2 decoder; the user just retrains.
@MainActor
final class ClassifierEngine: ObservableObject {

    // MARK: - Singleton

    static let shared = ClassifierEngine()
    private init() {}

    // MARK: - Types

    struct Prediction: Equatable, Sendable {
        /// Probabilities per `RatingClass`, indices 0…4 → classes 1…5.
        var probabilities: [Float]
        var topClass: RatingClass
        var topProbability: Float
    }

    struct TrainingSummary: Equatable, Sendable {
        var trainedAt: Date
        var sampleCount: Int
        var classCounts: [Int]     // 5 slots
        var finalLoss: Float
        var trainAccuracy: Float
        /// Generalization accuracy estimated via 5-fold cross-validation
        /// — the "honest" number the user should look at. Nil when the
        /// dataset is too small to split into five usable folds.
        var cvAccuracy: Float?
        /// 5×5 confusion matrix from CV. Row = true class, column =
        /// predicted class (indices 0…4 → RatingClass 1…5). Nil when
        /// CV was skipped.
        var confusionMatrix: [Int]?
        /// Per-class precision / recall / F1 / support, derived from
        /// the confusion matrix.
        var classMetrics: [ClassMetrics]?
        var durationSeconds: Double
    }

    struct ClassMetrics: Equatable, Sendable {
        let ratingClass: RatingClass
        let support: Int
        let precision: Float
        let recall: Float
        let f1: Float
    }

    enum TrainingError: Error, LocalizedError {
        case noLabeledFrames
        case noEmbeddingsAvailable(totalRated: Int)
        case partialEmbeddingCoverage(withEmbedding: Int, totalRated: Int, classCounts: [Int])
        case insufficientClasses(withEmbedding: Int, totalRated: Int, classCounts: [Int])

        var errorDescription: String? {
            switch self {
            case .noLabeledFrames:
                return "No human-rated frames yet. Rate at least a handful across two or more classes, then retrain."

            case .noEmbeddingsAvailable(let totalRated):
                return "\(totalRated) rated, but none of them have a cached embedding yet. Scroll through the matrix so the embedding generator catches up (watch the embed chip), then retrain."

            case .partialEmbeddingCoverage(let emb, let total, let counts):
                return "Only \(emb) of \(total) rated frames have a cached embedding, and so far they all fall into one class — \(Self.countsBreakdown(counts)). Scroll further (or wait) for the embedding generator to cover more classes, then retrain."

            case .insufficientClasses(let emb, let total, let counts):
                return "\(emb) of \(total) rated frames have a cached embedding, all in one class — \(Self.countsBreakdown(counts)). The classifier needs at least two distinct classes. Rate at least one frame in a different class and retrain."
            }
        }

        fileprivate static func countsBreakdown(_ counts: [Int]) -> String {
            let labels = ["1", "2", "3", "4", "5"]
            let parts = zip(labels, counts)
                .filter { $0.1 > 0 }
                .map { "\($0.0): \($0.1)" }
            return parts.isEmpty ? "none" : parts.joined(separator: ", ")
        }
    }

    // MARK: - Observable state

    @Published private(set) var summary: TrainingSummary?
    @Published private(set) var isTraining: Bool = false
    @Published private(set) var lastError: String?
    /// Last computed breakdown of the training set (rated totals,
    /// embedded count, per-class counts). Available even when
    /// training failed — powers the toolbar status line.
    @Published private(set) var lastCoverage: TrainingCoverage?

    struct TrainingCoverage: Equatable, Sendable {
        var totalRated: Int
        var withEmbedding: Int
        var classCounts: [Int]      // length numClasses
    }
    /// Predictions for every image the classifier has seen so far.
    /// Repopulated from a fresh `train()` + inference pass. Keyed by
    /// ImageRecord id.
    @Published private(set) var predictions: [Int64: Prediction] = [:]

    // MARK: - Config

    private struct Hyperparameters {
        var iterations: Int
        var learningRate: Float
        var l2: Float
        /// Per-RatingClass multiplier applied on top of inverse-frequency
        /// weighting. `[0]` → class 1, `[4]` → class 5. Length is
        /// always 5 (clamped in `current()`); values < 1 suppress a
        /// class, values > 1 over-weight it.
        var classBoosts: [Float]
        /// Width of the hidden ReLU layer. 0 would degenerate to a
        /// linear logreg — not worth supporting since that case was
        /// the root cause of the 0.4.x accuracy ceiling. Clamped to
        /// at least 16 in `current()` so an accidental 0 in defaults
        /// doesn't produce an NaN gradient.
        var hiddenDim: Int

        /// Read live from AppSettings so the Preferences → Training
        /// sliders take effect on the *next* ⌘T without needing to
        /// restart the app. Re-instantiated at the start of every
        /// train() call.
        static func current() -> Hyperparameters {
            let raw = AppSettings.shared.classWeightBoosts
            let boosts = (0..<5).map { i in
                Float(i < raw.count ? raw[i] : 1.0)
            }
            let hidden = max(16, AppSettings.shared.mlpHiddenDim)
            return Hyperparameters(
                iterations: AppSettings.shared.trainingIterations,
                learningRate: Float(AppSettings.shared.trainingLearningRate),
                l2: Float(AppSettings.shared.trainingL2),
                classBoosts: boosts,
                hiddenDim: hidden
            )
        }
    }

    private var hp = Hyperparameters.current()
    private let numClasses = 5    // RatingClass 1…5

    /// Trained parameters — two layers, all row-major:
    ///  - `weights1` [featureDim × hiddenDim] and `bias1` [hiddenDim]
    ///    feed the hidden ReLU.
    ///  - `weights2` [hiddenDim × numClasses] and `bias2` [numClasses]
    ///    feed the softmax.
    private var weights1: [Float] = []
    private var bias1: [Float] = []
    private var weights2: [Float] = []
    private var bias2: [Float] = []
    private var featureDim: Int = 0
    private var hiddenDim: Int = 0
    /// Monotonically increases every time `weights` is replaced
    /// (train(), restoreLatestModel(), clear()). `recomputeAllPredictions`
    /// reads the current value before spawning its detached task and
    /// ignores the result if the version advanced while the task ran
    /// — otherwise an older recompute can finish after a newer one
    /// and overwrite the newer model's predictions with stale scores.
    private var weightsVersion: Int = 0

    // MARK: - Public API

    /// Train on every current human label (skipping 'auto' rows per
    /// plan section 7.F6 — those are provisional). The caller should
    /// debounce rapid label commits if needed.
    func train() async {
        guard !isTraining else { return }
        isTraining = true
        lastError = nil
        defer { isTraining = false }

        // Re-read hyperparameters so changes made in Preferences →
        // Training between runs take effect on the next ⌘T without a
        // restart.
        hp = Hyperparameters.current()

        do {
            let started = Date()
            let diagnostics = try await loadTrainingSet()
            let samples = diagnostics.samples

            var classCounts = [Int](repeating: 0, count: numClasses)
            for sample in samples { classCounts[sample.classIndex] += 1 }

            let distinctClasses = classCounts.filter { $0 > 0 }.count
            let embeddedCount = samples.count

            lastCoverage = TrainingCoverage(
                totalRated: diagnostics.totalRated,
                withEmbedding: embeddedCount,
                classCounts: classCounts
            )

            if embeddedCount == 0 {
                throw TrainingError.noEmbeddingsAvailable(
                    totalRated: diagnostics.totalRated
                )
            }
            if distinctClasses < 2 {
                // Tell the user whether the coverage gap (few
                // embeddings) or the labeling spread (one class only)
                // is the real blocker — they require different fixes.
                if embeddedCount < diagnostics.totalRated / 2 {
                    throw TrainingError.partialEmbeddingCoverage(
                        withEmbedding: embeddedCount,
                        totalRated: diagnostics.totalRated,
                        classCounts: classCounts
                    )
                } else {
                    throw TrainingError.insufficientClasses(
                        withEmbedding: embeddedCount,
                        totalRated: diagnostics.totalRated,
                        classCounts: classCounts
                    )
                }
            }

            let weightsPerSample = sampleWeights(
                classCounts: classCounts,
                samples: samples
            )

            let (finalLoss, trainAccuracy) = runGradientDescent(
                samples: samples,
                sampleWeights: weightsPerSample
            )

            // Generalization estimate via 5-fold CV. Requires at
            // least ~10 samples in every represented class, else each
            // fold's train set would lose a whole class and the
            // accuracy number becomes misleading. When too small,
            // we still report train accuracy and the user gets a
            // note in the analysis helper explaining why CV is off.
            let cvResult = runCrossValidationIfFeasible(
                samples: samples,
                classCounts: classCounts,
                sampleWeights: weightsPerSample
            )

            let duration = Date().timeIntervalSince(started)

            summary = TrainingSummary(
                trainedAt: Date(),
                sampleCount: samples.count,
                classCounts: classCounts,
                finalLoss: finalLoss,
                trainAccuracy: trainAccuracy,
                cvAccuracy: cvResult?.accuracy,
                confusionMatrix: cvResult?.confusion,
                classMetrics: cvResult.map {
                    Self.deriveClassMetrics(
                        confusion: $0.confusion,
                        numClasses: self.numClasses
                    )
                },
                durationSeconds: duration
            )
            weightsVersion &+= 1

            await recomputeAllPredictions()
            await persistTrainedModel()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
    }

    /// Restore the most recently trained classifier from the local DB
    /// so predictions are available immediately on app launch. Silent
    /// when the table is empty or the blob header doesn't match.
    func restoreLatestModel() async {
        let reader = Database.shared.reader
        let row = try? await reader.read { db in
            try ModelVersionRecord
                .order(Column("trainedAt").desc)
                .fetchOne(db)
        }
        guard let row else { return }
        guard let decoded = Self.decodeWeights(row.classifierWeights) else {
            // Either an older blob shape (e.g. CMLW v1 logreg from
            // 0.4.x) or a corrupt row. Leaving the in-memory state
            // untrained means the toolbar chip will still report
            // "untrained" — the curator can retrain with ⌘T.
            return
        }
        weights1 = decoded.weights1
        bias1 = decoded.bias1
        weights2 = decoded.weights2
        bias2 = decoded.bias2
        featureDim = decoded.featureDim
        hiddenDim = decoded.hiddenDim
        weightsVersion &+= 1

        // Unpack the trainAccuracy + duration stashed in `notes`
        // as JSON by persistTrainedModel. Older rows (notes=nil)
        // still decode — trainAccuracy stays 0 only for them, and
        // the UI already prefers CV as the headline metric.
        var restoredTrainAccuracy: Float = 0
        var restoredDuration: Double = 0
        if let notes = row.notes,
           let data = notes.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data)
             as? [String: Double] {
            restoredTrainAccuracy = Float(dict["trainAccuracy"] ?? 0)
            restoredDuration = dict["durationSeconds"] ?? 0
        }
        summary = TrainingSummary(
            trainedAt: row.trainedAt,
            sampleCount: row.trainingSetSize,
            classCounts: row.classCounts,
            finalLoss: 0,           // not persisted
            trainAccuracy: restoredTrainAccuracy,
            cvAccuracy: row.accuracy5FoldCV.map(Float.init),
            confusionMatrix: nil,   // not persisted
            classMetrics: nil,      // not persisted
            durationSeconds: restoredDuration
        )

        await recomputeAllPredictions()
    }

    /// Predict for a single image. Returns `nil` when the classifier
    /// has not been trained yet, or when no cached embedding exists.
    func predict(image: ImageRecord) -> Prediction? {
        guard !weights2.isEmpty, featureDim > 0, hiddenDim > 0 else {
            return nil
        }
        guard let vector = FeatureVectorBuilder.vector(for: image),
              vector.count == featureDim else { return nil }
        return Self.runPrediction(
            vector: vector,
            weights1: weights1, bias1: bias1,
            weights2: weights2, bias2: bias2,
            hiddenDim: hiddenDim,
            numClasses: numClasses
        )
    }

    /// Re-score every image against the current weights without
    /// retraining. Called by the embedding warmer after it finishes
    /// catching up unrated frames so brain badges appear on tiles
    /// whose sidecar was only just generated. No-op when the
    /// classifier is empty.
    func refreshPredictions() async {
        guard !weights2.isEmpty, featureDim > 0, hiddenDim > 0 else {
            return
        }
        await recomputeAllPredictions()
    }

    /// Clear in-memory model + predictions. Useful when the user
    /// wants to reset before a fresh train.
    func clear() {
        weights1 = []
        bias1 = []
        weights2 = []
        bias2 = []
        featureDim = 0
        hiddenDim = 0
        summary = nil
        predictions = [:]
        weightsVersion &+= 1
    }

    /// Recompute the coverage snapshot without actually training.
    /// Powers the toolbar chip's status line so the user sees
    /// "X of Y rated, classes {1: 822}" before they even hit Train.
    ///
    /// Performance-critical: fires from a 2-second poll in
    /// ContentView. The old implementation delegated to
    /// `loadTrainingSet()` which decoded every 768-float sidecar into
    /// an actual feature vector (for the classifier's training path)
    /// — on a MainActor-isolated engine with ~5 k labels that was
    /// ~5 s of main-thread work every 2 s, starving tile rendering
    /// until the grid looked "stuck at first 100 thumbnails". This
    /// counts-only variant runs off MainActor via `Task.detached` and
    /// checks sidecar *existence* (one `stat` per file) instead of
    /// decoding the floats.
    func refreshCoverage() async {
        let numClasses = self.numClasses
        let computed = await Task.detached(priority: .utility) {
            () -> TrainingCoverage? in
            return try? Self.computeCoverageSnapshot(numClasses: numClasses)
        }.value
        if let computed { lastCoverage = computed }
    }

    /// Pure function: reads DB + does fast file-existence checks,
    /// returns a `TrainingCoverage` or throws. Called from a detached
    /// task so the main thread never spends time on sidecar I/O.
    nonisolated private static func computeCoverageSnapshot(
        numClasses: Int
    ) throws -> TrainingCoverage {
        let reader = Database.shared.reader
        let labels = try reader.read { db in
            try LabelRecord
                .filter(Column("isCurrent") == true)
                .filter(Column("source") == "human")
                .filter(Column("ratingClass") != RatingClass.unrated.rawValue)
                .fetchAll(db)
        }
        if labels.isEmpty {
            return TrainingCoverage(
                totalRated: 0,
                withEmbedding: 0,
                classCounts: [Int](repeating: 0, count: numClasses)
            )
        }

        let labelImageIds = labels.map(\.imageId)
        let images = try reader.read { db in
            try ImageRecord
                .filter(labelImageIds.contains(Column("id")))
                .fetchAll(db)
        }
        let imageById = Dictionary(
            uniqueKeysWithValues: images.compactMap { img in
                img.id.map { ($0, img) }
            }
        )

        var counts = [Int](repeating: 0, count: numClasses)
        var embedded = 0
        for label in labels {
            guard label.ratingClass.rawValue >= 1 else { continue }
            counts[label.ratingClass.rawValue - 1] += 1
            if let image = imageById[label.imageId],
               EmbeddingPipeline.shared.sidecarExists(for: image.filePath) {
                embedded += 1
            }
        }
        return TrainingCoverage(
            totalRated: labels.count,
            withEmbedding: embedded,
            classCounts: counts
        )
    }

    // MARK: - Data loading

    private struct LabeledSample: Sendable {
        let imageId: Int64
        let features: [Float]
        let classIndex: Int         // 0…4 → RatingClass 1…5
        /// Per-sample weight from `LabelRecord.sampleWeight` —
        /// transitional human labels carry 0.5, auto-confirmed 0.3,
        /// plain human labels 1.0. Multiplied into the class-weight
        /// before training so noisy samples really do contribute less.
        let labelWeight: Float
    }

    /// Result of a training-set build. `totalRated` is the raw count
    /// of human-labelled images (regardless of embedding coverage)
    /// so the error path can tell the user whether the blocker is
    /// "rate more variety" or "wait for embeddings".
    private struct TrainingSetDiagnostics {
        let samples: [LabeledSample]
        let totalRated: Int
    }

    /// Read every rated image that has a cached embedding, build its
    /// feature vector, and return the aligned (features, class) pairs.
    private func loadTrainingSet() async throws -> TrainingSetDiagnostics {
        let reader = Database.shared.reader

        let labels = try await reader.read { db in
            try LabelRecord
                .filter(Column("isCurrent") == true)
                .filter(Column("source") == "human")
                .filter(Column("ratingClass") != RatingClass.unrated.rawValue)
                .fetchAll(db)
        }
        guard !labels.isEmpty else { throw TrainingError.noLabeledFrames }

        let labelImageIds = labels.map(\.imageId)
        let images = try await reader.read { db in
            try ImageRecord
                .filter(labelImageIds.contains(Column("id")))
                .fetchAll(db)
        }
        let imageByIdPairs: [(Int64, ImageRecord)] = images.compactMap { img in
            img.id.map { ($0, img) }
        }
        let imageById = Dictionary(uniqueKeysWithValues: imageByIdPairs)

        var samples: [LabeledSample] = []
        samples.reserveCapacity(labels.count)
        for label in labels {
            guard let image = imageById[label.imageId] else { continue }
            guard let vector = FeatureVectorBuilder.vector(for: image) else { continue }
            guard label.ratingClass.rawValue >= 1 else { continue }
            samples.append(
                LabeledSample(
                    imageId: label.imageId,
                    features: vector,
                    classIndex: label.ratingClass.rawValue - 1,   // 1…5 → 0…4
                    labelWeight: Float(label.sampleWeight)
                )
            )
        }

        if let first = samples.first { featureDim = first.features.count }
        return TrainingSetDiagnostics(
            samples: samples,
            totalRated: labels.count
        )
    }

    private func sampleWeights(
        classCounts: [Int],
        samples: [LabeledSample]
    ) -> [Float] {
        // Inverse-frequency weights with a per-class multiplicative
        // boost from `hp.classBoosts`. Starting in 0.4.2 every class
        // has its own tunable knob; before that a single
        // `clearClassBoost` was applied uniformly to classes 4 + 5
        // (c >= 3) — which over-collapsed class 1 at the 14.9k-label
        // scale, since the boosted-but-already-bright class-5 samples
        // dominated the gradient and class-1 samples were starved
        // below the decision boundary.
        let total = Float(samples.count)
        var classWeights = [Float](repeating: 1, count: numClasses)
        for c in 0..<numClasses where classCounts[c] > 0 {
            let invFreq = total / Float(classCounts[c] * numClasses)
            let boost = c < hp.classBoosts.count ? hp.classBoosts[c] : 1.0
            classWeights[c] = invFreq * boost
        }
        // Normalise so the mean weight stays around 1 — keeps the
        // effective learning rate comparable to an unweighted run.
        let mean = classWeights.reduce(0, +) / Float(numClasses)
        if mean > 0 { for c in 0..<numClasses { classWeights[c] /= mean } }

        // Multiply the per-label sampleWeight into the per-sample
        // weight so `transitional_flag = true` human labels (weight
        // 0.5) and `auto_confirmed` labels (0.3) drag the gradient
        // proportionally less. Without this step the 0.5 sat idly on
        // the label rows without ever reaching the optimiser.
        return samples.map {
            classWeights[$0.classIndex] * $0.labelWeight
        }
    }

    // MARK: - Gradient descent

    /// Full-batch softmax-CE gradient descent over the two-layer MLP.
    /// Trains both layers simultaneously, stores the result in
    /// `self.weights{1,2}` / `self.bias{1,2}`, returns the final
    /// weighted loss + unweighted training accuracy for the summary row.
    private func runGradientDescent(
        samples: [LabeledSample],
        sampleWeights: [Float]
    ) -> (loss: Float, accuracy: Float) {
        let N = samples.count
        let D = samples[0].features.count
        let H = hp.hiddenDim
        let K = numClasses

        // Pack X row-major: [N × D]
        var X = [Float](repeating: 0, count: N * D)
        for (i, sample) in samples.enumerated() {
            for j in 0..<D { X[i * D + j] = sample.features[j] }
        }
        let y = samples.map(\.classIndex)

        // One-hot Y [N × K]
        var Y = [Float](repeating: 0, count: N * K)
        for (i, c) in y.enumerated() { Y[i * K + c] = 1 }

        // Layer init — He for W1 (ReLU), Xavier-ish for W2.
        // featureDim hasn't been set yet for the first fresh train;
        // record it here so downstream snapshots are consistent.
        featureDim = D
        hiddenDim = H
        weights1 = Self.initialHeWeights(inDim: D, outDim: H, seed: 1)
        bias1    = [Float](repeating: 0, count: H)
        weights2 = Self.initialHeWeights(inDim: H, outDim: K, seed: 2)
        bias2    = [Float](repeating: 0, count: K)

        // Forward buffers.
        var pre1  = [Float](repeating: 0, count: N * H)   // X @ W1 + b1
        var hAct  = [Float](repeating: 0, count: N * H)   // ReLU(pre1)
        var probs = [Float](repeating: 0, count: N * K)   // softmax(H @ W2 + b2)
        // Backward buffers.
        var dPre1  = [Float](repeating: 0, count: N * H)
        var dH     = [Float](repeating: 0, count: N * H)
        var dW1    = [Float](repeating: 0, count: D * H)
        var dB1    = [Float](repeating: 0, count: H)
        var dW2    = [Float](repeating: 0, count: H * K)
        var dB2    = [Float](repeating: 0, count: K)

        var finalLoss: Float = 0

        for _ in 0..<hp.iterations {
            forwardMLP(
                X: X,
                W1: weights1, b1: bias1,
                W2: weights2, b2: bias2,
                pre1: &pre1, hAct: &hAct, probs: &probs,
                N: N, D: D, H: H, K: K
            )

            // Softmax-CE gradient w.r.t. logits: (P - Y), scaled by
            // per-sample weight and divided by N.
            var diff = probs
            vDSP.subtract(probs, Y, result: &diff)
            applySampleWeights(to: &diff, weights: sampleWeights, K: K)
            var invN = Float(1) / Float(N)
            vDSP_vsmul(diff, 1, &invN, &diff, 1, vDSP_Length(N * K))

            // Output layer grads.
            // dW2 = hAct^T @ diff  →  [H × K]
            multiply(
                aT: true, a: hAct, aRows: N, aCols: H,
                bT: false, b: diff, bRows: N, bCols: K,
                out: &dW2
            )
            // dB2 = column sums of diff.
            for k in 0..<K {
                var colSum: Float = 0
                for i in 0..<N { colSum += diff[i * K + k] }
                dB2[k] = colSum
            }

            // Hidden layer grads.
            // dH = diff @ W2^T  →  [N × H]
            multiply(
                aT: false, a: diff, aRows: N, aCols: K,
                bT: true, b: weights2, bRows: H, bCols: K,
                out: &dH
            )
            // dPre1 = dH * (pre1 > 0).  ReLU derivative gate.
            for idx in 0..<(N * H) {
                dPre1[idx] = pre1[idx] > 0 ? dH[idx] : 0
            }
            // dW1 = X^T @ dPre1  →  [D × H]
            multiply(
                aT: true, a: X, aRows: N, aCols: D,
                bT: false, b: dPre1, bRows: N, bCols: H,
                out: &dW1
            )
            // dB1 = column sums of dPre1.
            for h in 0..<H {
                var colSum: Float = 0
                for i in 0..<N { colSum += dPre1[i * H + h] }
                dB1[h] = colSum
            }

            // L2 regularisation on both weight matrices.
            var lambda = hp.l2
            var two: Float = 2
            var l2scale = lambda * two
            vDSP_vsma(
                weights1, 1, &l2scale, dW1, 1, &dW1, 1,
                vDSP_Length(D * H)
            )
            vDSP_vsma(
                weights2, 1, &l2scale, dW2, 1, &dW2, 1,
                vDSP_Length(H * K)
            )

            // Parameter update: θ -= lr * grad.
            var negLR = -hp.learningRate
            vDSP_vsma(
                dW1, 1, &negLR, weights1, 1, &weights1, 1,
                vDSP_Length(D * H)
            )
            vDSP_vsma(
                dB1, 1, &negLR, bias1, 1, &bias1, 1,
                vDSP_Length(H)
            )
            vDSP_vsma(
                dW2, 1, &negLR, weights2, 1, &weights2, 1,
                vDSP_Length(H * K)
            )
            vDSP_vsma(
                dB2, 1, &negLR, bias2, 1, &bias2, 1,
                vDSP_Length(K)
            )

            finalLoss = crossEntropyLoss(
                probs: probs, y: y, weights: sampleWeights
            )
        }

        // Training accuracy (unweighted).
        forwardMLP(
            X: X,
            W1: weights1, b1: bias1,
            W2: weights2, b2: bias2,
            pre1: &pre1, hAct: &hAct, probs: &probs,
            N: N, D: D, H: H, K: K
        )
        var correct = 0
        for i in 0..<N {
            var best: Float = -.greatestFiniteMagnitude
            var bestIdx = 0
            for k in 0..<K where probs[i * K + k] > best {
                best = probs[i * K + k]
                bestIdx = k
            }
            if bestIdx == y[i] { correct += 1 }
        }
        let accuracy = Float(correct) / Float(N)

        return (finalLoss, accuracy)
    }

    // MARK: - Cross-validation

    private struct CVResult {
        let accuracy: Float
        /// Row-major K × K matrix where [true × K + predicted] = count.
        let confusion: [Int]
    }

    /// Decide whether we can afford a 5-fold CV and run it.
    /// Skipped when any represented class has fewer than 10 samples —
    /// at that point one fold's training set loses the class entirely
    /// and the reported accuracy misleads.
    private func runCrossValidationIfFeasible(
        samples: [LabeledSample],
        classCounts: [Int],
        sampleWeights: [Float]
    ) -> CVResult? {
        let minSamplesPerClass = 10
        let smallestPresentClass = classCounts.filter { $0 > 0 }.min() ?? 0
        guard samples.count >= 50,
              smallestPresentClass >= minSamplesPerClass
        else { return nil }
        return runCrossValidation(
            samples: samples, sampleWeights: sampleWeights
        )
    }

    /// 5-fold CV. For every fold we refit on 4/5 of the data and
    /// predict the held-out 1/5; predictions across folds cover the
    /// whole dataset exactly once, giving an honest generalisation
    /// accuracy. Same hyperparameters as the main train() call so
    /// the number reflects the model the user actually gets.
    private func runCrossValidation(
        samples: [LabeledSample],
        sampleWeights: [Float]
    ) -> CVResult {
        let K = numClasses
        let n = samples.count
        var confusion = [Int](repeating: 0, count: K * K)
        var correct = 0

        // Stable pseudo-random shuffle: xorshift on indices so the
        // fold assignment depends only on data order, not a fresh
        // randomness source that would change the reported number
        // between two identical train calls.
        var order = Array(0..<n)
        var rng: UInt64 = 0xC0FFEE
        for i in (1..<n).reversed() {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            let j = Int(rng % UInt64(i + 1))
            order.swapAt(i, j)
        }

        let shuffledSamples = order.map { samples[$0] }
        let shuffledWeights = order.map { sampleWeights[$0] }
        let foldSize = n / 5

        for foldIdx in 0..<5 {
            let testStart = foldIdx * foldSize
            let testEnd   = (foldIdx == 4) ? n : testStart + foldSize

            let trainIndices = Array(0..<testStart) + Array(testEnd..<n)
            let trainSamples = trainIndices.map { shuffledSamples[$0] }
            let trainWeights = trainIndices.map { shuffledWeights[$0] }
            let testSamples = Array(shuffledSamples[testStart..<testEnd])

            // Skip a fold whose training set ends up with <2 classes
            // (extreme skew + small dataset edge case).
            let trainClassSet = Set(trainSamples.map(\.classIndex))
            guard trainClassSet.count >= 2 else { continue }

            let fit = fitMLP(
                samples: trainSamples, sampleWeights: trainWeights
            )

            for sample in testSamples {
                let predicted = Self.argmaxPrediction(
                    vector: sample.features,
                    weights1: fit.W1, bias1: fit.b1,
                    weights2: fit.W2, bias2: fit.b2,
                    hiddenDim: fit.H, numClasses: K
                )
                confusion[sample.classIndex * K + predicted] += 1
                if predicted == sample.classIndex { correct += 1 }
            }
        }

        let accuracy = Float(correct) / Float(n)
        return CVResult(accuracy: accuracy, confusion: confusion)
    }

    /// Extracted from runGradientDescent so the CV loop can refit
    /// without touching the live `self.weights{1,2}`. Same numerics:
    /// He-init → full-batch softmax-CE GD over the two layers → L2 on
    /// both weight matrices, per-sample weight scaling on the diff.
    private func fitMLP(
        samples: [LabeledSample],
        sampleWeights: [Float]
    ) -> (W1: [Float], b1: [Float], W2: [Float], b2: [Float], H: Int) {
        let N = samples.count
        let D = samples[0].features.count
        let H = hp.hiddenDim
        let K = numClasses

        var X = [Float](repeating: 0, count: N * D)
        for (i, sample) in samples.enumerated() {
            for j in 0..<D { X[i * D + j] = sample.features[j] }
        }
        let y = samples.map(\.classIndex)
        var Y = [Float](repeating: 0, count: N * K)
        for (i, c) in y.enumerated() { Y[i * K + c] = 1 }

        var W1 = Self.initialHeWeights(inDim: D, outDim: H, seed: 1)
        var b1 = [Float](repeating: 0, count: H)
        var W2 = Self.initialHeWeights(inDim: H, outDim: K, seed: 2)
        var b2 = [Float](repeating: 0, count: K)

        var pre1  = [Float](repeating: 0, count: N * H)
        var hAct  = [Float](repeating: 0, count: N * H)
        var probs = [Float](repeating: 0, count: N * K)
        var dPre1 = [Float](repeating: 0, count: N * H)
        var dH    = [Float](repeating: 0, count: N * H)
        var dW1   = [Float](repeating: 0, count: D * H)
        var dB1   = [Float](repeating: 0, count: H)
        var dW2   = [Float](repeating: 0, count: H * K)
        var dB2   = [Float](repeating: 0, count: K)

        for _ in 0..<hp.iterations {
            forwardMLP(
                X: X,
                W1: W1, b1: b1,
                W2: W2, b2: b2,
                pre1: &pre1, hAct: &hAct, probs: &probs,
                N: N, D: D, H: H, K: K
            )

            var diff = probs
            vDSP.subtract(probs, Y, result: &diff)
            applySampleWeights(to: &diff, weights: sampleWeights, K: K)
            var invN = Float(1) / Float(N)
            vDSP_vsmul(diff, 1, &invN, &diff, 1, vDSP_Length(N * K))

            multiply(
                aT: true, a: hAct, aRows: N, aCols: H,
                bT: false, b: diff, bRows: N, bCols: K,
                out: &dW2
            )
            for k in 0..<K {
                var colSum: Float = 0
                for i in 0..<N { colSum += diff[i * K + k] }
                dB2[k] = colSum
            }

            multiply(
                aT: false, a: diff, aRows: N, aCols: K,
                bT: true, b: W2, bRows: H, bCols: K,
                out: &dH
            )
            for idx in 0..<(N * H) {
                dPre1[idx] = pre1[idx] > 0 ? dH[idx] : 0
            }
            multiply(
                aT: true, a: X, aRows: N, aCols: D,
                bT: false, b: dPre1, bRows: N, bCols: H,
                out: &dW1
            )
            for h in 0..<H {
                var colSum: Float = 0
                for i in 0..<N { colSum += dPre1[i * H + h] }
                dB1[h] = colSum
            }

            var lambda = hp.l2
            var two: Float = 2
            var l2scale = lambda * two
            vDSP_vsma(W1, 1, &l2scale, dW1, 1, &dW1, 1, vDSP_Length(D * H))
            vDSP_vsma(W2, 1, &l2scale, dW2, 1, &dW2, 1, vDSP_Length(H * K))

            var negLR = -hp.learningRate
            vDSP_vsma(dW1, 1, &negLR, W1, 1, &W1, 1, vDSP_Length(D * H))
            vDSP_vsma(dB1, 1, &negLR, b1, 1, &b1, 1, vDSP_Length(H))
            vDSP_vsma(dW2, 1, &negLR, W2, 1, &W2, 1, vDSP_Length(H * K))
            vDSP_vsma(dB2, 1, &negLR, b2, 1, &b2, 1, vDSP_Length(K))
        }

        return (W1, b1, W2, b2, H)
    }

    /// Argmax shortcut for one sample — returns the predicted class
    /// index (0…K-1). Runs the same two-layer forward as `predict`
    /// but skips the softmax normaliser since argmax is invariant
    /// under monotonic transforms.
    private static func argmaxPrediction(
        vector: [Float],
        weights1: [Float], bias1: [Float],
        weights2: [Float], bias2: [Float],
        hiddenDim H: Int, numClasses K: Int
    ) -> Int {
        let D = vector.count
        // pre1 = x @ W1 + b1  →  [H]
        var pre1 = bias1
        cblas_sgemv(
            CblasRowMajor, CblasTrans,
            Int32(D), Int32(H),
            1, weights1, Int32(H),
            vector, 1,
            1, &pre1, 1
        )
        // hAct = ReLU(pre1)
        var hAct = [Float](repeating: 0, count: H)
        for i in 0..<H { hAct[i] = max(0, pre1[i]) }
        // logits = hAct @ W2 + b2  →  [K]
        var logits = bias2
        cblas_sgemv(
            CblasRowMajor, CblasTrans,
            Int32(H), Int32(K),
            1, weights2, Int32(K),
            hAct, 1,
            1, &logits, 1
        )
        var best: Float = -.greatestFiniteMagnitude
        var bestIdx = 0
        for k in 0..<K where logits[k] > best {
            best = logits[k]
            bestIdx = k
        }
        return bestIdx
    }

    /// Row-sum over truth + column-sum over predictions yield support,
    /// TP per class, FP per class, FN per class, then P/R/F1.
    private static func deriveClassMetrics(
        confusion: [Int], numClasses K: Int
    ) -> [ClassMetrics] {
        var metrics: [ClassMetrics] = []
        metrics.reserveCapacity(K)
        for c in 0..<K {
            let tp = confusion[c * K + c]
            var rowSum = 0
            var colSum = 0
            for k in 0..<K {
                rowSum += confusion[c * K + k]
                colSum += confusion[k * K + c]
            }
            let fp = colSum - tp
            let fn = rowSum - tp
            let precision: Float = (tp + fp) > 0 ? Float(tp) / Float(tp + fp) : 0
            let recall: Float    = (tp + fn) > 0 ? Float(tp) / Float(tp + fn) : 0
            let f1: Float        = (precision + recall) > 0
                ? 2 * precision * recall / (precision + recall)
                : 0
            metrics.append(
                ClassMetrics(
                    ratingClass: RatingClass(rawValue: c + 1) ?? .unrated,
                    support: rowSum,
                    precision: precision,
                    recall: recall,
                    f1: f1
                )
            )
        }
        return metrics
    }

    // MARK: - Prediction over the library

    /// Re-score every image the library currently holds after a
    /// training run. Called automatically from `train()`.
    private func recomputeAllPredictions() async {
        // Snapshot weights + version so the detached work doesn't
        // need MainActor access for them. If weightsVersion moves on
        // during the detached run (a fresh train() overlapped an
        // older restoreLatestModel() recompute, for instance), we
        // throw the result away — otherwise the older recompute
        // could overwrite the newer model's predictions with stale
        // scores and leave the matrix in a "the chip says 53% but
        // the badges match the 28% classifier" mismatch.
        let launchVersion = weightsVersion
        let W1snap = weights1
        let b1snap = bias1
        let W2snap = weights2
        let b2snap = bias2
        let dim = featureDim
        let H = hiddenDim
        let numClasses = self.numClasses

        let next = await Task.detached(priority: .utility) {
            () -> [Int64: Prediction] in
            let reader = Database.shared.reader
            let images = (try? reader.read { db in
                try ImageRecord.fetchAll(db)
            }) ?? []

            var next: [Int64: Prediction] = [:]
            for image in images {
                if Task.isCancelled { return next }
                guard let id = image.id,
                      let vector = FeatureVectorBuilder.vector(for: image),
                      vector.count == dim
                else { continue }
                if let prediction = Self.runPrediction(
                    vector: vector,
                    weights1: W1snap, bias1: b1snap,
                    weights2: W2snap, bias2: b2snap,
                    hiddenDim: H, numClasses: numClasses
                ) {
                    next[id] = prediction
                }
            }
            return next
        }.value

        // Only commit if no newer train / restore / clear replaced
        // the weights while this task was running.
        guard launchVersion == weightsVersion else { return }
        predictions = next
    }

    // MARK: - Accelerate helpers

    /// out ← X @ W + b (row-broadcast bias). Used for both layers
    /// inside `forwardMLP` — same shape math, just different dims.
    private func forwardLinear(
        X: [Float], W: [Float], b: [Float],
        out: inout [Float],
        N: Int, inDim: Int, outDim: Int
    ) {
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans,
            Int32(N), Int32(outDim), Int32(inDim),
            1, X, Int32(inDim),
            W, Int32(outDim),
            0, &out, Int32(outDim)
        )
        for i in 0..<N {
            for k in 0..<outDim {
                out[i * outDim + k] += b[k]
            }
        }
    }

    /// Full forward pass for the two-layer MLP, reusing caller-owned
    /// buffers so the GD loop doesn't allocate per iteration.
    private func forwardMLP(
        X: [Float],
        W1: [Float], b1: [Float],
        W2: [Float], b2: [Float],
        pre1: inout [Float], hAct: inout [Float], probs: inout [Float],
        N: Int, D: Int, H: Int, K: Int
    ) {
        // pre1 = X @ W1 + b1  →  [N × H]
        forwardLinear(X: X, W: W1, b: b1, out: &pre1, N: N, inDim: D, outDim: H)
        // hAct = ReLU(pre1)
        for i in 0..<(N * H) { hAct[i] = max(0, pre1[i]) }
        // probs = hAct @ W2 + b2  →  [N × K]
        forwardLinear(X: hAct, W: W2, b: b2, out: &probs, N: N, inDim: H, outDim: K)
        softmaxInPlace(&probs, N: N, K: K)
    }

    /// He-uniform init for a Dense layer: ±sqrt(6 / inDim). Feeds a
    /// ReLU or softmax downstream; values stay in a narrow range so
    /// the first forward pass doesn't explode at high inDim (our D =
    /// 782 input dim makes zero-init unusable — the hidden layer
    /// would dead-ReLU on iteration one).
    ///
    /// Deterministic xorshift seeded per layer (1 and 2) so two
    /// identical train() calls produce identical weights → the CV
    /// accuracy number is stable across re-trains on the same data.
    nonisolated private static func initialHeWeights(
        inDim: Int, outDim: Int, seed: UInt64
    ) -> [Float] {
        let limit = sqrtf(6.0 / Float(inDim))
        var rng: UInt64 = seed &* 0x9E37_79B9_7F4A_7C15
        var out = [Float](repeating: 0, count: inDim * outDim)
        for i in 0..<out.count {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            // Map 64-bit → [-1, 1] uniform.
            let uniform01 = Float(rng >> 11) / Float(UInt64(1) << 53)
            out[i] = (uniform01 * 2 - 1) * limit
        }
        return out
    }

    /// out ← softmax(out) row-wise with numerical stabilisation.
    private func softmaxInPlace(
        _ out: inout [Float], N: Int, K: Int
    ) {
        for i in 0..<N {
            let rowStart = i * K
            var rowMax: Float = -.greatestFiniteMagnitude
            for k in 0..<K where out[rowStart + k] > rowMax {
                rowMax = out[rowStart + k]
            }
            var sum: Float = 0
            for k in 0..<K {
                let e = expf(out[rowStart + k] - rowMax)
                out[rowStart + k] = e
                sum += e
            }
            if sum > 0 {
                let inv = 1 / sum
                for k in 0..<K { out[rowStart + k] *= inv }
            }
        }
    }

    private func applySampleWeights(
        to diff: inout [Float], weights: [Float], K: Int
    ) {
        for (i, w) in weights.enumerated() {
            let start = i * K
            for k in 0..<K { diff[start + k] *= w }
        }
    }

    private func multiply(
        aT: Bool, a: [Float], aRows: Int, aCols: Int,
        bT: Bool, b: [Float], bRows: Int, bCols: Int,
        out: inout [Float]
    ) {
        let opA: CBLAS_TRANSPOSE = aT ? CblasTrans : CblasNoTrans
        let opB: CBLAS_TRANSPOSE = bT ? CblasTrans : CblasNoTrans
        let m = aT ? aCols : aRows
        let k = aT ? aRows : aCols
        let n = bT ? bRows : bCols
        cblas_sgemm(
            CblasRowMajor, opA, opB,
            Int32(m), Int32(n), Int32(k),
            1, a, Int32(aCols),
            b, Int32(bCols),
            0, &out, Int32(n)
        )
    }

    private func crossEntropyLoss(
        probs: [Float], y: [Int], weights: [Float]
    ) -> Float {
        var sum: Float = 0
        let K = numClasses
        for (i, c) in y.enumerated() {
            let p = max(probs[i * K + c], 1e-7)
            sum += -weights[i] * logf(p)
        }
        return sum / Float(y.count)
    }

    // MARK: - Static per-sample prediction

    /// Pure, actor-free per-sample softmax + argmax. Runs on whichever
    /// executor called it — including a `Task.detached` from the
    /// batch re-score path.
    nonisolated private static func runPrediction(
        vector: [Float],
        weights1: [Float], bias1: [Float],
        weights2: [Float], bias2: [Float],
        hiddenDim H: Int, numClasses: Int
    ) -> Prediction? {
        let D = vector.count
        guard weights1.count == D * H, bias1.count == H,
              weights2.count == H * numClasses, bias2.count == numClasses
        else { return nil }

        // pre1 = x @ W1 + b1
        var pre1 = bias1
        cblas_sgemv(
            CblasRowMajor, CblasTrans,
            Int32(D), Int32(H),
            1, weights1, Int32(H),
            vector, 1,
            1, &pre1, 1
        )
        // hAct = ReLU(pre1)
        var hAct = [Float](repeating: 0, count: H)
        for i in 0..<H { hAct[i] = max(0, pre1[i]) }

        // logits = hAct @ W2 + b2
        var logits = bias2
        cblas_sgemv(
            CblasRowMajor, CblasTrans,
            Int32(H), Int32(numClasses),
            1, weights2, Int32(numClasses),
            hAct, 1,
            1, &logits, 1
        )

        // Softmax with row-max subtraction for stability.
        var rowMax: Float = -.greatestFiniteMagnitude
        for k in 0..<numClasses where logits[k] > rowMax { rowMax = logits[k] }
        var sum: Float = 0
        for k in 0..<numClasses {
            let e = expf(logits[k] - rowMax)
            logits[k] = e
            sum += e
        }
        if sum > 0 {
            let inv = 1 / sum
            for k in 0..<numClasses { logits[k] *= inv }
        }

        var bestProb: Float = -1
        var bestIdx = 0
        for k in 0..<numClasses where logits[k] > bestProb {
            bestProb = logits[k]
            bestIdx = k
        }

        let topRaw = bestIdx + 1
        guard let topClass = RatingClass(rawValue: topRaw) else { return nil }
        return Prediction(
            probabilities: logits,
            topClass: topClass,
            topProbability: bestProb
        )
    }

    // MARK: - Persistence

    /// Compact little-endian blob header — version 2 (MLP):
    /// 4 bytes magic, 1 byte format version, 3 bytes reserved,
    /// Int32 featureDim, Int32 hiddenDim, Int32 numClasses, then:
    ///   - W1  (featureDim × hiddenDim)  Float32 row-major
    ///   - b1  (hiddenDim)               Float32
    ///   - W2  (hiddenDim × numClasses)  Float32 row-major
    ///   - b2  (numClasses)              Float32
    ///
    /// Version 1 was the linear logreg layout (no hiddenDim, just
    /// W[D×K] + b[K]). The v2 decoder rejects v1 blobs so restoring
    /// an older model after 0.5.0 leaves the classifier untrained —
    /// the user retrains. Unavoidable because v1 lacked the hidden
    /// layer entirely; no sensible upgrade path exists.
    private static let weightsMagic: [UInt8] = [0x43, 0x4D, 0x4C, 0x57] // "CMLW"
    private static let weightsFormatVersion: UInt8 = 2
    private static let weightsHeaderSize = 20

    /// Persist the freshly-trained weights as a new `model_versions`
    /// row. Called from `train()` after `summary` is set so the stored
    /// row carries the exact CV accuracy the UI surfaces. Skipped when
    /// the in-memory state is empty (guard against a race where
    /// training failed mid-way).
    private func persistTrainedModel() async {
        guard !weights1.isEmpty, !bias1.isEmpty,
              !weights2.isEmpty, !bias2.isEmpty,
              featureDim > 0, hiddenDim > 0,
              let summary else { return }

        let blob = Self.encodeWeights(
            featureDim: featureDim,
            hiddenDim: hiddenDim,
            numClasses: numClasses,
            weights1: weights1, bias1: bias1,
            weights2: weights2, bias2: bias2
        )

        // Version string: ISO-8601 to second precision + millisecond
        // counter + sample count. The millisecond tail protects
        // against two trains in the same second colliding on the
        // UNIQUE primary key and silently dropping the newer row
        // (PersistableRecord.insert throws, the catch block below
        // swallows it, restore later loads the stale snapshot).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let millis = Int((summary.trainedAt.timeIntervalSince1970 * 1000)
                         .truncatingRemainder(dividingBy: 1000))
        let versionString = String(
            format: "v%@-%03d-%d",
            formatter.string(from: summary.trainedAt),
            millis,
            summary.sampleCount
        )

        // Stash trainAccuracy + duration in the `notes` JSON so the
        // restore path can rehydrate a usable summary without
        // needing a schema migration. Keeping it optional so older
        // rows (notes=nil) still decode cleanly.
        let extras: [String: Double] = [
            "trainAccuracy": Double(summary.trainAccuracy),
            "durationSeconds": summary.durationSeconds
        ]
        let notes = (try? JSONSerialization.data(
            withJSONObject: extras, options: []
        )).flatMap { String(data: $0, encoding: .utf8) }

        let record = ModelVersionRecord(
            version: versionString,
            trainedAt: summary.trainedAt,
            trainingSetSize: summary.sampleCount,
            classCounts: summary.classCounts,
            classifierType: .mlp2,
            classifierWeights: blob,
            accuracy5FoldCV: summary.cvAccuracy.map(Double.init),
            notes: notes
        )

        do {
            try await Database.shared.writer.write { db in
                try record.insert(db)
            }
        } catch {
            // Non-fatal: the in-memory model still works for this
            // session, the user just loses the restored-on-launch
            // benefit. Surface nothing noisy — error chip is reserved
            // for training failures.
        }
    }

    /// Serialize the four MLP parameter tensors into the
    /// `CMLW v2` blob format.
    static func encodeWeights(
        featureDim: Int, hiddenDim: Int, numClasses: Int,
        weights1: [Float], bias1: [Float],
        weights2: [Float], bias2: [Float]
    ) -> Data {
        var data = Data()
        let bodyFloatCount =
            weights1.count + bias1.count + weights2.count + bias2.count
        data.reserveCapacity(weightsHeaderSize + bodyFloatCount * 4)
        data.append(contentsOf: weightsMagic)
        data.append(weightsFormatVersion)
        data.append(contentsOf: [0, 0, 0])          // reserved
        var fd = Int32(featureDim).littleEndian
        var hd = Int32(hiddenDim).littleEndian
        var nc = Int32(numClasses).littleEndian
        withUnsafeBytes(of: &fd) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &hd) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &nc) { data.append(contentsOf: $0) }
        for array in [weights1, bias1, weights2, bias2] {
            array.withUnsafeBufferPointer { buf in
                data.append(UnsafeBufferPointer(
                    start: buf.baseAddress, count: buf.count
                ))
            }
        }
        return data
    }

    /// Decode a `CMLW v2` blob. Returns `nil` on magic mismatch,
    /// version mismatch (v1 logreg is rejected), or any trailing
    /// bytes that don't match the declared featureDim × hiddenDim ×
    /// numClasses layout.
    static func decodeWeights(_ data: Data) -> (
        featureDim: Int, hiddenDim: Int, numClasses: Int,
        weights1: [Float], bias1: [Float],
        weights2: [Float], bias2: [Float]
    )? {
        guard data.count >= weightsHeaderSize else { return nil }
        let magic = Array(data.prefix(4))
        guard magic == weightsMagic else { return nil }
        guard data[4] == weightsFormatVersion else { return nil }

        let fd = data.subdata(in: 8..<12).withUnsafeBytes {
            Int32(littleEndian: $0.load(as: Int32.self))
        }
        let hd = data.subdata(in: 12..<16).withUnsafeBytes {
            Int32(littleEndian: $0.load(as: Int32.self))
        }
        let nc = data.subdata(in: 16..<20).withUnsafeBytes {
            Int32(littleEndian: $0.load(as: Int32.self))
        }
        let featureDim = Int(fd)
        let hiddenDim = Int(hd)
        let numClasses = Int(nc)
        guard featureDim > 0, hiddenDim > 0, numClasses > 0 else {
            return nil
        }

        let w1Count = featureDim * hiddenDim
        let b1Count = hiddenDim
        let w2Count = hiddenDim * numClasses
        let b2Count = numClasses
        let expectedSize =
            weightsHeaderSize + (w1Count + b1Count + w2Count + b2Count) * 4
        guard data.count == expectedSize else { return nil }

        func readFloats(from start: Int, count: Int) -> [Float] {
            data.subdata(in: start..<(start + count * 4))
                .withUnsafeBytes { raw -> [Float] in
                    let buf = raw.bindMemory(to: Float.self)
                    return Array(buf)
                }
        }

        var cursor = weightsHeaderSize
        let weights1 = readFloats(from: cursor, count: w1Count)
        cursor += w1Count * 4
        let bias1 = readFloats(from: cursor, count: b1Count)
        cursor += b1Count * 4
        let weights2 = readFloats(from: cursor, count: w2Count)
        cursor += w2Count * 4
        let bias2 = readFloats(from: cursor, count: b2Count)

        return (featureDim, hiddenDim, numClasses,
                weights1, bias1, weights2, bias2)
    }
}
