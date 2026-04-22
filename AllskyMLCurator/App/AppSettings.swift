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

    /// Last image format selected (raw value of `ImageFormat`).
    var lastImageFormatRaw: String? {
        get { defaults.string(forKey: Key.lastImageFormatRaw) }
        set { defaults.set(newValue, forKey: Key.lastImageFormatRaw) }
    }

    /// Active camera filter in the main matrix view. `nil` means
    /// "show all cameras"; a raw value restricts to that `CameraType`.
    /// Default on first launch is `"color"` so the dominant OSC feed
    /// is isolated and monochrome frames don't muddy the grid until
    /// the user asks for them.
    var lastCameraFilterRaw: String? {
        get {
            if let stored = defaults.string(forKey: Key.lastCameraFilterRaw) {
                return stored.isEmpty ? nil : stored
            }
            return CameraType.color.rawValue
        }
        set {
            // Distinguish "explicitly set to All cameras" (empty
            // string sentinel) from "never set" (nil → default).
            if let new = newValue {
                defaults.set(new, forKey: Key.lastCameraFilterRaw)
            } else {
                defaults.set("", forKey: Key.lastCameraFilterRaw)
            }
        }
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

    // MARK: - Optical FoV + zenith-crop (dynamic per setup)
    //
    // Allsky frames cover the whole hemisphere but the horizon ring
    // is useless for astrophotography rating — below ~30° elevation
    // there is always scattered cloud, haze, light pollution, and
    // tree / building silhouette. Worse, it drags the rating label
    // away from what matters ("is the zenith clear?") toward "is the
    // far horizon clear?", which the curator can't control.
    //
    // The fix is a symmetric zenith crop applied to both the display
    // thumbnail and the ML embedding, so "what you see is what you
    // train on". The crop radius is computed from:
    //
    //   crop_fraction = (90° - horizon_exclusion°) / (fov° / 2)
    //
    // assuming an equidistant fisheye projection (angle from zenith
    // maps linearly to pixel radius, true to within a few percent on
    // most allsky lenses). Defaults exclude everything below 30°
    // elevation — for the ZWO ASI676MC (176° FoV) that yields
    // crop_fraction ≈ 0.68, for the SX SuperStar (112.5° FoV) the
    // full disk already fits above 33° elevation so the crop is a
    // no-op (clamped to 1.0).

    var colorFovDeg: Double {
        get { defaults.double(forKey: Key.colorFov, default: 176.0) }
        set { defaults.set(newValue, forKey: Key.colorFov) }
    }

    var monoFovDeg: Double {
        get { defaults.double(forKey: Key.monoFov, default: 112.5) }
        set { defaults.set(newValue, forKey: Key.monoFov) }
    }

    // MARK: - Camera orientation (compass calibration)
    //
    // One-time rotation offset per camera so that compass azimuth can
    // be translated back into a pixel direction on the fisheye image.
    // Zero means "true north is straight up in the frame" — the case
    // for a perfectly aligned rig. Any deviation from that is stored
    // in degrees: positive rotates clockwise (viewed as printed on
    // screen), so a value of 90° means north-up in the picture is
    // actually *east* on the compass (camera rotated 90° CCW).
    //
    // Unused by v1 ML features but captured here so the cloud-motion
    // detector (v2.0) has a per-camera compass reference without a
    // schema migration later. Users who haven't calibrated leave the
    // value at 0 — motion direction will then be expressed relative
    // to the frame, not to the compass.

    var colorNorthOffsetDeg: Double {
        get { defaults.double(forKey: Key.colorNorthOffset, default: 0.0) }
        set { defaults.set(newValue, forKey: Key.colorNorthOffset) }
    }

    var monoNorthOffsetDeg: Double {
        get { defaults.double(forKey: Key.monoNorthOffset, default: 0.0) }
        set { defaults.set(newValue, forKey: Key.monoNorthOffset) }
    }

    /// Elevation below which the horizon ring is masked out.
    /// 30° matches the threshold under which ground-based
    /// astrophotography usually doesn't even point.
    var horizonExclusionDeg: Double {
        get { defaults.double(forKey: Key.horizonExclusion, default: 30.0) }
        set { defaults.set(newValue, forKey: Key.horizonExclusion) }
    }

    /// Computed radius fraction for the zenith crop, per camera type.
    /// Returns 1.0 when the camera's FoV already tops out above the
    /// horizon-exclusion elevation — no crop needed.
    func zenithCropFraction(for cameraType: CameraType) -> Double {
        let fov: Double
        switch cameraType {
        case .color:      fov = colorFovDeg
        case .monochrome: fov = monoFovDeg
        }
        let halfFov = fov / 2.0
        let angleFromZenith = 90.0 - horizonExclusionDeg
        guard halfFov > 0 else { return 1.0 }
        return max(0.1, min(1.0, angleFromZenith / halfFov))
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

    /// Gradient-descent learning rate for the logistic-regression head.
    /// Larger values converge faster but overshoot; 0.05 is the v1 default.
    var trainingLearningRate: Double {
        get { defaults.double(forKey: Key.trainingLR, default: 0.05) }
        set { defaults.set(newValue, forKey: Key.trainingLR) }
    }

    /// Number of GD iterations per `train()` call. At Rheine's data
    /// scale 200 is usually enough; raising this helps when the loss
    /// hasn't flattened yet in the live status line.
    var trainingIterations: Int {
        get { defaults.integer(forKey: Key.trainingIter, default: 200) }
        set { defaults.set(newValue, forKey: Key.trainingIter) }
    }

    /// L2 regularisation strength. Nudges weights toward zero to keep
    /// the model honest on a small training set.
    var trainingL2: Double {
        get { defaults.double(forKey: Key.trainingL2, default: 5e-4) }
        set { defaults.set(newValue, forKey: Key.trainingL2) }
    }

    /// Night-only filter. When enabled, both the matrix view and the
    /// classifier's training set drop every frame whose `sun_alt_deg`
    /// is above `nightOnlySunAltMaxDeg` — i.e. dusk / day frames get
    /// hidden.
    ///
    /// Soft filter: the rows stay in SQLite and can be restored by
    /// flipping the toggle back off. No `is_excluded` bit is touched,
    /// so later we can spin up a **separate** day-classifier on the
    /// same dataset without a re-ingest.
    ///
    /// Reason: 0.5.2 hit a class-1 ↔ class-5 ceiling at ~50 % CV
    /// because bright overcast daytime frames look identical to
    /// bright clear daytime frames in Vision FeaturePrint space, and
    /// sun-reflection artefacts dominate any rating signal on the
    /// color camera at day. Training a night-only classifier removes
    /// that pollution at the cost of not predicting day frames at
    /// all — which is acceptable since AstroTriage only cares about
    /// night frames anyway.
    var nightOnlyMode: Bool {
        get { defaults.bool(forKey: Key.nightOnlyMode) }
        set { defaults.set(newValue, forKey: Key.nightOnlyMode) }
    }

    /// Sun altitude threshold for night-only mode. Frames with
    /// `sun_alt_deg > nightOnlySunAltMaxDeg` are hidden when the mode
    /// is on. Standard anchors:
    ///   * `-6°`  civil darkness and beyond (keeps civil twilight out)
    ///   * `-12°` nautical darkness and beyond (looser, quicker to
    ///            collect samples if the site's sun never drops far)
    ///   * `-18°` astronomical darkness only (strictest, no twilight
    ///            glow at all — default, matches what the user asked
    ///            for: "tatsächlich dunkelheit ohne dämmerung")
    var nightOnlySunAltMaxDeg: Double {
        get { defaults.double(forKey: Key.nightOnlySunAltMax, default: -18.0) }
        set { defaults.set(newValue, forKey: Key.nightOnlySunAltMax) }
    }

    /// Moon altitude (in degrees) above which the moon becomes a
    /// real reflection / sky-glow problem in the allsky frame.
    /// Below this, the moon might be technically above the horizon
    /// but too low to cause lens flare or serious glow — the site's
    /// horizon mask, distant trees / buildings, and the camera's
    /// zenith-cone crop hide it. 30° is the empirical threshold the
    /// user measured at Rheine; adjustable for other sites. Used by
    /// `MatrixTileCell.showMoonIcon` to gate the bottom-left moon
    /// badge.
    var moonAltitudeProblemThresholdDeg: Double {
        get { defaults.double(forKey: Key.moonAltProblemThreshold, default: 30.0) }
        set { defaults.set(newValue, forKey: Key.moonAltProblemThreshold) }
    }

    /// Width of the MLP hidden layer. 128 is the 0.5.0 default —
    /// large enough to learn the non-linear "bright cloudy at day"
    /// vs "clear at day" split in Vision FeaturePrint space, small
    /// enough that full-batch GD on ~15 k samples fits comfortably
    /// in memory and stays under a minute on Apple Silicon. Raising
    /// to 256 helps slightly on huge libraries; dropping below ~32
    /// starts to underfit noticeably.
    var mlpHiddenDim: Int {
        get { defaults.integer(forKey: Key.mlpHiddenDim, default: 128) }
        set { defaults.set(newValue, forKey: Key.mlpHiddenDim) }
    }

    /// Multiplicative boost applied per RatingClass (1…5) on top of
    /// inverse-frequency weighting. `[0]` is class 1 (full clouds),
    /// `[4]` is class 5 (clear).
    ///
    /// Replaces the single `clearClassBoost` knob in 0.4.2 — in
    /// practice the *under-represented* class on a given library
    /// isn't always 4 + 5. At Rheine a 14.9k-label dataset collapsed
    /// class 1 to 3 % recall because the blanket "boost 4 + 5" rule
    /// over-weighted bright overcast samples that visually resembled
    /// class 5, turning every class-1 sample into low-priority
    /// gradient noise. A per-class vector lets the curator lift the
    /// actually-failing class without collateral damage.
    ///
    /// Migration (0.4.1 → 0.4.2): when the new per-class keys are
    /// absent but the legacy `ml.clearClassBoost` was set, return
    /// `[1, 1, 1, legacy, legacy]` so an existing install keeps its
    /// previous behaviour across the upgrade. Otherwise default to
    /// all-ones (pure inverse-frequency).
    var classWeightBoosts: [Double] {
        get {
            if defaults.object(forKey: Key.classBoost1) != nil {
                return (0..<5).map { i in
                    defaults.double(forKey: Self.classBoostKey(i), default: 1.0)
                }
            }
            if defaults.object(forKey: Key.clearBoost) != nil {
                let legacy = defaults.double(forKey: Key.clearBoost)
                return [1.0, 1.0, 1.0, legacy, legacy]
            }
            return [1.0, 1.0, 1.0, 1.0, 1.0]
        }
        set {
            let values = Array(newValue.prefix(5))
            for (i, v) in values.enumerated() {
                defaults.set(v, forKey: Self.classBoostKey(i))
            }
        }
    }

    private static func classBoostKey(_ index: Int) -> String {
        switch index {
        case 0: return Key.classBoost1
        case 1: return Key.classBoost2
        case 2: return Key.classBoost3
        case 3: return Key.classBoost4
        case 4: return Key.classBoost5
        default: return Key.classBoost1
        }
    }

    /// Reset every training-side and autonomous-mode hyperparameter to
    /// its v1 default. Leaves camera / observatory / Supabase settings
    /// untouched. Used by the "Reset to defaults" button in Prefs → ML.
    func resetTrainingHyperparameters() {
        defaults.removeObject(forKey: Key.trainingLR)
        defaults.removeObject(forKey: Key.trainingIter)
        defaults.removeObject(forKey: Key.trainingL2)
        defaults.removeObject(forKey: Key.clearBoost)
        defaults.removeObject(forKey: Key.classBoost1)
        defaults.removeObject(forKey: Key.classBoost2)
        defaults.removeObject(forKey: Key.classBoost3)
        defaults.removeObject(forKey: Key.classBoost4)
        defaults.removeObject(forKey: Key.classBoost5)
        defaults.removeObject(forKey: Key.mlpHiddenDim)
        defaults.removeObject(forKey: Key.autonomousMin)
        defaults.removeObject(forKey: Key.autonomousConfidence)
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
        static let lastImageFormatRaw = "ingest.lastImageFormatRaw"
        static let lastCameraFilterRaw = "matrix.lastCameraFilterRaw"
        static let colorCenterX = "camera.color.centerXPx"
        static let colorCenterY = "camera.color.centerYPx"
        static let colorRadius  = "camera.color.radiusPx"
        static let monoCenterX  = "camera.mono.centerXPx"
        static let monoCenterY  = "camera.mono.centerYPx"
        static let monoRadius   = "camera.mono.radiusPx"
        static let colorFov     = "camera.color.fovDeg"
        static let monoFov      = "camera.mono.fovDeg"
        static let colorNorthOffset = "camera.color.northOffsetDeg"
        static let monoNorthOffset  = "camera.mono.northOffsetDeg"
        static let horizonExclusion = "camera.horizonExclusionDeg"
        static let autonomousMin = "autonomous.minLabels"
        static let autonomousConfidence = "autonomous.confidenceThreshold"
        static let clearBoost = "ml.clearClassBoost"  // legacy — kept for migration
        static let classBoost1 = "ml.classBoost.1"
        static let classBoost2 = "ml.classBoost.2"
        static let classBoost3 = "ml.classBoost.3"
        static let classBoost4 = "ml.classBoost.4"
        static let classBoost5 = "ml.classBoost.5"
        static let trainingLR = "ml.learningRate"
        static let trainingIter = "ml.iterations"
        static let trainingL2 = "ml.l2"
        static let mlpHiddenDim = "ml.mlpHiddenDim"
        static let nightOnlyMode = "ml.nightOnlyMode"
        static let nightOnlySunAltMax = "ml.nightOnlySunAltMaxDeg"
        static let moonAltProblemThreshold = "overlay.moonAltProblemThresholdDeg"
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
