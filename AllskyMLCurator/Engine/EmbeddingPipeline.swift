import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Vision

/// Extracts an Apple Vision `FeaturePrint` from each allsky frame and
/// caches the resulting 768-float vector next to the HEIF thumbnail
/// on disk. The classifier head (Phase 5b) will treat this vector as
/// its primary input and concatenate the per-frame aux features
/// (sun_alt, moon_phase, sensor_temp, …) at training time.
///
/// Pipeline per frame:
///   1. Load the original JPG from disk.
///   2. Crop + mask to the fisheye circle via `SkyDiskMask` using the
///      Preferences geometry for the frame's camera type.
///   3. Feed the masked `CGImage` to a
///      `VNGenerateImageFeaturePrintRequest`.
///   4. Extract the raw `Float32` vector via `.data` and persist to
///      `~/Library/Caches/AllskyMLCurator/embeddings/{hash}.fp`.
///
/// Cache layout: `{hash}` is SHA-256 of the absolute image path so
/// two unrelated frames with the same filename never collide. Each
/// sidecar carries a small header (magic + revision + dim) so a
/// future macOS bumping the FeaturePrint revision can be detected
/// and entries re-generated lazily.
final class EmbeddingPipeline: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = EmbeddingPipeline()
    private init() {
        try? FileManager.default.createDirectory(
            at: Self.cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Errors

    enum EmbeddingError: Error {
        case imageLoadFailed
        case skyMaskFailed
        case visionFailed(String)
        case emptyResult
        case sidecarCorrupt
    }

    // MARK: - Config

    private static let maxConcurrentExtractions = 3

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AllskyMLCurator", isDirectory: true)
            .appendingPathComponent("embeddings", isDirectory: true)
    }

    /// Sidecar format:
    ///  - 4 bytes: magic "FPRT"
    ///  - 4 bytes: revision (Int32 little-endian) — the value of
    ///    `VNGenerateImageFeaturePrintRequest.revision` at write time
    ///  - 4 bytes: dimension (Int32 little-endian)
    ///  - dim × 4 bytes: Float32 little-endian values
    private static let sidecarMagic: [UInt8] = [0x46, 0x50, 0x52, 0x54]  // "FPRT"

    // MARK: - Observable embedding result

    struct Embedding: Equatable, Sendable {
        var values: [Float]
        var revision: Int
    }

    // MARK: - Public API

    /// Remove the cached `.fp` sidecar for one image path. Silent
    /// when nothing is cached. Used by the delete-image path so an
    /// orphan embedding doesn't sit in the cache forever after the
    /// image row it described is gone.
    func purgeCache(for imagePath: String) {
        let url = diskURL(for: imagePath)
        try? FileManager.default.removeItem(at: url)
    }

    /// Fast existence check that does not read / decode the sidecar.
    /// Used by coverage polling — reading the whole 768-float blob is
    /// ~ms per frame and starves the main thread when a loop fires it
    /// for thousands of labels. `fileExists` is one `stat` per call.
    func sidecarExists(for imagePath: String) -> Bool {
        FileManager.default.fileExists(atPath: diskURL(for: imagePath).path)
    }

    /// Return the cached embedding if present on disk, without
    /// running Vision. Returns `nil` when there is no sidecar or the
    /// revision in the sidecar doesn't match the current request
    /// revision — in either case the caller should schedule
    /// `generate(for:cameraType:)`.
    func cached(for imagePath: String) -> Embedding? {
        let url = diskURL(for: imagePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let embedding = Self.decodeSidecar(data)
        else { return nil }
        return embedding.revision == currentRevision ? embedding : nil
    }

    /// Generate (or re-use) the embedding for `imagePath`. The camera
    /// type chooses which fisheye geometry is applied to the image
    /// before extraction. Concurrent calls for the same path share a
    /// single in-flight task; global concurrency is capped at
    /// `maxConcurrentExtractions` so the Vision queue + SMB reads
    /// don't saturate.
    func generate(
        for imagePath: String,
        cameraType: CameraType
    ) async -> Embedding? {
        if let hit = cached(for: imagePath) { return hit }

        let key = cacheKey(for: imagePath)
        if let existing = inflight.withLock({ $0[key] }) {
            // Join an in-flight extraction instead of starting a duplicate.
            // Cancellation of *this* call is propagated to the shared task
            // only when every joiner cancels — otherwise a scroll-off
            // shouldn't tear down work another caller still wants.
            return await existing.value
        }

        // `Task.detached` keeps the Vision + CGImageSource work off
        // the MainActor that `.task(...)` inherits. Cancellation is
        // still threaded through via `withTaskCancellationHandler` +
        // explicit `task.cancel()`, so scroll-off tears down pending
        // extractions without needing the task to be structurally
        // attached.
        let task = Task.detached(priority: .utility) { [self] () -> Embedding? in
            defer { inflight.withLock { $0[key] = nil } }
            guard !Task.isCancelled else { return nil }
            await extractionSemaphore.acquire()
            defer { Task { await extractionSemaphore.release() } }
            guard !Task.isCancelled else { return nil }
            return await self.extract(imagePath: imagePath, cameraType: cameraType)
        }
        inflight.withLock { $0[key] = task }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Extraction

    private func extract(
        imagePath: String, cameraType: CameraType
    ) async -> Embedding? {
        let sourceURL = URL(fileURLWithPath: imagePath)

        // URL-based ImageIO source so the thumbnail fetch reads only
        // the bytes it actually needs. Reading the full JPEG into RAM
        // to piggyback a SHA-256 onto it (previous attempt) saturates
        // the SMB channel under concurrent extraction + thumbnail
        // generation — the 3 embedding slots eat 3–9 MB of in-flight
        // bandwidth per burst and stall the 4-slot thumbnail cache.
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL, nil
        ) else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceThumbnailMaxPixelSize:          1024
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { return nil }

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

        let baseGeometry = SkyDiskMask.Geometry.fromSettings(for: cameraType)
        let geometry = SkyDiskMask.Geometry(
            centerXPx: Int((Double(baseGeometry.centerXPx) * scale).rounded()),
            centerYPx: Int((Double(baseGeometry.centerYPx) * scale).rounded()),
            radiusPx: max(1, Int((Double(baseGeometry.radiusPx) * scale).rounded())),
            cropFraction: baseGeometry.cropFraction
        )

        guard let masked = SkyDiskMask.apply(to: thumbnail, geometry: geometry) else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: masked, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            return nil
        }

        let values = Self.floatValues(from: observation)
        guard !values.isEmpty else { return nil }

        let embedding = Embedding(
            values: values,
            revision: request.revision
        )
        let destination = diskURL(for: imagePath)
        if let encoded = Self.encodeSidecar(embedding) {
            try? encoded.write(to: destination, options: .atomic)
        }
        return embedding
    }

    /// Extract a `[Float]` array from a `VNFeaturePrintObservation`
    /// regardless of its element-type (Apple has historically emitted
    /// `.float` and `.double` in different OS releases).
    private static func floatValues(
        from observation: VNFeaturePrintObservation
    ) -> [Float] {
        let byteCount = observation.data.count
        switch observation.elementType {
        case .float:
            let count = byteCount / MemoryLayout<Float>.size
            return observation.data.withUnsafeBytes { ptr -> [Float] in
                guard let base = ptr.bindMemory(to: Float.self).baseAddress else {
                    return []
                }
                return Array(UnsafeBufferPointer(start: base, count: count))
            }
        case .double:
            let count = byteCount / MemoryLayout<Double>.size
            let doubles = observation.data.withUnsafeBytes { ptr -> [Double] in
                guard let base = ptr.bindMemory(to: Double.self).baseAddress else {
                    return []
                }
                return Array(UnsafeBufferPointer(start: base, count: count))
            }
            return doubles.map { Float($0) }
        default:
            return []
        }
    }

    // MARK: - Sidecar encoding

    private static func encodeSidecar(_ embedding: Embedding) -> Data? {
        var bytes = Data()
        bytes.append(contentsOf: sidecarMagic)

        var revisionLE = Int32(embedding.revision).littleEndian
        withUnsafeBytes(of: &revisionLE) { bytes.append(contentsOf: $0) }

        var dimLE = Int32(embedding.values.count).littleEndian
        withUnsafeBytes(of: &dimLE) { bytes.append(contentsOf: $0) }

        for value in embedding.values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    private static func decodeSidecar(_ data: Data) -> Embedding? {
        guard data.count >= 12,
              data.prefix(4).elementsEqual(sidecarMagic)
        else { return nil }

        let revision = data.subdata(in: 4..<8).withUnsafeBytes {
            Int($0.load(as: Int32.self).littleEndian)
        }
        let dim = data.subdata(in: 8..<12).withUnsafeBytes {
            Int($0.load(as: Int32.self).littleEndian)
        }
        let expectedCount = 12 + dim * MemoryLayout<Float>.size
        guard data.count == expectedCount, dim > 0 else { return nil }

        var values = [Float](repeating: 0, count: dim)
        data.withUnsafeBytes { raw in
            let floatsBase = raw.baseAddress!.advanced(by: 12)
            for i in 0..<dim {
                let bits = floatsBase
                    .advanced(by: i * MemoryLayout<Float>.size)
                    .load(as: UInt32.self)
                    .littleEndian
                values[i] = Float(bitPattern: bits)
            }
        }
        return Embedding(values: values, revision: revision)
    }

    // MARK: - Revision

    /// Revision reported by a fresh `VNGenerateImageFeaturePrintRequest`.
    /// Cached lazily so we don't construct the request once per image
    /// just to query it.
    private lazy var currentRevision: Int = {
        VNGenerateImageFeaturePrintRequest().revision
    }()

    // MARK: - Cache key + paths

    private func cacheKey(for imagePath: String) -> String {
        let digest = SHA256.hash(data: Data(imagePath.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(for imagePath: String) -> URL {
        Self.cacheDirectory
            .appendingPathComponent(cacheKey(for: imagePath))
            .appendingPathExtension("fp")
    }

    // MARK: - Coverage helpers

    /// Number of embedding sidecars currently on disk. Fast — just
    /// counts directory entries, no file reads. Used by the toolbar
    /// progress chip.
    static func sidecarCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.count ?? 0
    }

    // MARK: - Concurrency helpers

    private let inflight = Mutex<[String: Task<Embedding?, Never>]>(initial: [:])
    private let extractionSemaphore = AsyncSemaphore(limit: 3)
}

// MARK: - Tiny helpers (kept private; sister types exist in ThumbnailCache)

private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(initial: Value) { self.value = initial }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

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
        } else {
            active -= 1
        }
    }
}
