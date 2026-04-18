import Foundation
import GRDB

/// A model prediction for an image. UNIQUE (imageId, modelVersion) so
/// repeated predictions from the same model version overwrite cleanly.
///
/// Reflection probability and (v2.0) cloud-motion vector live on this
/// row so downstream consumers (AstroTriage, cloudwatcher-optimizer)
/// can read them without re-running the classifier.
struct PredictionRecord: Codable, Identifiable, Equatable, Sendable {

    var id: Int64?
    var imageId: Int64
    var modelVersion: String

    var predictedClass: RatingClass
    /// Per-class probabilities in `RatingClass` order (unrated…clear).
    /// Stored as JSON-encoded [Double] so GRDB can persist it as BLOB.
    var classProbabilities: [Double]
    var reflectionProb: Double

    /// v2.0 cloud-motion output — nil for v1 predictions.
    var motionVectorDegPerMin: Double?
    var motionAzimuthDeg: Double?

    var createdAt: Date

    /// Convenience: top-class confidence (0…1) used to gate autonomous mode.
    var topClassConfidence: Double {
        classProbabilities.max() ?? 0.0
    }
}

// MARK: - GRDB persistence

extension PredictionRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "predictions"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // classProbabilities is encoded as a JSON blob for SQLite storage.
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["imageId"] = imageId
        container["modelVersion"] = modelVersion
        container["predictedClass"] = predictedClass.rawValue
        container["classProbabilities"] =
            try? JSONSerialization.data(withJSONObject: classProbabilities)
        container["reflectionProb"] = reflectionProb
        container["motionVectorDegPerMin"] = motionVectorDegPerMin
        container["motionAzimuthDeg"] = motionAzimuthDeg
        container["createdAt"] = createdAt
    }
}
