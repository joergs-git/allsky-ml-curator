import Foundation

/// Loads `CameraProfile` JSON files shipped with the app.
///
/// For v1 the profiles are read straight from the bundle's
/// `CameraProfiles/` resource directory. A future revision will seed
/// `~/Library/Application Support/AllskyMLCurator/CameraProfiles/` on
/// first launch so the user can calibrate the fisheye geometry and
/// overlay masks per-site without touching the source tree.
final class CameraProfileStore {

    static let shared = CameraProfileStore()
    private init() { reload() }

    // MARK: - State

    private(set) var profiles: [String: CameraProfile] = [:]

    /// Ordered list of profile IDs in alphabetical order — good enough
    /// for a picker UI at this scale.
    var allIds: [String] { profiles.keys.sorted() }

    // MARK: - Access

    func profile(id: String) -> CameraProfile? {
        profiles[id]
    }

    /// Resolve the correct profile for a given `camera_source`. The
    /// mapping is a convention baked into the seed profiles — the color
    /// source maps to the `rheine_color_allsky_*` profile and the mono
    /// sources both use the ZWO profile.
    func profile(for cameraSource: ImageRecord.CameraSource) -> CameraProfile? {
        switch cameraSource {
        case .colorAllskyJpg:
            return profiles.values.first { $0.sensor.type == .color }
        case .monoZwoJpg, .monoZwoFits:
            return profiles.values.first { $0.sensor.type == .monochrome }
        }
    }

    // MARK: - Loading

    /// Re-read every profile from the bundle. Called at init and any
    /// time the user imports a new profile file in a future revision.
    func reload() {
        var loaded: [String: CameraProfile] = [:]
        for url in bundleProfileUrls() {
            do {
                let profile = try CameraProfile.load(from: url)
                loaded[profile.id] = profile
            } catch {
                NSLog("CameraProfileStore: failed to load \(url.lastPathComponent): \(error)")
            }
        }
        profiles = loaded
    }

    private func bundleProfileUrls() -> [URL] {
        // Camera profiles land at the bundle's Resources root after
        // XcodeGen flattens the `Preferences/CameraProfiles/` source path.
        // Filter by filename convention so unrelated JSONs (added for
        // other features later) are not mistaken for camera profiles.
        guard let all = Bundle.main.urls(
            forResourcesWithExtension: "json", subdirectory: nil
        ) else { return [] }
        return all.filter { url in
            let name = url.deletingPathExtension().lastPathComponent
            return name.contains("_color_") || name.contains("_mono_")
        }
    }
}
