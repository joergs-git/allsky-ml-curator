import Foundation

/// Builds the input vector the classifier consumes: the 768-dim
/// Vision feature-print concatenated with a small set of ephemeris /
/// camera / prefilter aux features.
///
/// Layout (subject to stability once v1.1 lands more aux fields):
/// ```
/// [ 0 … 767]   Vision FeaturePrint embedding
/// [768]        sun_alt_norm            = sunAltDeg / 90
/// [769]        sin(sun_az_rad)
/// [770]        cos(sun_az_rad)
/// [771]        moon_alt_norm           = moonAltDeg / 90
/// [772]        sin(moon_az_rad)
/// [773]        cos(moon_az_rad)
/// [774]        moon_phase              (already 0…1)
/// [775]        cam_one_hot_color       (0 or 1)
/// [776]        cam_one_hot_mono        (0 or 1)
/// [777]        reflection_risk_score   (0…1)
/// [778]        transitional_risk_score (0…1)
/// [779]        mb_has_forecast         (0 or 1)
/// [780]        mb_total_cloud_norm     (totalcloud / 100, 0…1)
/// [781]        mb_seeing_norm          ((seeing_arcsec - 1) / 5, clamped)
/// ```
/// Total: 782 features.
///
/// Why the two risk scores matter: a frame with a strong sun / moon
/// reflection looks bright and "feature-rich" in image space alone,
/// which would push the classifier toward a cloudy rating even when
/// the zenith sky is actually clear. The geometric + exposure-based
/// risk scores (computed at ingest, living on ImageRecord) tell the
/// classifier "this visual brightness is artefact, not cloud". Same
/// for `transitional` — gain-settling frames are noisy inputs the
/// classifier should discount. Both are available for every frame
/// regardless of whether the human has rated it, so no asymmetry
/// between training and inference.
enum FeatureVectorBuilder {

    /// Aux-only slice length. Embedding length is appended on top by
    /// the embedding pipeline and known per revision at runtime.
    static let auxCount = 14

    /// Build the full feature vector for one image. Returns `nil`
    /// when either the cached embedding or the basic ImageRecord
    /// fields are missing.
    static func vector(for image: ImageRecord) -> [Float]? {
        guard let embedding = EmbeddingPipeline.shared.cached(for: image.filePath) else {
            return nil
        }
        var result = embedding.values
        result.append(contentsOf: aux(for: image))
        return result
    }

    /// Aux portion of the vector — pure function of the ImageRecord,
    /// cheap to compute ad-hoc for prediction cadence.
    static func aux(for image: ImageRecord) -> [Float] {
        let sunAzRad = image.sunAzDeg * .pi / 180.0
        let moonAzRad = image.moonAzDeg * .pi / 180.0
        let camOneHot = cameraOneHot(for: image.cameraSource)

        // Forecast aux. When the frame has no matching meteoblue hour
        // we zero the flag + values; the classifier learns to discount
        // the forecast channel in that case. The normalisation bounds
        // match what `meteoblue_hourly` actually emits for Rheine —
        // totalcloud is already 0…100, seeing rarely leaves 1″–6″.
        let hasForecast: Float = image.meteoblueHourId == nil ? 0 : 1
        let cloudNorm: Float = Float(
            max(0.0, min(1.0, (image.meteoblueTotalCloud ?? 0.0) / 100.0))
        )
        let seeingNorm: Float = Float(
            max(0.0, min(1.0, ((image.meteoblueSeeingArcsec ?? 1.0) - 1.0) / 5.0))
        )

        return [
            Float(image.sunAltDeg / 90.0),
            Float(sin(sunAzRad)),
            Float(cos(sunAzRad)),
            Float(image.moonAltDeg / 90.0),
            Float(sin(moonAzRad)),
            Float(cos(moonAzRad)),
            Float(image.moonPhase),
            camOneHot.color,
            camOneHot.mono,
            Float(image.reflectionRiskScore),
            Float(image.transitionalRiskScore),
            hasForecast,
            cloudNorm,
            seeingNorm
        ]
    }

    private static func cameraOneHot(
        for source: ImageRecord.CameraSource
    ) -> (color: Float, mono: Float) {
        switch source {
        case .colorAllskyJpg:                  return (1, 0)
        case .monoAllskyJpg, .monoAllskyFits:  return (0, 1)
        }
    }
}
