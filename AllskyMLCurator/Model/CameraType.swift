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

    /// 0.8.4: raw-value list of the `ImageRecord.CameraSource` cases
    /// that belong to this camera type. Used when a query needs to
    /// filter `images.cameraSource` by camera — a mono camera covers
    /// both `mono_allsky_jpg` and `mono_allsky_fits` on disk, so a
    /// single enum case isn't enough. Mirrors the private helper in
    /// `ImageLibrary.sources(for:)` and is exposed on the type so UI
    /// code can build WHERE-IN clauses without going through the
    /// library.
    var filePathCameraSources: [String] {
        switch self {
        case .color:
            return [ImageRecord.CameraSource.colorAllskyJpg.rawValue]
        case .monochrome:
            return [
                ImageRecord.CameraSource.monoAllskyJpg.rawValue,
                ImageRecord.CameraSource.monoAllskyFits.rawValue
            ]
        }
    }

    /// Map `(type, file extension)` to the concrete `ImageRecord.CameraSource`
    /// used on disk rows.
    func cameraSource(for fileExtension: String) -> ImageRecord.CameraSource? {
        let ext = fileExtension.lowercased()
        switch (self, ext) {
        case (.color, "jpg"), (.color, "jpeg"):
            return .colorAllskyJpg
        case (.color, "fit"), (.color, "fits"):
            // Color FITS lands on disk as a distinct raw-Bayer record
            // in Phase 1.1+. Until the FITS reader is ported the scan
            // filter also keeps these files out of the ingest set.
            return .colorAllskyJpg       // placeholder mapping for now
        case (.monochrome, "jpg"), (.monochrome, "jpeg"):
            return .monoAllskyJpg
        case (.monochrome, "fit"), (.monochrome, "fits"):
            return .monoAllskyFits
        default:
            return nil
        }
    }
}

/// Image encoding the user wants to ingest for a given run.
///
/// Raw FITS is strictly better for training — no burned-in text
/// overlay, 16-bit dynamic range, camera-native Bayer pattern. JPG
/// is convenient and works today; FITS needs the `cfitsio` bridge
/// that ships with Phase 1.1.
enum ImageFormat: String, CaseIterable, Sendable {
    case jpg  = "jpg"
    case fits = "fits"

    var displayName: String {
        switch self {
        case .jpg:  return "JPG"
        case .fits: return "FITS (raw — v1.1)"
        }
    }

    /// File extensions matched by this format during the scan.
    var extensions: Set<String> {
        switch self {
        case .jpg:  return ["jpg", "jpeg"]
        case .fits: return ["fit", "fits"]
        }
    }

    /// FITS loading is not wired up yet. The picker still shows it so
    /// users can choose the format they want and the scan filter
    /// honours it; actual embedding + thumbnailing for FITS arrives
    /// with the cfitsio bridge port.
    var isSupportedInCurrentBuild: Bool {
        switch self {
        case .jpg:  return true
        case .fits: return false
        }
    }
}
