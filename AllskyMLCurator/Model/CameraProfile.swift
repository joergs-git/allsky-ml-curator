import Foundation

/// A camera profile describes the geometry and overlay layout of one
/// physical allsky camera. Loaded from JSON in
/// `Preferences/CameraProfiles/*.json` and referenced by
/// `ImageRecord.cameraProfileId`.
///
/// The ingest pipeline uses `sensor.dayCapable` + `dayExclusionSunAltDeg`
/// to decide whether a mono-camera frame captured during daylight should
/// be flagged `isExcluded`. The `SkyDiskMask` module uses the fisheye +
/// overlay rectangles to produce the clean crop fed to the ML embedding
/// stage (the curator still sees the original, overlay-bearing thumbnail
/// in the UI).
struct CameraProfile: Codable, Equatable, Sendable {

    var id: String
    var displayName: String
    var site: Site
    var sensor: Sensor
    var fisheye: FisheyeGeometry
    var overlayMaskRectsPx: [OverlayRect]
    var orientation: Orientation
    var filePathPatterns: FilePathPatterns
    var stf: STFConfig?           // only relevant for FITS-mode profiles
    var calibration: Calibration
    var schemaVersion: Int

    // MARK: - Nested

    struct Site: Codable, Equatable, Sendable {
        var name: String
        var latitudeDeg: Double
        var longitudeDeg: Double
        var timezone: String
    }

    struct Sensor: Codable, Equatable, Sendable {
        var type: SensorType
        var description: String?
        var dayCapable: Bool
        /// Mono cameras only: frames with sun_alt above this value are
        /// pre-excluded from the training set on ingest.
        var dayExclusionSunAltDeg: Double?
        var pixelWidth: Int
        var pixelHeight: Int
        var bayerPattern: String?
        var bitDepth: Int
        var fileFormat: String

        enum SensorType: String, Codable, Sendable {
            case color      = "color"
            case monochrome = "monochrome"
        }
    }

    struct FisheyeGeometry: Codable, Equatable, Sendable {
        var centerXPx: Double
        var centerYPx: Double
        var radiusPx: Double
        /// Y-axis stretch ratio for non-circular fisheyes. 1.0 = circular.
        var ellipseRatio: Double
        /// `true` once the values have been measured on a real frame — the
        /// placeholder profiles ship with `false` so the ingest path can
        /// warn the user.
        var isCalibrated: Bool { radiusPx > 0 }
    }

    struct OverlayRect: Codable, Equatable, Sendable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        var isEmpty: Bool { width == 0 || height == 0 }
    }

    struct Orientation: Codable, Equatable, Sendable {
        /// Azimuth in degrees of the image's "up" direction (toward the top
        /// pixel edge from the fisheye center). Needed by the v2.0
        /// cloud-motion feature to translate pixel velocity to compass bearing.
        var northAzimuthDegAtPixelUp: Double
        /// Whether the camera image rotates clockwise around zenith as the
        /// compass bearing grows.
        var rotationClockwise: Bool
    }

    struct FilePathPatterns: Codable, Equatable, Sendable {
        var nasBase: String
        /// For color profile: single column name. For mono profile: list.
        var supabaseColumn: String?
        var supabaseColumns: [String]?
        var typicalSubdirectory: String?
    }

    struct STFConfig: Codable, Equatable, Sendable {
        var mode: String
        var shadowsClipSigma: Double
        var targetBackground: Double
    }

    struct Calibration: Codable, Equatable, Sendable {
        var calibratedAt: Date?
        var calibratedBy: String?
        var notes: String?
    }

    // MARK: - JSON coding

    enum CodingKeys: String, CodingKey {
        case id
        case displayName       = "display_name"
        case site
        case sensor
        case fisheye
        case overlayMaskRectsPx = "overlay_mask_rects_px"
        case orientation
        case filePathPatterns   = "file_path_patterns"
        case stf
        case calibration
        case schemaVersion      = "schema_version"
    }

    // MARK: - Loading

    /// Decode a profile from a JSON file on disk. Throws on malformed or
    /// missing data — no silent fallbacks, because a wrong profile would
    /// poison the ML pipeline.
    static func load(from url: URL) throws -> CameraProfile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CameraProfile.self, from: data)
    }
}

// MARK: - Ingest helpers

extension CameraProfile.Sensor {

    /// True when a frame captured at the given sun altitude must be
    /// flagged as excluded for this sensor (applies to mono cameras with
    /// a configured daylight cutoff).
    func isExcludedAtSunAlt(_ sunAltDeg: Double) -> Bool {
        guard !dayCapable, let cutoff = dayExclusionSunAltDeg else { return false }
        return sunAltDeg > cutoff
    }
}
