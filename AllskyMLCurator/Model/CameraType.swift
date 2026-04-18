import Foundation

/// The two physical sensor categories the curator cares about.
///
/// Color cameras (OSC) produce usable frames day and night — the
/// classifier sees both twilight glow and nightsky. Monochrome cameras
/// (ZWO ASI290 in the Rheine setup) only expose night, so any frame
/// captured while the sun is above the horizon is flagged
/// `is_excluded` on ingest and never enters the training set.
///
/// Keeping this deliberately tiny: a richer `CameraProfile` concept
/// with fisheye geometry / overlay rectangles / orientation was tried
/// earlier but was premature — those belong in Phase 2 when they're
/// actually used, and for FITS the camera metadata is already
/// available from the file header.
enum CameraType: String, Codable, CaseIterable, Sendable {
    case color      = "color"
    case monochrome = "mono"

    var displayName: String {
        switch self {
        case .color:      return "Color (OSC)"
        case .monochrome: return "Monochrome"
        }
    }

    var dayCapable: Bool {
        switch self {
        case .color:      return true
        case .monochrome: return false
        }
    }

    /// Sun altitude above which a non-day-capable camera's frames are
    /// considered garbage and excluded from the training set.
    var dayExclusionSunAltDeg: Double { -6.0 }

    /// True when a frame captured at the given sun altitude should be
    /// excluded for this camera type.
    func isExcludedAtSunAlt(_ sunAltDeg: Double) -> Bool {
        !dayCapable && sunAltDeg > dayExclusionSunAltDeg
    }

    /// Map `(type, file extension)` to the concrete `ImageRecord.CameraSource`
    /// used on disk rows.
    func cameraSource(for fileExtension: String) -> ImageRecord.CameraSource? {
        let ext = fileExtension.lowercased()
        switch (self, ext) {
        case (.color, "jpg"), (.color, "jpeg"):
            return .colorAllskyJpg
        case (.monochrome, "jpg"), (.monochrome, "jpeg"):
            return .monoZwoJpg
        case (.monochrome, "fit"), (.monochrome, "fits"):
            return .monoZwoFits
        default:
            return nil
        }
    }
}
