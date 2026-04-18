import AppKit
import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// Generates and caches 512×512 HEIF thumbnails for the allsky frames.
///
/// The matrix view has potentially thousands of tiles and scrolls
/// fluently on a Mac Studio; loading a 3552×3552 JPG per tile is out
/// of the question. The cache has two tiers:
///
///  - **Disk**: HEIF sidecar under
///    `~/Library/Caches/AllskyMLCurator/thumbnails/{hash}.heic`.
///    `{hash}` is SHA-256 of the image's absolute path so two
///    unrelated frames with the same basename don't collide.
///  - **Memory**: `NSCache<NSString, NSImage>` with 200 entries max.
///    Decoded NSImages are kept around for snappy re-scroll.
///
/// Generation is async (GCD background queue), so the matrix view can
/// display a placeholder tile immediately and swap in the real image
/// when it's ready.
final class ThumbnailCache: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = ThumbnailCache()
    private init() {
        memoryCache.countLimit = 200
        try? FileManager.default.createDirectory(
            at: Self.cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Config

    /// Square side length of generated thumbnails. 512 is a good
    /// trade-off: pin-sharp at 240 pt tile size on a 2× Retina screen,
    /// ~50 KB HEIF per frame on disk.
    static let size: CGFloat = 512

    /// Upper bound on concurrent decodes. Reading and JPEG-decoding a
    /// 3552×3552 allsky frame from the SMB share is the bottleneck; at
    /// 20+ simultaneous reads macOS starts queuing + the UI stalls
    /// waiting for async results. Four keeps the SMB channel busy
    /// without saturating it.
    private static let maxConcurrentGenerations = 4

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AllskyMLCurator", isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
    }

    // MARK: - Public API

    /// Fast path: returns the cached thumbnail if available (memory
    /// hit or disk hit). The cache key includes the camera type so
    /// color and mono crops never collide, and a crop-fraction tag
    /// so changing Preferences → Camera → Horizon exclusion gives a
    /// fresh cache rather than stale images.
    func cached(
        for imagePath: String, cameraType: CameraType
    ) -> NSImage? {
        let key = cacheKey(for: imagePath, cameraType: cameraType) as NSString
        if let hit = memoryCache.object(forKey: key) {
            return hit
        }
        let url = diskURL(for: imagePath, cameraType: cameraType)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return nil }
        memoryCache.setObject(image, forKey: key)
        return image
    }

    /// Generate (or re-use) the thumbnail. Runs the same
    /// `SkyDiskMask` the ML embedding uses, so "what you see is what
    /// you train on" — the tile shows only the zenith cone and the
    /// horizon ring is neutralised.
    func generate(
        for imagePath: String, cameraType: CameraType
    ) async -> NSImage? {
        if let hit = cached(for: imagePath, cameraType: cameraType) { return hit }

        let key = cacheKey(for: imagePath, cameraType: cameraType)
        if let existing = inflight.withLock({ $0[key] }) {
            return await existing.value
        }

        // `Task.detached` is load-bearing here: the matrix tile's
        // `.task` runs on the MainActor, and a plain `Task { ... }`
        // inherits that isolation — which means CGImageSource decode,
        // CGContext.draw, and the HEIC encode would all block the
        // main thread. Detached pushes the work onto the cooperative
        // pool. Cancellation is propagated manually via
        // `withTaskCancellationHandler` + explicit `task.cancel()` so
        // the scroll-off wins the orphan-task fix from PR #38 still
        // apply.
        let task = Task.detached(priority: .utility) { [self] () -> NSImage? in
            defer { inflight.withLock { $0[key] = nil } }
            guard !Task.isCancelled else { return nil }
            await generationSemaphore.acquire()
            defer { Task { await generationSemaphore.release() } }
            guard !Task.isCancelled else { return nil }
            return await generateOnWorker(
                for: imagePath, cameraType: cameraType
            )
        }
        inflight.withLock { $0[key] = task }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Generation

    private func generateOnWorker(
        for imagePath: String, cameraType: CameraType
    ) async -> NSImage? {
        let sourceURL = URL(fileURLWithPath: imagePath)
        let destination = diskURL(for: imagePath, cameraType: cameraType)

        if let onDisk = NSImage(contentsOf: destination) {
            memoryCache.setObject(
                onDisk,
                forKey: cacheKey(for: imagePath, cameraType: cameraType) as NSString
            )
            return onDisk
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)
        else { return nil }

        // ImageIO's thumbnail pathway is vastly faster than a full
        // `CGImageSourceCreateImageAtIndex` decode — especially over
        // SMB, where reading the full 3552×3552 JPEG is the real
        // bottleneck. We downsample the source to a maxDim that's
        // roughly 2× the final tile size so the SkyDiskMask crop still
        // has enough detail to re-resize cleanly, then apply the mask
        // using a scaled Geometry.
        let maxThumbDim = Int(Self.size * 2)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceThumbnailMaxPixelSize:          maxThumbDim
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { return nil }

        // Derive the pixel-space scale factor from the source props
        // so we can scale the fisheye geometry to match the thumbnail.
        let scale: Double = {
            guard let props = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil
            ) as? [CFString: Any],
            let srcW = props[kCGImagePropertyPixelWidth] as? Int,
            srcW > 0 else {
                return 1.0
            }
            return Double(thumbnail.width) / Double(srcW)
        }()

        let geometry = Self.scaledGeometry(
            SkyDiskMask.Geometry.fromSettings(for: cameraType),
            by: scale
        )
        guard let masked = SkyDiskMask.apply(to: thumbnail, geometry: geometry) else {
            return nil
        }

        // Resize to the canonical cache size. Masked output may be
        // smaller than `size` when the zenith crop is aggressive —
        // the resize step normalises the tile dimension either way.
        guard let resized = Self.resize(masked, to: Int(Self.size)) else {
            return nil
        }

        if let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) {
            let writeOptions: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.8
            ]
            CGImageDestinationAddImage(dest, resized, writeOptions as CFDictionary)
            CGImageDestinationFinalize(dest)
        }

        let nsImage = NSImage(
            cgImage: resized,
            size: NSSize(width: Self.size, height: Self.size)
        )
        memoryCache.setObject(
            nsImage,
            forKey: cacheKey(for: imagePath, cameraType: cameraType) as NSString
        )
        return nsImage
    }

    /// Scale a fisheye geometry by `scale`, preserving the crop
    /// fraction. Used when SkyDiskMask needs to operate on an
    /// already-downsampled thumbnail rather than the full image.
    private static func scaledGeometry(
        _ g: SkyDiskMask.Geometry, by scale: Double
    ) -> SkyDiskMask.Geometry {
        guard scale > 0, scale != 1 else { return g }
        return SkyDiskMask.Geometry(
            centerXPx: Int((Double(g.centerXPx) * scale).rounded()),
            centerYPx: Int((Double(g.centerYPx) * scale).rounded()),
            radiusPx: max(1, Int((Double(g.radiusPx) * scale).rounded())),
            cropFraction: g.cropFraction
        )
    }

    /// Downscale a square `CGImage` to `side × side` pixels using a
    /// neutral-grey context. Separate from SkyDiskMask so SkyDiskMask
    /// can keep producing full-resolution output for the embedding
    /// path (which does its own 224×224 resize via Vision).
    private static func resize(_ image: CGImage, to side: Int) -> CGImage? {
        guard side > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: side, height: side)
        )
        return context.makeImage()
    }

    // MARK: - Rebuild helper

    /// Progress snapshot for the rebuild-missing walker. `regenerated`
    /// counts files newly written this run; `skipped` counts files
    /// already on disk.
    struct RebuildProgress: Equatable, Sendable {
        var done: Int
        var total: Int
        var regenerated: Int
        var skipped: Int
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// Rebuild every thumbnail whose HEIC sidecar isn't on disk under
    /// the current cacheKey (fisheye geometry + crop fraction). Fixes
    /// the "chunk gap" symptom where changing Preferences → Camera
    /// invalidates a subset of cache keys and scroll shows stuck
    /// spinners for tiles in the affected range. `onProgress` fires
    /// after every 10 frames so the caller can drive a progress bar
    /// without an update per tile.
    func rebuildMissing(
        onProgress: @Sendable @escaping (RebuildProgress) -> Void
    ) async {
        let images = (try? await Database.shared.reader.read { db in
            try ImageRecord
                .filter(ImageRecord.Columns.isExcluded == false)
                .order(ImageRecord.Columns.captureUtc.asc)
                .fetchAll(db)
        }) ?? []
        let total = images.count
        var done = 0
        var regenerated = 0
        var skipped = 0

        for image in images {
            if Task.isCancelled { return }
            let url = diskURL(
                for: image.filePath,
                cameraType: image.cameraSource.cameraType
            )
            if FileManager.default.fileExists(atPath: url.path) {
                skipped += 1
            } else {
                _ = await generate(
                    for: image.filePath,
                    cameraType: image.cameraSource.cameraType
                )
                regenerated += 1
            }
            done += 1
            if done.isMultiple(of: 10) || done == total {
                onProgress(RebuildProgress(
                    done: done, total: total,
                    regenerated: regenerated, skipped: skipped
                ))
            }
        }
    }

    // MARK: - Single-frame purge

    /// Remove one image's cached HEIC + memory entry so a subsequent
    /// database delete doesn't leave orphan files in the cache dir.
    /// Silent if nothing was cached.
    func purgeCache(for imagePath: String, cameraType: CameraType) {
        let key = cacheKey(for: imagePath, cameraType: cameraType)
        memoryCache.removeObject(forKey: key as NSString)
        let url = diskURL(for: imagePath, cameraType: cameraType)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Cache key + paths

    /// Key = SHA-256 over `{path}|{camera}|c{cropPercent}`. Different
    /// camera types or crop fractions produce different keys so the
    /// old cache files stay on disk but aren't used (orphaned until
    /// the user purges `~/Library/Caches/AllskyMLCurator`).
    private func cacheKey(
        for imagePath: String, cameraType: CameraType
    ) -> String {
        let fraction = AppSettings.shared.zenithCropFraction(for: cameraType)
        let cropTag = String(format: "c%03d", Int((fraction * 1000).rounded()))
        let material = "\(imagePath)|\(cameraType.rawValue)|\(cropTag)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(
        for imagePath: String, cameraType: CameraType
    ) -> URL {
        Self.cacheDirectory
            .appendingPathComponent(cacheKey(for: imagePath, cameraType: cameraType))
            .appendingPathExtension("heic")
    }

    // MARK: - State

    private let memoryCache = NSCache<NSString, NSImage>()

    /// Deduplicates concurrent generation for the same path. Lock-
    /// protected dictionary from cache-key → in-flight task.
    private let inflight = Mutex<[String: Task<NSImage?, Never>]>(initial: [:])

    /// Bounds the number of in-flight JPEG decodes so the SMB channel
    /// doesn't get saturated during a fast scroll through thousands
    /// of tiles.
    private let generationSemaphore = AsyncSemaphore(limit: 4)
}

// MARK: - Async semaphore

/// Lightweight async semaphore used to throttle concurrent thumbnail
/// generations. Actor-isolated so acquire/release happen in a
/// well-defined order with no data races.
private actor AsyncSemaphore {
    private let limit: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            // `active` stays — the slot moves from this task to the next
        } else {
            active -= 1
        }
    }
}

// MARK: - Tiny Mutex helper

/// Bare-bones lock around a value. Avoids adding an actor hop for a
/// scalar `Dictionary`-based deduplication map.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(initial: Value) { self.value = initial }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
