import Foundation
import GRDB

/// A single allsky frame known to the app. One row per physical file
/// picked up during ingest. Ephemeris values are pre-computed on ingest
/// so queries, filters and the transitional / reflection detectors
/// never hit trigonometry at runtime.
struct ImageRecord: Codable, Identifiable, Equatable, Sendable {

    // MARK: - Identity

    var id: Int64?
    var filePath: String
    var fileHashSha256: String?
    var cameraSource: CameraSource

    // MARK: - Time

    /// UTC capture timestamp, parsed from filename during ingest
    /// (falls back to file modification date when nothing matches).
    var captureUtc: Date
    var timeOfDay: TimeOfDay

    // MARK: - Cross-reference

    /// FK into `cloudwatcher_readings.id` (astro-weather Supabase),
    /// filled when ingest can pair this frame with a weather reading
    /// within the configured time window.
    var supabaseReadingId: Int64?

    /// FK into `meteoblue_hourly.id` (astro-weather Supabase), filled
    /// when ingest finds a forecast hour within ±30 min of the frame.
    /// Drives the forecast-aux features in `FeatureVectorBuilder`.
    var meteoblueHourId: Int64?

    // MARK: - Ephemeris (sun / moon, body-agnostic)

    var sunAltDeg: Double
    var sunAzDeg: Double
    var moonAltDeg: Double
    var moonAzDeg: Double
    var moonPhase: Double   // 0.0 = new, 0.5 = full, 1.0 = next new

    // MARK: - Derived prefilter scores

    var reflectionRiskScore: Double      // 0 = none, 1 = strong risk
    var transitionalRiskScore: Double    // 0 = clean, 1 = gain-settling garbage

    /// True for mono-camera frames captured while the sun is above the
    /// profile's daylight cutoff. Such frames never enter the training set.
    var isExcluded: Bool

    // MARK: - Per-frame metadata (from the *_metadata.json sidecar)
    //
    // Populated during ingest when a sidecar is present. Unused when
    // FITS header parsing lands (v1.1) — the corresponding FITS
    // keywords will fill the same columns.

    var exposureSec: Double?
    var gain: Double?
    var sensorTempC: Double?
    /// `false` when the capture software's auto-exposure was still
    /// hunting for the ADU target. Materially more reliable as a
    /// "this frame is garbage" signal than the geometric sun-altitude
    /// window alone.
    var aeStable: Bool?

    // MARK: - Embedding cache

    var embeddingPath: String?
    var embeddingRevision: Int

    // MARK: - Meta

    var createdAt: Date

    // MARK: - Nested types

    enum CameraSource: String, Codable, Sendable {
        case colorAllskyJpg  = "color_allsky_jpg"
        case monoAllskyJpg   = "mono_allsky_jpg"
        case monoAllskyFits  = "mono_allsky_fits"

        /// Map back to the coarse two-bucket `CameraType` used in the UI.
        var cameraType: CameraType {
            switch self {
            case .colorAllskyJpg:                  return .color
            case .monoAllskyJpg, .monoAllskyFits:  return .monochrome
            }
        }
    }
}

// MARK: - GRDB persistence

extension ImageRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "images"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum Columns {
        static let id                    = Column(CodingKeys.id)
        static let filePath              = Column(CodingKeys.filePath)
        static let fileHashSha256        = Column(CodingKeys.fileHashSha256)
        static let cameraSource          = Column(CodingKeys.cameraSource)
        static let captureUtc            = Column(CodingKeys.captureUtc)
        static let timeOfDay             = Column(CodingKeys.timeOfDay)
        static let supabaseReadingId     = Column(CodingKeys.supabaseReadingId)
        static let meteoblueHourId       = Column(CodingKeys.meteoblueHourId)
        static let sunAltDeg             = Column(CodingKeys.sunAltDeg)
        static let sunAzDeg              = Column(CodingKeys.sunAzDeg)
        static let moonAltDeg            = Column(CodingKeys.moonAltDeg)
        static let moonAzDeg             = Column(CodingKeys.moonAzDeg)
        static let moonPhase             = Column(CodingKeys.moonPhase)
        static let reflectionRiskScore   = Column(CodingKeys.reflectionRiskScore)
        static let transitionalRiskScore = Column(CodingKeys.transitionalRiskScore)
        static let isExcluded            = Column(CodingKeys.isExcluded)
        static let embeddingPath         = Column(CodingKeys.embeddingPath)
        static let embeddingRevision     = Column(CodingKeys.embeddingRevision)
        static let createdAt             = Column(CodingKeys.createdAt)
    }
}
