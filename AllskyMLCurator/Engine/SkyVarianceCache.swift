import AppKit
import CoreGraphics
import Foundation

/// Per-image luminance standard deviation cache.
///
/// Why this matters: the 0.6.x autopilot sweep showed that amplifying
/// the geometric moon / sun / reflection aux signals breaks the
/// class-5 ↔ class-4 confusion in most cases, but **one residual
/// failure mode survives**: a bright moon at just-above-threshold
/// altitude can still lay a smooth luminance gradient on a genuinely
/// clear sky that the MLP reads as cloud. The distinguishing cue is
/// *texture*: real clouds are structured (high variance); moon glow
/// is smooth (low variance). The Vision FeaturePrint encodes a lot
/// of visual content, but precomputing a texture scalar makes it
/// directly available as an aux feature without needing the MLP to
/// derive it from the 768-dim embedding.
///
/// Implementation: reads the already-cached HEIC thumbnail from disk
/// (zenith-cropped to exactly the same region Vision saw when it
/// extracted the embedding, via `SkyDiskMask`), decodes it once to
/// an 8-bit grayscale bitmap, computes the std-dev of the luminance
/// over the non-padding pixels, and caches the result in memory.
///
/// Thread safety: a plain `NSLock` around a dictionary is
/// sufficient — the feature-vector build site is the only writer
/// and happens in bursts (during `loadTrainingSet` or
/// `recomputeAllPredictions`), not per-user-keystroke.
final class SkyVarianceCache: @unchecked Sendable {

    static let shared = SkyVarianceCache()
    private init() {}

    // MARK: - Public API

    /// Normalised luminance std-dev for the zenith-cropped thumbnail,
    /// 0…1 roughly (std-dev over an 8-bit image divided by 128). Nil
    /// when the thumbnail can't be loaded — the caller emits 0 and
    /// flags `has_variance = 0` in the feature vector.
    func value(for imagePath: String, cameraType: CameraType) -> Float? {
        let key = Self.cacheKey(imagePath: imagePath, cameraType: cameraType)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit.isNaN ? nil : hit
        }
        lock.unlock()

        let url = ThumbnailCache.shared.thumbnailURL(
            for: imagePath, cameraType: cameraType
        )
        guard FileManager.default.fileExists(atPath: url.path),
              let cg = Self.loadCGImage(at: url) else {
            lock.lock()
            cache[key] = .nan
            lock.unlock()
            return nil
        }

        let std = Self.luminanceStdDev(cg: cg)
        lock.lock()
        cache[key] = std
        lock.unlock()
        return std
    }

    /// Drop everything — used by the purge path when thumbnails are
    /// regenerated (the variance would no longer match the on-disk
    /// HEIC then).
    func purgeAll() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    // MARK: - Storage

    private let lock = NSLock()
    /// NaN sentinel marks "we tried to compute and failed" so we
    /// don't retry on every subsequent feature-vector build.
    private var cache: [String: Float] = [:]

    private static func cacheKey(imagePath: String, cameraType: CameraType) -> String {
        "\(cameraType.rawValue):\(imagePath)"
    }

    // MARK: - Image loading + stats

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Compute the standard deviation of luminance over the non-alpha
    /// pixels of the image, normalised to [0, 1] by dividing by 128
    /// (half the 8-bit luminance range). Values near 0 = smooth
    /// gradient (moon glow, featureless overcast); values near 1 =
    /// high-contrast structure (broken cloud, bright star field).
    /// Pixels fully outside the mask (alpha = 0) are skipped so the
    /// padding band around the fisheye doesn't drag the mean toward 0.
    static func luminanceStdDev(cg: CGImage) -> Float {
        let width = cg.width
        let height = cg.height
        let bytesPerRow = width * 4
        let capacity = bytesPerRow * height
        var buffer = [UInt8](repeating: 0, count: capacity)
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Single-pass mean + variance using Welford-style accumulators
        // on ITU-R BT.601 luminance. Skips alpha-0 pixels (mask edge).
        var count: Int = 0
        var mean: Double = 0
        var m2: Double = 0
        for i in stride(from: 0, to: capacity, by: 4) {
            let a = buffer[i + 3]
            if a < 128 { continue }
            let r = Double(buffer[i])
            let g = Double(buffer[i + 1])
            let b = Double(buffer[i + 2])
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            count += 1
            let delta = y - mean
            mean += delta / Double(count)
            m2 += delta * (y - mean)
        }
        guard count > 2 else { return 0 }
        let variance = m2 / Double(count - 1)
        let std = sqrt(variance)
        return Float(min(1.0, std / 128.0))
    }
}
