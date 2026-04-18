import Accelerate
import Foundation
import GRDB

/// Multi-class logistic-regression head that sits on top of the
/// Vision FeaturePrint embeddings. Deliberately simple — 5 output
/// classes (RatingClass 1…5), full-batch gradient descent via
/// Accelerate matmul, in-memory weights. No mini-batching, no
/// momentum; at the curator's scale (≤ a few thousand human labels)
/// convergence happens in a fraction of a second.
///
/// Training / prediction pipeline:
///
///   1. `train()` loads every image with a current human label,
///      reads cached embeddings, builds feature vectors, applies
///      inverse-frequency class weights with an extra boost for the
///      rare clear-sky classes (4 & 5), runs ~200 iterations of
///      softmax-cross-entropy GD, and stores the resulting weights.
///   2. `predict(image:)` rebuilds the feature vector for one frame
///      and returns per-class probabilities + the top pick.
///
/// Every successful `train()` snapshot is persisted to the local
/// `model_versions` table (row keyed by a timestamped version string);
/// on app launch `restoreLatestModel()` rehydrates the most recent row
/// so predictions are warm immediately without a fresh retrain. The
/// blob format is a compact little-endian dump — magic, featureDim,
/// numClasses, weights, bias — decoded in `decodeWeights(_:)`.
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
        var iterations: Int = 200
        var learningRate: Float = 0.05
        var l2: Float = 5e-4
        var clearClassBoost: Float = 3.0
    }

    private let hp = Hyperparameters()
    private let numClasses = 5    // RatingClass 1…5

    /// Trained parameters: row-major W [numFeatures × numClasses] and
    /// bias [numClasses].
    private var weights: [Float] = []
    private var bias: [Float] = []
    private var featureDim: Int = 0

    // MARK: - Public API

    /// Train on every current human label (skipping 'auto' rows per
    /// plan section 7.F6 — those are provisional). The caller should
    /// debounce rapid label commits if needed.
    func train() async {
        guard !isTraining else { return }
        isTraining = true
        lastError = nil
        defer { isTraining = false }

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
            // Either an older blob shape from a previous dev build or a
            // corrupt row. Leaving the in-memory state untrained means
            // the toolbar chip will still report "untrained" — the
            // curator can retrain with ⌘T.
            return
        }
        weights = decoded.weights
        bias = decoded.bias
        featureDim = decoded.featureDim

        summary = TrainingSummary(
            trainedAt: row.trainedAt,
            sampleCount: row.trainingSetSize,
            classCounts: row.classCounts,
            finalLoss: 0,           // not persisted
            trainAccuracy: 0,       // not persisted
            cvAccuracy: row.accuracy5FoldCV.map(Float.init),
            confusionMatrix: nil,   // not persisted
            classMetrics: nil,      // not persisted
            durationSeconds: 0
        )

        await recomputeAllPredictions()
    }

    /// Predict for a single image. Returns `nil` when the classifier
    /// has not been trained yet, or when no cached embedding exists.
    func predict(image: ImageRecord) -> Prediction? {
        guard !weights.isEmpty, featureDim > 0 else { return nil }
        guard let vector = FeatureVectorBuilder.vector(for: image),
              vector.count == featureDim else { return nil }
        return Self.runPrediction(
            vector: vector,
            weights: weights,
            bias: bias,
            numClasses: numClasses
        )
    }

    /// Clear in-memory model + predictions. Useful when the user
    /// wants to reset before a fresh train.
    func clear() {
        weights = []
        bias = []
        featureDim = 0
        summary = nil
        predictions = [:]
    }

    /// Recompute the coverage snapshot without actually training.
    /// Powers the toolbar chip's status line so the user sees
    /// "X of Y rated, classes {1: 822}" before they even hit Train.
    func refreshCoverage() async {
        do {
            let diag = try await loadTrainingSet()
            var counts = [Int](repeating: 0, count: numClasses)
            for sample in diag.samples { counts[sample.classIndex] += 1 }
            lastCoverage = TrainingCoverage(
                totalRated: diag.totalRated,
                withEmbedding: diag.samples.count,
                classCounts: counts
            )
        } catch TrainingError.noLabeledFrames {
            lastCoverage = TrainingCoverage(
                totalRated: 0, withEmbedding: 0,
                classCounts: [Int](repeating: 0, count: numClasses)
            )
        } catch {
            // Silent — we don't want refresh failures to surface as
            // a red error line in the toolbar on every app launch.
        }
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
        // Inverse-frequency weights with an extra "clear-sky" boost on
        // classes 4 and 5 (indices 3 and 4) — Rheine nights are
        // dominantly cloudy, rare samples mustn't drown.
        let total = Float(samples.count)
        var classWeights = [Float](repeating: 1, count: numClasses)
        for c in 0..<numClasses where classCounts[c] > 0 {
            let invFreq = total / Float(classCounts[c] * numClasses)
            let boost: Float = (c >= 3) ? hp.clearClassBoost : 1.0
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

    /// Full-batch softmax cross-entropy gradient descent. Returns the
    /// final loss + training-set accuracy for the summary row.
    private func runGradientDescent(
        samples: [LabeledSample],
        sampleWeights: [Float]
    ) -> (loss: Float, accuracy: Float) {
        let N = samples.count
        let D = samples[0].features.count
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

        // Initialise to zeros.
        weights = [Float](repeating: 0, count: D * K)
        bias    = [Float](repeating: 0, count: K)

        var probs = [Float](repeating: 0, count: N * K)
        var gradW = [Float](repeating: 0, count: D * K)
        var gradB = [Float](repeating: 0, count: K)
        var finalLoss: Float = 0

        for _ in 0..<hp.iterations {
            // logits = X @ W + b
            forwardLogits(
                X: X, W: weights, b: bias,
                out: &probs, N: N, D: D, K: K
            )
            softmaxInPlace(&probs, N: N, K: K)

            // Gradient of softmax-CE w.r.t. logits is (P - Y) / N,
            // scaled by per-sample weight.
            var diff = probs
            vDSP.subtract(probs, Y, result: &diff)
            applySampleWeights(to: &diff, weights: sampleWeights, K: K)
            var scale = Float(1) / Float(N)
            vDSP_vsmul(diff, 1, &scale, &diff, 1, vDSP_Length(N * K))

            // gradW = X^T @ diff  →  [D × K]
            multiply(
                aT: true, a: X, aRows: N, aCols: D,
                bT: false, b: diff, bRows: N, bCols: K,
                out: &gradW
            )
            // L2 regularisation on W.
            var lambda = hp.l2
            var two: Float = 2
            var scaleWtoGrad = lambda * two
            vDSP_vsma(
                weights, 1, &scaleWtoGrad, gradW, 1, &gradW, 1,
                vDSP_Length(D * K)
            )

            // gradB = column sums of diff
            for k in 0..<K {
                var colSum: Float = 0
                for i in 0..<N { colSum += diff[i * K + k] }
                gradB[k] = colSum
            }

            // Update parameters: θ -= lr * grad
            var negLR = -hp.learningRate
            vDSP_vsma(
                gradW, 1, &negLR, weights, 1, &weights, 1,
                vDSP_Length(D * K)
            )
            vDSP_vsma(
                gradB, 1, &negLR, bias, 1, &bias, 1,
                vDSP_Length(K)
            )

            finalLoss = crossEntropyLoss(
                probs: probs, y: y, weights: sampleWeights
            )
        }

        // Training accuracy (unweighted).
        forwardLogits(
            X: X, W: weights, b: bias,
            out: &probs, N: N, D: D, K: K
        )
        softmaxInPlace(&probs, N: N, K: K)
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

            let (W, b) = fitLinearClassifier(
                samples: trainSamples, sampleWeights: trainWeights
            )

            for sample in testSamples {
                let predicted = Self.argmaxPrediction(
                    vector: sample.features,
                    weights: W, bias: b, numClasses: K
                )
                confusion[sample.classIndex * K + predicted] += 1
                if predicted == sample.classIndex { correct += 1 }
            }
        }

        let accuracy = Float(correct) / Float(n)
        return CVResult(accuracy: accuracy, confusion: confusion)
    }

    /// Extracted from runGradientDescent so the CV loop can call it
    /// without touching `self.weights` / `self.bias`. Same numerics —
    /// full-batch softmax-CE GD, L2 regularisation, per-sample weights.
    private func fitLinearClassifier(
        samples: [LabeledSample],
        sampleWeights: [Float]
    ) -> (weights: [Float], bias: [Float]) {
        let N = samples.count
        let D = samples[0].features.count
        let K = numClasses

        var X = [Float](repeating: 0, count: N * D)
        for (i, sample) in samples.enumerated() {
            for j in 0..<D { X[i * D + j] = sample.features[j] }
        }
        let y = samples.map(\.classIndex)
        var Y = [Float](repeating: 0, count: N * K)
        for (i, c) in y.enumerated() { Y[i * K + c] = 1 }

        var W = [Float](repeating: 0, count: D * K)
        var b = [Float](repeating: 0, count: K)
        var probs = [Float](repeating: 0, count: N * K)
        var gradW = [Float](repeating: 0, count: D * K)
        var gradB = [Float](repeating: 0, count: K)

        for _ in 0..<hp.iterations {
            forwardLogits(X: X, W: W, b: b, out: &probs, N: N, D: D, K: K)
            softmaxInPlace(&probs, N: N, K: K)

            var diff = probs
            vDSP.subtract(probs, Y, result: &diff)
            applySampleWeights(to: &diff, weights: sampleWeights, K: K)
            var scale = Float(1) / Float(N)
            vDSP_vsmul(diff, 1, &scale, &diff, 1, vDSP_Length(N * K))

            multiply(
                aT: true, a: X, aRows: N, aCols: D,
                bT: false, b: diff, bRows: N, bCols: K,
                out: &gradW
            )
            var lambda = hp.l2
            var two: Float = 2
            var scaleWtoGrad = lambda * two
            vDSP_vsma(
                W, 1, &scaleWtoGrad, gradW, 1, &gradW, 1,
                vDSP_Length(D * K)
            )

            for k in 0..<K {
                var colSum: Float = 0
                for i in 0..<N { colSum += diff[i * K + k] }
                gradB[k] = colSum
            }

            var negLR = -hp.learningRate
            vDSP_vsma(gradW, 1, &negLR, W, 1, &W, 1, vDSP_Length(D * K))
            vDSP_vsma(gradB, 1, &negLR, b, 1, &b, 1, vDSP_Length(K))
        }

        return (W, b)
    }

    /// Argmax shortcut — returns the predicted class index (0…K-1).
    private static func argmaxPrediction(
        vector: [Float],
        weights: [Float], bias: [Float], numClasses: Int
    ) -> Int {
        let D = vector.count
        var logits = bias
        cblas_sgemv(
            CblasRowMajor, CblasTrans,
            Int32(D), Int32(numClasses),
            1, weights, Int32(numClasses),
            vector, 1,
            1, &logits, 1
        )
        var best: Float = -.greatestFiniteMagnitude
        var bestIdx = 0
        for k in 0..<numClasses where logits[k] > best {
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
        let reader = Database.shared.reader
        let images = (try? await reader.read { db in
            try ImageRecord.fetchAll(db)
        }) ?? []

        var next: [Int64: Prediction] = [:]
        for image in images {
            guard let id = image.id,
                  let vector = FeatureVectorBuilder.vector(for: image),
                  vector.count == featureDim else { continue }
            if let prediction = Self.runPrediction(
                vector: vector,
                weights: weights,
                bias: bias,
                numClasses: numClasses
            ) {
                next[id] = prediction
            }
        }
        predictions = next
    }

    // MARK: - Accelerate helpers

    /// probs ← X @ W + b (row-broadcast bias).
    private func forwardLogits(
        X: [Float], W: [Float], b: [Float],
        out: inout [Float],
        N: Int, D: Int, K: Int
    ) {
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans,
            Int32(N), Int32(K), Int32(D),
            1, X, Int32(D),
            W, Int32(K),
            0, &out, Int32(K)
        )
        for i in 0..<N {
            for k in 0..<K {
                out[i * K + k] += b[k]
            }
        }
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

    private static func runPrediction(
        vector: [Float],
        weights: [Float],
        bias: [Float],
        numClasses: Int
    ) -> Prediction? {
        let D = vector.count
        guard weights.count == D * numClasses, bias.count == numClasses
        else { return nil }

        var logits = bias
        cblas_sgemv(
            CblasRowMajor, CblasTrans,
            Int32(D), Int32(numClasses),
            1, weights, Int32(numClasses),
            vector, 1,
            1, &logits, 1
        )

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

    /// Compact little-endian blob header: 4 bytes magic, 1 byte format
    /// version, 3 bytes reserved, Int32 featureDim, Int32 numClasses —
    /// then featureDim×numClasses row-major Float32 weights and
    /// numClasses Float32 biases.
    private static let weightsMagic: [UInt8] = [0x43, 0x4D, 0x4C, 0x57] // "CMLW"
    private static let weightsFormatVersion: UInt8 = 1
    private static let weightsHeaderSize = 16

    /// Persist the freshly-trained weights as a new `model_versions`
    /// row. Called from `train()` after `summary` is set so the stored
    /// row carries the exact CV accuracy the UI surfaces. Skipped when
    /// the in-memory state is empty (guard against a race where
    /// training failed mid-way).
    private func persistTrainedModel() async {
        guard !weights.isEmpty, !bias.isEmpty, featureDim > 0,
              let summary else { return }

        let blob = Self.encodeWeights(
            featureDim: featureDim,
            numClasses: numClasses,
            weights: weights,
            bias: bias
        )

        // Version string: ISO-8601 without separators + sample count —
        // chronologically sortable, unique across rapid consecutive
        // trains, and self-describing when scanning the table.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let versionString = "v\(formatter.string(from: summary.trainedAt))-\(summary.sampleCount)"

        let record = ModelVersionRecord(
            version: versionString,
            trainedAt: summary.trainedAt,
            trainingSetSize: summary.sampleCount,
            classCounts: summary.classCounts,
            classifierType: .logreg,
            classifierWeights: blob,
            accuracy5FoldCV: summary.cvAccuracy.map(Double.init),
            notes: nil
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

    /// Serialize weights + bias into the `CMLW v1` blob format.
    static func encodeWeights(
        featureDim: Int, numClasses: Int,
        weights: [Float], bias: [Float]
    ) -> Data {
        var data = Data()
        data.reserveCapacity(
            weightsHeaderSize + (weights.count + bias.count) * 4
        )
        data.append(contentsOf: weightsMagic)
        data.append(weightsFormatVersion)
        data.append(contentsOf: [0, 0, 0])          // reserved
        var fd = Int32(featureDim).littleEndian
        var nc = Int32(numClasses).littleEndian
        withUnsafeBytes(of: &fd) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &nc) { data.append(contentsOf: $0) }
        weights.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        bias.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        return data
    }

    /// Decode a `CMLW v1` blob. Returns `nil` on magic mismatch, size
    /// mismatch, or any trailing bytes that don't match the declared
    /// featureDim × numClasses layout.
    static func decodeWeights(_ data: Data) -> (
        featureDim: Int, numClasses: Int,
        weights: [Float], bias: [Float]
    )? {
        guard data.count >= weightsHeaderSize else { return nil }
        let magic = Array(data.prefix(4))
        guard magic == weightsMagic else { return nil }
        guard data[4] == weightsFormatVersion else { return nil }

        let fd = data.subdata(in: 8..<12).withUnsafeBytes {
            Int32(littleEndian: $0.load(as: Int32.self))
        }
        let nc = data.subdata(in: 12..<16).withUnsafeBytes {
            Int32(littleEndian: $0.load(as: Int32.self))
        }
        let featureDim = Int(fd)
        let numClasses = Int(nc)
        guard featureDim > 0, numClasses > 0 else { return nil }

        let weightsCount = featureDim * numClasses
        let biasCount = numClasses
        let expectedSize = weightsHeaderSize + (weightsCount + biasCount) * 4
        guard data.count == expectedSize else { return nil }

        let weightsStart = weightsHeaderSize
        let weightsEnd = weightsStart + weightsCount * 4
        let biasStart = weightsEnd
        let biasEnd = biasStart + biasCount * 4

        let weights = data.subdata(in: weightsStart..<weightsEnd).withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
        let bias = data.subdata(in: biasStart..<biasEnd).withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
        return (featureDim, numClasses, weights, bias)
    }
}
