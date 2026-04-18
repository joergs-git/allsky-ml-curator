import CryptoKit
import Foundation
import GRDB
import SwiftUI

/// Folder-based ingest for Phase 1.
///
/// The user opens any folder via `Cmd+O` (parity with AstroBlink) and
/// picks the camera type (Color / Monochrome). The service walks the
/// folder recursively for supported image extensions, parses a capture
/// timestamp from every filename (falling back to file mtime), and
/// pre-computes ephemeris + reflection + geometric transitional risk
/// scores for each frame.
///
/// Supabase is used purely for *enrichment* — if credentials are
/// configured, the service fetches `cloudwatcher_readings` covering
/// the folder's time range in a single batch and attaches the nearest
/// match (within ±5 min) to every image.
///
/// `dryRun = true` performs every step except the database write so
/// the UI can preview counts before committing.
@MainActor
final class IngestService: ObservableObject {

    // MARK: - Observable state

    @Published private(set) var totalFiles: Int = 0
    @Published private(set) var processed: Int = 0
    @Published private(set) var inserted: Int = 0
    @Published private(set) var skippedNoTimestamp: Int = 0
    @Published private(set) var skippedUnknownExtension: Int = 0
    @Published private(set) var excluded: Int = 0
    @Published private(set) var reflectionFlagged: Int = 0
    @Published private(set) var transitionalFlagged: Int = 0
    @Published private(set) var enrichedWithWeather: Int = 0
    @Published private(set) var enrichedWithMeta: Int = 0
    @Published private(set) var statusMessage: String = "idle"
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?

    // MARK: - Entry point

    /// Ingest every supported image in `folderURL` as captures from
    /// the given `cameraType` + `imageFormat`. The scan filter uses
    /// `imageFormat` to decide which file extensions to pick up, so a
    /// parent folder containing sibling `jpg/` and `fits/` subtrees
    /// can be scanned cleanly without doubling the index. Observatory
    /// coordinates come from `AppSettings.shared`.
    func ingestFolder(
        _ folderURL: URL,
        cameraType: CameraType,
        imageFormat: ImageFormat,
        dryRun: Bool
    ) async {
        guard !isRunning else { return }
        resetCounters()
        isRunning = true
        lastError = nil
        cancelToken = CancelToken()
        let token = cancelToken

        // Sandbox: keep the folder accessible for the duration of the run.
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { folderURL.stopAccessingSecurityScopedResource() }
        }

        statusMessage = "scanning \(folderURL.lastPathComponent)…"

        do {
            let files = scanFolder(folderURL, imageFormat: imageFormat)
            totalFiles = files.count
            statusMessage = "processing \(files.count) files…"

            try await buildWeatherIndex(forFiles: files)
            let dbWriter: DatabaseWriter? =
                dryRun ? nil : Database.shared.writer

            for file in files {
                try token.checkCancelled()
                await processFile(
                    file,
                    cameraType: cameraType,
                    dbWriter: dbWriter
                )
                processed += 1
            }

            statusMessage = dryRun
                ? "dry-run done — \(inserted) of \(files.count) eligible"
                : "ingest done — \(inserted) of \(files.count) written"
        } catch is CancellationError {
            statusMessage = "cancelled"
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            statusMessage = "failed: \(lastError ?? "?")"
        }

