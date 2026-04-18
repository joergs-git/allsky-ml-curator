import CoreGraphics
import Foundation
import ImageIO

/// Flags dusk / dawn frames where the camera's auto-exposure or auto-gain
/// is still settling. These transitional frames are near-garbage for the
/// classifier — over- or under-exposed, sometimes banded, and easily
/// mistaken for cloudy or reflection-heavy scenes.
///
/// Two triggers run in sequence:
///  1. **Geometric** — sun altitude inside the twilight-transition window
///     is a necessary condition for any transitional score.
///  2. **Statistical** — histogram of the clipped sky disk is compared
///     to a per-camera baseline of "expected mean brightness for this
///     sun altitude". Significant departures add to the score.
///
/// The baseline is seeded from the first ~200 ingested frames and then
/// refined over time. Frames exceeding the score threshold get an
/// auto-populated `transitional_flag = 1` that the curator can toggle
/// with the `T` key.
enum TransitionalDetector {

    /// Baseline statistics learned from previously-ingested frames. Each
    /// entry maps a sun-altitude bucket to the observed mean brightness
    /// and its standard deviation across that bucket.
    struct Baseline: Equatable, Sendable {
        /// Map of sun-altitude bucket index (floor(sun_alt_deg / bucketSize))
        /// to aggregated stats.
        var buckets: [Int: BucketStats]
        /// Width of a sun-altitude bucket in degrees. A 1° width is a
        /// reasonable trade-off between resolution and sample density.
        var bucketSizeDeg: Double

        static let empty = Baseline(buckets: [:], bucketSizeDeg: 1.0)

        struct BucketStats: Equatable, Sendable {
            var count: Int
            var meanBrightness: Double
            var stdBrightness: Double
        }

        func bucket(forSunAltDeg sunAltDeg: Double) -> Int {
            Int((sunAltDeg / bucketSizeDeg).rounded(.down))
        }
    }

    /// Input to the detector — already-computed brightness stats for the
    /// sky disk only. The statistics are cheap: a single pass over the
    /// masked thumbnail is enough.
    struct Input: Equatable {
        var sunAltDeg: Double
        var meanBrightness: Double           // 0…1
        var saturatedHighFraction: Double    // 0…1, pixels at ≥ 0.98
        var cameraIsDayCapable: Bool
    }

    /// Twilight-transition window in sun altitude. Only frames whose sun
    /// altitude falls in this range can ever be flagged as transitional.
    ///
    /// The upper bound is slightly above the horizon to catch the first
    /// few daylight frames where the camera's fully-opened iris is still
    /// closing. The lower bound is well past nautical twilight because
    /// below −12° true night conditions are stable.
    static let transitionWindowDeg: ClosedRange<Double> = -12.0 ... 6.0

    /// Fraction of saturated-high pixels above which a frame is
    /// considered likely gain-blown. Empirical starting value, tune in v1.1.
    static let saturationThreshold: Double = 0.15

    /// Number of baseline standard deviations a frame's mean brightness
    /// can sit away from the bucket mean before it contributes to the
    /// transitional score.
    static let brightnessDeviationSigma: Double = 2.0

    /// Score threshold above which `transitional_flag = 1` is
    /// auto-populated on the label row.
    static let autoFlagThreshold: Double = 0.7

    // MARK: - Scoring

    /// Produce the transitional-risk score ∈ [0, 1] for a single frame.
    ///
    /// If the sun altitude lies outside the transition window the score
    /// is zero; otherwise the two triggers each contribute independently
    /// and the maximum is returned.
    static func score(_ input: Input, baseline: Baseline = .empty) -> Double {
        // Only the color camera's auto-exposure hunts the transition
        // window. Mono frames at these altitudes are already excluded
        // upstream and this detector is not invoked for them.
        guard input.cameraIsDayCapable else { return 0.0 }
        guard transitionWindowDeg.contains(input.sunAltDeg) else { return 0.0 }

        let saturationScore = saturationContribution(input.saturatedHighFraction)
        let brightnessScore = brightnessContribution(
            sunAltDeg: input.sunAltDeg,
            measuredMean: input.meanBrightness,
            baseline: baseline
        )
        return min(1.0, max(saturationScore, brightnessScore))
    }

    // MARK: - Individual contributions

    private static func saturationContribution(_ fraction: Double) -> Double {
        guard fraction >= saturationThreshold else { return 0.0 }
        // Ramp from 0 at the threshold to 1 at twice the threshold.
        let span = saturationThreshold
        return min(1.0, (fraction - saturationThreshold) / span)
    }

    private static func brightnessContribution(
        sunAltDeg: Double,
        measuredMean: Double,
        baseline: Baseline
    ) -> Double {
        let bucketIndex = baseline.bucket(forSunAltDeg: sunAltDeg)
        guard
            let stats = baseline.buckets[bucketIndex],
            stats.count >= 10,
            stats.stdBrightness > 1e-6
        else {
            // Not enough baseline data for this bucket yet. Stay silent
            // and rely on the saturation contribution alone.
            return 0.0
        }
        let deviation = abs(measuredMean - stats.meanBrightness)
        let sigmas = deviation / stats.stdBrightness
        guard sigmas >= brightnessDeviationSigma else { return 0.0 }
        return min(1.0, (sigmas - brightnessDeviationSigma) / brightnessDeviationSigma)
    }

    // MARK: - Statistics from a CGImage

    /// Compute the minimal brightness statistics needed by `Input`.
    ///
    /// Uses CoreGraphics to draw the input into an 8-bit luminance
    /// buffer (256×256 is plenty for sample statistics), then iterates
    /// once. Kept out of the GPU / Metal pipeline so it's cheap and
    /// testable without a MTLDevice.
    static func brightnessStats(from image: CGImage) -> (mean: Double, saturatedHighFraction: Double)? {
        let width = 256
        let height = 256
        let bytesPerRow = width
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var buffer = [UInt8](repeating: 0, count: width * height)

        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum = 0
        var saturated = 0
        for byte in buffer {
            sum += Int(byte)
            if byte >= 250 { saturated += 1 }  // ~0.98 of full-scale
        }
        let mean = Double(sum) / Double(buffer.count) / 255.0
        let satFraction = Double(saturated) / Double(buffer.count)
        return (mean, satFraction)
    }
}
