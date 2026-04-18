import Foundation
import GRDB

/// A rating applied to an image. The active row for each image has
/// `isCurrent = true`; prior ratings stay in the DB with `isCurrent = false`
/// so a full label history is recoverable without deletions.
///
/// Reflection (`R`) and transitional (`T`) are orthogonal flags that
/// coexist with `class`. A "3 some clouds + moon reflex visible" label
/// stores class=3, reflectionFlag=true, transitionalFlag=false.
struct LabelRecord: Codable, Identifiable, Equatable, Sendable {

    var id: Int64?
    var imageId: Int64

    // MARK: - Rating payload

    var ratingClass: RatingClass
    var reflectionFlag: Bool
    var transitionalFlag: Bool

    // MARK: - Provenance

    var source: LabelSource
    var sampleWeight: Double   // 1.0 human · 0.5 transitional · 0.3 auto_confirmed
    var confidence: Int?       // 1 quick · 2 confident · 3 certain (optional)
    var annotatorId: String

    // MARK: - Timing and sync

    var labeledAt: Date
    var syncedToSupabase: Bool
    var isCurrent: Bool

    // MARK: - Factories

    /// Construct a pure-human label. `sampleWeight` is auto-set to 1.0
    /// unless `transitionalFlag` is true, in which case it drops to 0.5.
    static func human(
        imageId: Int64,
        ratingClass: RatingClass,
        reflection: Bool = false,
        transitional: Bool = false,
        confidence: Int? = nil,
        annotator: String = "joergsflow"
    ) -> LabelRecord {
        LabelRecord(
            id: nil,
            imageId: imageId,
            ratingClass: ratingClass,
            reflectionFlag: reflection,
            transitionalFlag: transitional,
            source: .human,
            sampleWeight: transitional ? 0.5 : 1.0,
            confidence: confidence,
            annotatorId: annotator,
            labeledAt: Date(),
            syncedToSupabase: false,
            isCurrent: true
        )
    }

    /// Construct a provisional label from the autonomous rater. These
    /// are never used in retrain — only `auto_confirmed` rows are.
    static func auto(
        imageId: Int64,
        ratingClass: RatingClass,
        reflection: Bool = false,
        annotator: String = "joergsflow"
    ) -> LabelRecord {
        LabelRecord(
            id: nil,
            imageId: imageId,
            ratingClass: ratingClass,
            reflectionFlag: reflection,
            transitionalFlag: false,
            source: .auto,
            sampleWeight: 0.0,
            confidence: nil,
            annotatorId: annotator,
            labeledAt: Date(),
            syncedToSupabase: false,
            isCurrent: true
        )
    }
}

// MARK: - GRDB persistence

extension LabelRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "labels"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
