import Foundation

/// User-facing app settings. Backed by `UserDefaults` for a v1 MVP; may
/// migrate to a GRDB-backed preferences table if the surface grows.
///
/// Defaults align with the Rheine observatory and the existing
/// `astro-weather` pipeline layout.
final class AppSettings {

    // MARK: - Singleton

    static let shared = AppSettings()
    private init() {}

    // MARK: - Observatory

    /// Geographic latitude in degrees, north positive. Default: Rheine.
    var latitudeDeg: Double {
        get { defaults.double(forKey: Key.latitude, default: 52.17) }
        set { defaults.set(newValue, forKey: Key.latitude) }
    }

    /// Geographic longitude in degrees, east positive. Default: Rheine.
    var longitudeDeg: Double {
        get { defaults.double(forKey: Key.longitude, default: 7.25) }
        set { defaults.set(newValue, forKey: Key.longitude) }
    }

    // MARK: - Last picked folder (for UI recall, no security-scoped bookmark yet)

    /// Path the user most recently ingested, shown as a breadcrumb in
    /// the main window. The actual access rights do not persist across
    /// app launches in v1 — the user picks the folder again each time
    /// (a security-scoped bookmark can be added in a later revision).
    var lastIngestedFolderPath: String? {
        get { defaults.string(forKey: Key.lastFolder) }
        set { defaults.set(newValue, forKey: Key.lastFolder) }
    }

    /// Last camera type the user selected for ingest (raw value of
    /// `CameraType`). Restored in the picker on relaunch so repeat
    /// ingest sessions don't have to re-pick.
    var lastCameraTypeRaw: String? {
        get { defaults.string(forKey: Key.lastCameraTypeRaw) }
        set { defaults.set(newValue, forKey: Key.lastCameraTypeRaw) }
    }

    // MARK: - Allsky fisheye geometry (per camera type)
    //
    // Used by the Phase-2 SkyDiskMask to crop the circular sky area
    // from a rectangular allsky frame before feeding it to the ML
    // embedding. The values are editable in Preferences → Camera so
    // they are never truly hardcoded — the numbers below only kick
    // in on first launch. Defaults are the user's Rheine rig:
    //   - Color (OSC):  ZWO ASI676MC, 3552×3552 sensor,
    //                   3200 px image circle, centered at (1776, 1776)
    //   - Monochrome:   SX CCD SuperStar, 1392×1040 sensor,
    //                   880 px image circle, centered at (696, 520)

    var colorFisheyeCenterXPx: Int {
        get { defaults.integer(forKey: Key.colorCenterX, default: 1776) }
        set { defaults.set(newValue, forKey: Key.colorCenterX) }
    }

    var colorFisheyeCenterYPx: Int {
        get { defaults.integer(forKey: Key.colorCenterY, default: 1776) }
        set { defaults.set(newValue, forKey: Key.colorCenterY) }
    }

    var colorFisheyeRadiusPx: Int {
        get { defaults.integer(forKey: Key.colorRadius, default: 1600) }
        set { defaults.set(newValue, forKey: Key.colorRadius) }
    }

    var monoFisheyeCenterXPx: Int {
        get { defaults.integer(forKey: Key.monoCenterX, default: 696) }
        set { defaults.set(newValue, forKey: Key.monoCenterX) }
    }

    var monoFisheyeCenterYPx: Int {
        get { defaults.integer(forKey: Key.monoCenterY, default: 520) }
        set { defaults.set(newValue, forKey: Key.monoCenterY) }
    }

    var monoFisheyeRadiusPx: Int {
        get { defaults.integer(forKey: Key.monoRadius, default: 440) }
        set { defaults.set(newValue, forKey: Key.monoRadius) }
    }

    // MARK: - Autonomous mode

    /// Minimum genuine human labels required before F10 autonomous mode
    /// may engage. Guards against early-stage confirmation bias.
    var autonomousMinLabels: Int {
        get { defaults.integer(forKey: Key.autonomousMin, default: 200) }
        set { defaults.set(newValue, forKey: Key.autonomousMin) }
    }

    /// Per-image top-class probability below which autonomous mode pauses
    /// for manual review. Range [0, 1].
    var autonomousConfidenceThreshold: Double {
        get { defaults.double(forKey: Key.autonomousConfidence, default: 0.6) }
        set { defaults.set(newValue, forKey: Key.autonomousConfidence) }
    }

    // MARK: - ML training

    /// Multiplicative boost applied to rare clear-sky classes (4 and 5)
    /// on top of inverse-frequency weighting.
    var clearClassBoost: Double {
        get { defaults.double(forKey: Key.clearBoost, default: 3.0) }
        set { defaults.set(newValue, forKey: Key.clearBoost) }
    }

    // MARK: - Appearance

    /// Red-on-black night mode for dark-adapted vision at the telescope.
    var nightMode: Bool {
        get { defaults.bool(forKey: Key.nightMode) }
        set { defaults.set(newValue, forKey: Key.nightMode) }
    }

    // MARK: - Storage

    private let defaults = UserDefaults.standard

    private enum Key {
        static let latitude = "observatory.latitudeDeg"
        static let longitude = "observatory.longitudeDeg"
        static let lastFolder = "ingest.lastFolderPath"
        static let lastCameraTypeRaw = "ingest.lastCameraTypeRaw"
        static let colorCenterX = "camera.color.centerXPx"
        static let colorCenterY = "camera.color.centerYPx"
        static let colorRadius  = "camera.color.radiusPx"
        static let monoCenterX  = "camera.mono.centerXPx"
        static let monoCenterY  = "camera.mono.centerYPx"
        static let monoRadius   = "camera.mono.radiusPx"
        static let autonomousMin = "autonomous.minLabels"
        static let autonomousConfidence = "autonomous.confidenceThreshold"
        static let clearBoost = "ml.clearClassBoost"
        static let nightMode = "appearance.nightMode"
    }
}

// MARK: - UserDefaults helpers with defaults

private extension UserDefaults {

    func double(forKey key: String, default defaultValue: Double) -> Double {
        object(forKey: key) == nil ? defaultValue : double(forKey: key)
    }

    func integer(forKey key: String, default defaultValue: Int) -> Int {
        object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }
}
