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
/// The weights aren't persisted across launches yet — Phase 5c will
/// add that to `model_versions`. For now retraining is cheap enough
/// that a fresh boot simply retrains on demand.
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
        var durationSeconds: Double
    }

    enum TrainingError: Error, LocalizedError {
        case noLabeledFrames
        case noEmbeddingsAvailable
        case insufficientClasses(classesSeen: Int)

        var errorDescription: String? {
            switch self {
            case .noLabeledFrames:
                return "No human-rated frames yet — rate at least a handful across a couple of classes first."
            case .noEmbeddingsAvailable:
                return "No cached embeddings — scroll the matrix so the embedding generator has a chance to warm up, then retrain."
            case .insufficientClasses(let n):
                return "Only \(n) distinct classes have been rated so far. The classifier needs at least 2."
            }
        }
    }

    // MARK: - Observable state

    @Published private(set) var summary: TrainingSummary?
    @Published private(set) var isTraining: Bool = false
    @Published private(set) var lastError: String?
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
            let samples = try await loadTrainingSet()

            var classCounts = [Int](repeating: 0, count: numClasses)
            for sample in samples { classCounts[sample.classIndex] += 1 }

            let distinctClasses = classCounts.filter { $0 > 0 }.count
            guard distinctClasses >= 2 else {
                throw TrainingError.insufficientClasses(classesSeen: distinctClasses)
            }

            let weightsPerSample = sampleWeights(
                classCounts: classCounts,
                samples: samples
            )

            let (finalLoss, trainAccuracy) = runGradientDescent(
                samples: samples,
                sampleWeights: weightsPerSample
            )

            let duration = Date().timeIntervalSince(started)

            summary = TrainingSummary(
                trainedAt: Date(),
                sampleCount: samples.count,
                classCounts: classCounts,
                finalLoss: finalLoss,
                trainAccuracy: trainAccuracy,
                durationSeconds: duration
            )

            await recomputeAllPredictions()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
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

    // MARK: - Data loading

    private struct LabeledSample: Sendable {
        let imageId: Int64
        let features: [Float]
        let classIndex: Int   // 0…4 → RatingClass 1…5
    }

    /// Read every rated image that has a cached embedding, build its
    /// feature vector, and return the aligned (features, class) pairs.
    private func loadTrainingSet() async throws -> [LabeledSample] {
        let reader = Database.shared.reader
        let images = try await reader.read { db -> [ImageRecord] in
            let ratedImageIds = try LabelRecord
                .filter(Column("isCurrent") == true)
                .filter(Column("source") == "human")
                .filter(Column("ratingClass") != RatingClass.unrated.rawValue)
                .select(Column("imageId"), as: Int64.self)
                .fetchAll(db)
            guard !ratedImageIds.isEmpty else { return [] }
            return try ImageRecord
                .filter(ratedImageIds.contains(Column("id")))
                .fetchAll(db)
        }

        guard !images.isEmpty else { throw TrainingError.noLabeledFrames }

        let imageByIdPairs: [(Int64, ImageRecord)] = images.compactMap { img in
            img.id.map { ($0, img) }
        }
        let imageById = Dictionary(uniqueKeysWithValues: imageByIdPairs)
        let imageIds = imageByIdPairs.map(\.0)

        let labels = try await reader.read { db in
            try LabelRecord
                .filter(imageIds.contains(Column("imageId")))
                .filter(Column("isCurrent") == true)
                .filter(Column("source") == "human")
                .fetchAll(db)
        }

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
                    classIndex: label.ratingClass.rawValue - 1   // 1…5 → 0…4
                )
            )
        }

        guard !samples.isEmpty else { throw TrainingError.noEmbeddingsAvailable }
        featureDim = samples[0].features.count
        return samples
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

        return samples.map { classWeights[$0.classIndex] }
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
}
