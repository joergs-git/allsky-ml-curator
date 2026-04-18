import Foundation
import GRDB

/// One row per trained classifier snapshot. Weights are stored as a
/// serialized BNNS blob so the exact model can be restored without
/// re-training from scratch after relaunch.
struct ModelVersionRecord: Codable, Equatable, Sendable {

    /// `v0.YYYYMMDD-HHMM-N` format (`N` increments per session).
    var version: String
    var trainedAt: Date
    var trainingSetSize: Int
    /// Per-class sample counts in `RatingClass` order. Surfaced in the UI
    /// so the curator can see which labels are scarce and seek rare ones.
    var classCounts: [Int]
    var classifierType: ClassifierType
    var classifierWeights: Data
    var accuracy5FoldCV: Double?
    var notes: String?

    enum ClassifierType: String, Codable, Sendable {
        case logreg    = "logreg"
        case mlp2      = "mlp2"
    }
}

// MARK: - GRDB persistence

extension ModelVersionRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "model_versions"

    func encode(to container: inout PersistenceContainer) {
        container["version"] = version
        container["trainedAt"] = trainedAt
        container["trainingSetSize"] = trainingSetSize
        container["classCounts"] =
            try? JSONSerialization.data(withJSONObject: classCounts)
        container["classifierType"] = classifierType.rawValue
        container["classifierWeights"] = classifierWeights
        container["accuracy5FoldCV"] = accuracy5FoldCV
        container["notes"] = notes
    }
}