        isRunning = false
    }

    /// Request cancellation of the current run.
    func cancel() { cancelToken.cancel() }

    // MARK: - Folder scan

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "fit", "fits"
    ]

    /// Directory names whose entire subtrees are skipped during the
    /// image scan. The user's allsky layout puts derived products
    /// (keograms, keogram-rt, star-trail composites) in sibling folders
    /// that we never want to train on, and per-frame metadata JSONs
    /// live in `meta/` which we access via a direct sidecar lookup
    /// rather than a recursive walk.
    private static func shouldSkipDirectory(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("keogram")
            || lower == "startrail"
            || lower == "meta"
    }

    /// Walk `folderURL` recursively and return every supported image
    /// file whose extension matches `imageFormat`. Directory subtrees
    /// that match `shouldSkipDirectory` are pruned entirely via
    /// `enumerator.skipDescendants()`. Results are sorted by path so
    /// the UI counter advances in a stable order.
    private func scanFolder(_ folderURL: URL, imageFormat: ImageFormat) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let allowedExtensions = imageFormat.extensions

        var results: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey]
            )

            // Prune derived-product and metadata subdirectories.
            if values?.isDirectory == true,
               Self.shouldSkipDirectory(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - Weather enrichment

    /// Cache of the most recent fetch so `processFile` can look up the
    /// full reading row (not just the timestamp) when it finds a match.
    private var latestWeatherReadings: [SupabaseClient.CloudwatcherReading] = []

    /// Fetch one batch of Supabase `cloudwatcher_readings` covering the
    /// folder's time range, so per-file lookup is O(n) over an in-memory
    /// array rather than n network round-trips. No-op when Supabase is
    /// not configured.
    private func buildWeatherIndex(forFiles files: [URL]) async throws {
        latestWeatherReadings = []
        guard SupabaseClient.shared.loadConfig() != nil else { return }
        guard let range = timeRange(of: files) else { return }

        statusMessage = "fetching weather for \(range.lowerBound.iso8601Short()) … \(range.upperBound.iso8601Short())"

        // Widen ±10 min so frames near the edges still find a neighbor.
        let lower = range.lowerBound.addingTimeInterval(-600)
        let upper = range.upperBound.addingTimeInterval(600)
        latestWeatherReadings = try await SupabaseClient.shared
            .fetchCloudwatcherReadings(from: lower, to: upper)
    }

    /// Timestamp range covered by the given files. Fast path: filename
    /// parsing + modification-date fallback (meta JSON reads during a
    /// range probe would double the disk traffic for no benefit — a
    /// ±10 min widening downstream absorbs the small deltas between
    /// filename and sidecar time).
    private func timeRange(of files: [URL]) -> ClosedRange<Date>? {
        var earliest: Date?
        var latest: Date?
        for url in files {
            guard let ts = timestamp(for: url, meta: nil) else { continue }
            earliest = min(earliest ?? ts, ts)
            latest   = max(latest   ?? ts, ts)
        }
        guard let e = earliest, let l = latest else { return nil }
        return e...l
    }

    // MARK: - Per-file processing

    private func processFile(
        _ fileURL: URL,
        cameraType: CameraType,
        dbWriter: DatabaseWriter?
    ) async {
        guard let cameraSource = cameraType.cameraSource(for: fileURL.pathExtension) else {
            skippedUnknownExtension += 1
            return
        }

        let meta = MetaJsonReader.read(for: fileURL)
        if meta != nil { enrichedWithMeta += 1 }

        guard let captureUtc = timestamp(for: fileURL, meta: meta) else {
            skippedNoTimestamp += 1
            return
        }

        let matchedReading = nearestReading(to: captureUtc)
        if matchedReading != nil { enrichedWithWeather += 1 }

        let record = classify(
            filePath: fileURL.path,
            cameraSource: cameraSource,
            cameraType: cameraType,
            captureUtc: captureUtc,
            matchedReading: matchedReading,
            meta: meta
        )

        if record.isExcluded { excluded += 1 }
        if record.reflectionRiskScore >= 0.5 { reflectionFlagged += 1 }
        if record.transitionalRiskScore >= 0.7 { transitionalFlagged += 1 }

        if let dbWriter {
            do {
                try await insertIfNew(record, into: dbWriter)
            } catch {
                lastError = "DB insert failed for \(fileURL.lastPathComponent): \(error)"
                return
            }
        }
        inserted += 1
    }

    /// Timestamp priority: sidecar `time` (authoritative UTC epoch)
    /// → filename regex → file modification date.
    private func timestamp(
        for url: URL,
        meta: MetaJsonReader.Metadata?
    ) -> Date? {
        if let meta { return meta.captureUtc }
        if let date = FilenameTimestamp.parse(url.lastPathComponent) { return date }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    /// Find the closest reading in `latestWeatherReadings` whose
    /// timestamp is within ±5 minutes of `captureUtc`.
    private func nearestReading(
        to captureUtc: Date
    ) -> SupabaseClient.CloudwatcherReading? {
        guard !latestWeatherReadings.isEmpty else { return nil }
        var best: SupabaseClient.CloudwatcherReading?
        var bestDelta = TimeInterval.greatestFiniteMagnitude
        for reading in latestWeatherReadings {
            let delta = abs(reading.timestamp.timeIntervalSince(captureUtc))
            if delta < bestDelta {
                bestDelta = delta
                best = reading
            }
        }
        return bestDelta <= 300 ? best : nil
    }

    // MARK: - Classification

    private func classify(
        filePath: String,
        cameraSource: ImageRecord.CameraSource,
        cameraType: CameraType,
        captureUtc: Date,
        matchedReading: SupabaseClient.CloudwatcherReading?,
        meta: MetaJsonReader.Metadata?
    ) -> ImageRecord {
        let latitude  = AppSettings.shared.latitudeDeg
        let longitude = AppSettings.shared.longitudeDeg

        let sun = Ephemeris.sun(
            at: captureUtc,
            latitudeDeg: latitude,
            longitudeDeg: longitude
        )
        let moon = Ephemeris.moon(
            at: captureUtc,
            latitudeDeg: latitude,
            longitudeDeg: longitude
        )

        let isExcluded = cameraType.isExcludedAtSunAlt(sun.horizontal.altitudeDeg)

        let reflectionScore = ReflectionPrefilter.score(
            .init(
                sunAltDeg: sun.horizontal.altitudeDeg,
                moonAltDeg: moon.horizontal.altitudeDeg,
                moonIlluminationFraction: moon.illumination,
                cameraIsDayCapable: cameraType.dayCapable
            )
        )

        // Transitional risk: geometric fallback (sun in twilight window)
        // plus an authoritative override from the sidecar — when the
        // capture software reports `stable_exposure == 0`, the frame is
        // mid-AE-hunt and reliably bad.
        let geometricInWindow =
            TransitionalDetector.transitionWindowDeg.contains(sun.horizontal.altitudeDeg)
            && cameraType.dayCapable
        let aeUnstable = meta?.stableExposure == false
        let transitionalScore: Double = {
            if aeUnstable { return 1.0 }
            return geometricInWindow ? 0.5 : 0.0
        }()

        return ImageRecord(
            id: nil,
            filePath: filePath,
            fileHashSha256: Self.pathIdentityHash(for: filePath),
            cameraSource: cameraSource,
            captureUtc: captureUtc,
            timeOfDay: sun.timeOfDay,
            supabaseReadingId: matchedReading?.id,
            sunAltDeg: sun.horizontal.altitudeDeg,
            sunAzDeg: sun.horizontal.azimuthDeg,
            moonAltDeg: moon.horizontal.altitudeDeg,
            moonAzDeg: moon.horizontal.azimuthDeg,
            moonPhase: moon.illumination,
            reflectionRiskScore: reflectionScore,
            transitionalRiskScore: transitionalScore,
            isExcluded: isExcluded,
            exposureSec: meta?.exposureSec,
            gain: meta?.gain,
            sensorTempC: meta?.sensorTempC,
            aeStable: meta.map { $0.stableExposure },
            embeddingPath: nil,
            embeddingRevision: 0,
            createdAt: Date()
        )
    }

    /// Cheap "stable identity" hash of the file path. Not a content
    /// hash — moving / renaming the file produces a new identity — but
    /// good enough for the Supabase row to carry a deterministic ID
    /// that matches across machines sharing the same filesystem. A
    /// proper content-hash variant can be computed lazily by the
    /// embedding pipeline; at ingest time reading each JPG twice over
    /// SMB would be painful.
    private static func pathIdentityHash(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Database insert

    /// Insert when no row with the same `file_path` already exists.
    private func insertIfNew(
        _ record: ImageRecord, into db: DatabaseWriter
    ) async throws {
        try await db.write { db in
            let existing = try ImageRecord
                .filter(ImageRecord.Columns.filePath == record.filePath)
                .fetchOne(db)
            if existing == nil {
                var mutable = record
                try mutable.insert(db)
            }
        }
    }

    // MARK: - Bookkeeping

    private var cancelToken = CancelToken()

    private func resetCounters() {
        totalFiles = 0
        processed = 0
        inserted = 0
        skippedNoTimestamp = 0
        skippedUnknownExtension = 0
        excluded = 0
        reflectionFlagged = 0
        transitionalFlagged = 0
        enrichedWithWeather = 0
        enrichedWithMeta = 0
    }

    // MARK: - Cancellation

    private final class CancelToken: @unchecked Sendable {
        private var cancelled = false
        private let lock = NSLock()

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }

        func checkCancelled() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }
    }
}

// MARK: - Small formatting helper

private extension Date {
    func iso8601Short() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: self)
    }
}
