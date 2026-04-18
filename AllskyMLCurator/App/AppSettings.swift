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

    // MARK: - Synology mount

    /// Absolute path of the SMB mount where the allsky images live.
    /// The app rewrites `/volume1/…` paths from Supabase to this prefix.
    var allskyMountPath: String {
        get { defaults.string(forKey: Key.allskyMount) ?? "/Volumes/AllSky-Rheine" }
        set { defaults.set(newValue, forKey: Key.allskyMount) }
    }

    /// NAS-side path prefix that Supabase stores. Paths are rewritten by
    /// replacing this prefix with `allskyMountPath` on ingest.
    var nasPathPrefix: String {
        get { defaults.string(forKey: Key.nasPrefix) ?? "/volume1/AllSky-Rheine" }
        set { defaults.set(newValue, forKey: Key.nasPrefix) }
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
        static let allskyMount = "mount.allskyPath"
        static let nasPrefix = "mount.nasPrefix"
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
