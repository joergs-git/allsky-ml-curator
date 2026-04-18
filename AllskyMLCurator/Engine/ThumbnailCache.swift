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
    /// hit or disk hit). Returns `nil` when the thumbnail has not been
    /// generated yet — caller should schedule `generate(for:)` and
    /// show a placeholder tile in the meantime.
    func cached(for imagePath: String) -> NSImage? {
        let key = cacheKey(for: imagePath) as NSString
        if let hit = memoryCache.object(forKey: key) {
            return hit
        }
        let url = diskURL(for: imagePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return nil }
        memoryCache.setObject(image, forKey: key)
        return image
    }

    /// Generate (or re-use) the thumbnail. Safe to call concurrently
    /// from the UI layer — in-flight requests for the same path share
    /// a single task, and global concurrency is capped at
    /// `maxConcurrentGenerations` so SwiftUI's LazyVGrid can fire
    /// hundreds of `.task` blocks at once during a fast scroll
    /// without saturating the SMB connection.
    func generate(for imagePath: String) async -> NSImage? {
        // Fast check before touching the generation lock.
        if let hit = cached(for: imagePath) { return hit }

        let key = cacheKey(for: imagePath)
        if let existing = inflight.withLock({ $0[key] }) {
            return await existing.value
        }

        let task = Task.detached(priority: .utility) { [self] () -> NSImage? in
            defer { inflight.withLock { $0[key] = nil } }
            await generationSemaphore.acquire()
            defer { Task { await generationSemaphore.release() } }
            return await generateOnWorker(for: imagePath)
        }
        inflight.withLock { $0[key] = task }
        return await task.value
    }

    /// Convenience: ensure thumbnails exist for a batch of paths.
    /// Runs serially on a detached task so it doesn't saturate the
    /// UI queue or the SSD.
    func warmUp(paths: [String]) async {
        for path in paths {
            _ = await generate(for: path)
        }
    }

    // MARK: - Generation

    private func generateOnWorker(for imagePath: String) async -> NSImage? {
        let sourceURL = URL(fileURLWithPath: imagePath)
        let destination = diskURL(for: imagePath)

        // Another instance may have written the sidecar between the
        // `cached(for:)` miss and this point — re-check to avoid doing
        // the work twice.
        if let onDisk = NSImage(contentsOf: destination) {
            memoryCache.setObject(onDisk, forKey: cacheKey(for: imagePath) as NSString)
            return onDisk
        }

        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL, nil
        ) else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceThumbnailMaxPixelSize:          Self.size * 2  // retina
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { return nil }

        // Write HEIF to disk.
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        let writeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(dest, cgImage, writeOptions as CFDictionary)
        CGImageDestinationFinalize(dest)

        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: Self.size, height: Self.size)
        )
        memoryCache.setObject(nsImage, forKey: cacheKey(for: imagePath) as NSString)
        return nsImage
    }

    // MARK: - Cache key + paths

    private func cacheKey(for imagePath: String) -> String {
        let digest = SHA256.hash(data: Data(imagePath.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(for imagePath: String) -> URL {
        Self.cacheDirectory
            .appendingPathComponent(cacheKey(for: imagePath))
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
