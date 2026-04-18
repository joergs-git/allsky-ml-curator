import AppKit
import CryptoKit
import Foundation
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

        let task = Task.detached(priority: .utility) { [self] () -> NSImage? in
            defer { inflight.withLock { $0[key] = nil } }
            await generationSemaphore.acquire()
            defer { Task { await generationSemaphore.release() } }
            return await generateOnWorker(
                for: imagePath, cameraType: cameraType
            )
        }
        inflight.withLock { $0[key] = task }
        return await task.value
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

        // SkyDiskMask wants a full-resolution CGImage so the geometry
        // values (center_x/y + radius) are expressed in the camera's
        // native pixel space. Loading the original is slow on SMB —
        // the detached task + 4-slot semaphore in this class bound
        // the damage.
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let geometry = SkyDiskMask.Geometry.fromSettings(for: cameraType)
        guard let masked = SkyDiskMask.apply(to: cgImage, geometry: geometry) else {
            return nil
        }

        // Resize to the cache target. The masked image is already
        // square, so one uniform scale does the job.
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
