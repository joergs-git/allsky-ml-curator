import Foundation

/// Builds the input vector the classifier consumes: the 768-dim
/// Vision feature-print concatenated with a small set of ephemeris /
/// camera aux features.
///
/// Layout (subject to stability once v1.1 lands more aux fields):
/// ```
/// [ 0 … 767]   Vision FeaturePrint embedding
/// [768]        sun_alt_norm       = sunAltDeg / 90
/// [769]        sin(sun_az_rad)
/// [770]        cos(sun_az_rad)
/// [771]        moon_alt_norm      = moonAltDeg / 90
/// [772]        sin(moon_az_rad)
/// [773]        cos(moon_az_rad)
/// [774]        moon_phase         (already 0…1)
/// [775]        cam_one_hot_color  (0 or 1)
/// [776]        cam_one_hot_mono   (0 or 1)
/// ```
/// Total: 777 features. Extending later (sky_temp z-score, exposure,
/// gain, transitional-risk) is additive — the classifier just has to
/// be retrained with the wider vector.
enum FeatureVectorBuilder {

    /// Aux-only slice length. Embedding length is appended on top by
    /// the embedding pipeline and known per revision at runtime.
    static let auxCount = 9

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

        return [
            Float(image.sunAltDeg / 90.0),
            Float(sin(sunAzRad)),
            Float(cos(sunAzRad)),
            Float(image.moonAltDeg / 90.0),
            Float(sin(moonAzRad)),
            Float(cos(moonAzRad)),
            Float(image.moonPhase),
            camOneHot.color,
            camOneHot.mono
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
