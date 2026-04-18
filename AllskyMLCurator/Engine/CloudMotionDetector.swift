import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Measures the dominant pixel-space translation between two
/// consecutive allsky frames and converts it into a sky-angular rate
/// (degrees of zenith-cone per minute) plus, when the camera has a
/// calibrated north offset, a compass bearing.
///
/// Designed as a leaf utility: no singleton state, no DB access, no
/// Combine wiring. Callers decide when to invoke it (v1 uses it from
/// the inspection sheet; v2 can run it across a sliding 3-frame
/// window during ingest).
///
/// The registration itself is Vision's
/// `VNTranslationalImageRegistrationRequest`, which returns a
/// `CGAffineTransform` that aligns a "floating" image onto a
/// "reference" image. We read `.tx` / `.ty` directly — rotation and
/// scale are not fit by this request, which is exactly what we want
/// for cloud drift over a 60 s capture cadence.
enum CloudMotionDetector {

    // MARK: - Output

    struct Motion: Equatable, Sendable {
        /// Pixel translation of the current frame relative to the
        /// previous frame, in the thumbnail coordinate space Vision
        /// saw (pre-scale to the original).
        var pxPerFrame: CGVector

        /// Seconds between the previous and current frame.
        var secondsBetweenFrames: Double

        /// Angular rate of cloud motion, normalised to degrees per
        /// minute of sky-angle at the zenith. Uses the equidistant
        /// fisheye approximation: one pixel of radius = (fov/2 / R)°
        /// of sky angle.
        var degreesPerMinute: Double

        /// Frame-local bearing in degrees, 0° = up in the frame,
        /// increasing clockwise. Always populated.
        var frameBearingDeg: Double

        /// True compass bearing when the camera has a non-zero north
        /// offset in AppSettings; nil when calibration is absent so
        /// the caller can fall back to the frame-local bearing.
        var compassBearingDeg: Double?

        /// Human-readable compass label (N / NE / E / SE / S / SW / W
        /// / NW). Uses compass bearing when available, otherwise the
        /// frame bearing prefixed with "frame".
        var compassLabel: String {
            let bearing = compassBearingDeg ?? frameBearingDeg
            let sectors = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
            let idx = Int(((bearing + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
            let wrapped = (idx + sectors.count) % sectors.count
            let label = sectors[wrapped]
            return compassBearingDeg == nil ? "frame \(label)" : label
        }
    }

    enum DetectionError: Error {
        case imageLoadFailed
        case registrationFailed
        case emptyResult
    }

    // MARK: - Detection

    /// Compute motion from `previous` → `current`. Returns nil when
    /// either image can't be decoded or Vision reports no alignment.
    /// Safe to call off the main thread; no Published state.
    static func detect(
        previousPath: String,
        currentPath: String,
        secondsBetween: Double,
        cameraType: CameraType,
        fisheyeRadiusPx: Int,
        fovDeg: Double,
        northOffsetDeg: Double
    ) async -> Motion? {
        guard secondsBetween > 0 else { return nil }

        guard let prev = downsampledCGImage(at: previousPath),
              let curr = downsampledCGImage(at: currentPath) else {
            return nil
        }

        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: curr, options: [:]
        )
        let handler = VNImageRequestHandler(cgImage: prev, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }

        // The alignment transform maps `curr` onto `prev`. The cloud
        // motion vector from prev → curr is therefore the negative of
        // the transform's translation. Positive dy would mean "clouds
        // moved *down* in the image between frames", which after the
        // coordinate-system flip below becomes "south" in frame-local
        // space.
        let transform = obs.alignmentTransform
        let motionPx = CGVector(dx: -transform.tx, dy: -transform.ty)

        // Compute degrees/min using the equidistant fisheye scaling.
        // Pixels are measured in the downsampled image; scale back to
        // the original frame via the ratio of requested size to
        // original dimensions. Simpler approximation: motion is a
        // small fraction of the radius either way, so downsampling
        // roughly preserves the angular rate.
        let downsampledRadius = Double(
            min(prev.width, prev.height)
        ) / 2.0
        let radiusRatio = downsampledRadius / Double(max(fisheyeRadiusPx, 1))
        let effectiveRadius = Double(fisheyeRadiusPx) * radiusRatio
        let magnitudePx = sqrt(
            Double(motionPx.dx) * Double(motionPx.dx)
                + Double(motionPx.dy) * Double(motionPx.dy)
        )
        let halfFov = fovDeg / 2.0
        let degreesPerPx = effectiveRadius > 0
            ? halfFov / effectiveRadius
            : 0
        let degreesThisFrame = magnitudePx * degreesPerPx
        let minutes = secondsBetween / 60.0
        let degreesPerMinute = minutes > 0 ? degreesThisFrame / minutes : 0

        // Frame-local bearing: 0° means clouds moved upward in the
        // frame (image +Y is down in ImageIO, hence the negate on dy).
        let frameBearingRad = atan2(
            Double(motionPx.dx), -Double(motionPx.dy)
        )
        let frameBearingDeg = Self.normalizeBearing(
            frameBearingRad * 180.0 / .pi
        )

        let compassBearingDeg: Double?
        if abs(northOffsetDeg) > 0.001 {
            compassBearingDeg = Self.normalizeBearing(
                frameBearingDeg + northOffsetDeg
            )
        } else {
            // No calibration recorded — cameraType is accepted here
            // so the caller still gets a stable signature and future
            // per-camera post-processing can plug in without a
            // new parameter.
            _ = cameraType
            compassBearingDeg = nil
        }

        return Motion(
            pxPerFrame: motionPx,
            secondsBetweenFrames: secondsBetween,
            degreesPerMinute: degreesPerMinute,
            frameBearingDeg: frameBearingDeg,
            compassBearingDeg: compassBearingDeg
        )
    }

    // MARK: - Helpers

    /// Load a JPG at ~512 px long-edge via ImageIO. Matches the scale
    /// used elsewhere in the pipeline and keeps Vision registration
    /// fast — full 3552² decode would triple the wall time with no
    /// benefit to the vector estimate.
    private static func downsampledCGImage(at path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    /// Map an arbitrary angle into [0, 360).
    private static func normalizeBearing(_ deg: Double) -> Double {
        let mod = deg.truncatingRemainder(dividingBy: 360)
        return mod < 0 ? mod + 360 : mod
    }
}
