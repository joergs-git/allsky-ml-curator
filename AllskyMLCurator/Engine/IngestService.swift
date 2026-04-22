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

    // MARK: - Singleton

    /// Shared instance so both ingest sheets (folder-walk and
    /// weather-filtered) observe the same published progress state.
    /// Without a singleton each sheet would get its own `@StateObject`
    /// and the progress counters would reset when either sheet
    /// re-mounted.
    static let shared = IngestService()

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

            // Staged batch so we can commit the whole group in a
            // single GRDB write transaction. One transaction per file
            // is fine at ~100 frames but at 20 000 frames the SQLite
            // BEGIN/COMMIT overhead dominates, stretching an ingest
            // run to several minutes of wall time. Batching to ~500
            // cuts 20 k transactions down to ~40.
            var pendingBatch: [ImageRecord] = []
            pendingBatch.reserveCapacity(Self.insertBatchSize)

            // Cancellation + error paths both need to flush any
            // already-processed records to the DB so the user
            // doesn't silently lose the first ~499 frames of a
            // batch when they hit Cancel mid-run. The bookkeeping
            // happens in the defer so every exit path is covered.
            defer {
                if let dbWriter, !pendingBatch.isEmpty {
                    let doomed = pendingBatch
                    Task { @MainActor in
                        var batch = doomed
                        await self.flushPendingBatch(&batch, into: dbWriter)
                    }
                }
            }

            for file in files {
                try token.checkCancelled()
                if let record = await processFile(
                    file, cameraType: cameraType
                ) {
                    if dbWriter != nil {
                        pendingBatch.append(record)
                    } else {
                        // Dry-run: count without DB writes so the
                        // preview still reflects what a real run
                        // would insert.
                        inserted += 1
                    }
                }
                processed += 1

                if let dbWriter,
                   pendingBatch.count >= Self.insertBatchSize {
                    await flushPendingBatch(&pendingBatch, into: dbWriter)
                }
            }

            if let dbWriter, !pendingBatch.isEmpty {
                await flushPendingBatch(&pendingBatch, into: dbWriter)
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

    /// Ingest an explicit list of file URLs rather than walking a
    /// folder. Used by the weather-filtered ingest where the file
    /// set is the result of a Supabase `cloudwatcher_readings` query
    /// (e.g. "every clear-enough-but-not-fully-clear frame"). Still
    /// runs the same weather + meteoblue + ephemeris enrichment path
    /// as folder ingest so downstream code sees identical rows.
    func ingestFiles(
        _ files: [URL],
        cameraType: CameraType,
        dryRun: Bool
    ) async {
        guard !isRunning else { return }
        resetCounters()
        isRunning = true
        lastError = nil
        cancelToken = CancelToken()
        let token = cancelToken

        statusMessage = "processing \(files.count) files…"

        do {
            totalFiles = files.count
            try await buildWeatherIndex(forFiles: files)
            let dbWriter: DatabaseWriter? =
                dryRun ? nil : Database.shared.writer

            var pendingBatch: [ImageRecord] = []
            pendingBatch.reserveCapacity(Self.insertBatchSize)

            for file in files {
                try token.checkCancelled()
                if let record = await processFile(
                    file, cameraType: cameraType
                ) {
                    if dbWriter != nil {
                        pendingBatch.append(record)
                    } else {
                        inserted += 1
                    }
                }
                processed += 1

                if let dbWriter,
                   pendingBatch.count >= Self.insertBatchSize {
                    await flushPendingBatch(&pendingBatch, into: dbWriter)
                }
            }

            if let dbWriter, !pendingBatch.isEmpty {
                await flushPendingBatch(&pendingBatch, into: dbWriter)
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

    /// Cache of the meteoblue-forecast hours covering the ingest batch.
    /// Updated alongside `latestWeatherReadings` and queried per frame
    /// via `nearestMeteoblueHour(to:)`.
    private var latestMeteoblueHours: [SupabaseClient.MeteoblueHour] = []

    /// Fetch one batch of Supabase `cloudwatcher_readings` + the
    /// matching `meteoblue_hourly` rows covering the folder's time
    /// range, so per-file lookups are O(n) over an in-memory array
    /// rather than 2n network round-trips. No-op when Supabase is not
    /// configured. Meteoblue failures are swallowed — forecast
    /// enrichment is nice-to-have, not required for ingest to succeed.
    private func buildWeatherIndex(forFiles files: [URL]) async throws {
        latestWeatherReadings = []
        latestMeteoblueHours = []
        guard SupabaseClient.shared.loadConfig() != nil else { return }
        guard let range = timeRange(of: files) else { return }

        statusMessage = "fetching weather for \(range.lowerBound.iso8601Short()) … \(range.upperBound.iso8601Short())"

        // Widen ±10 min for cloudwatcher (5-min cadence) and ±30 min
        // for meteoblue (hourly) so frames at the edges still match.
        let cwLower = range.lowerBound.addingTimeInterval(-600)
        let cwUpper = range.upperBound.addingTimeInterval(600)
        latestWeatherReadings = try await SupabaseClient.shared
            .fetchCloudwatcherReadings(from: cwLower, to: cwUpper)

        let mbLower = range.lowerBound.addingTimeInterval(-1800)
        let mbUpper = range.upperBound.addingTimeInterval(1800)
        do {
            latestMeteoblueHours = try await SupabaseClient.shared
                .fetchMeteoblueHours(from: mbLower, to: mbUpper)
        } catch {
            latestMeteoblueHours = []
        }
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

    /// Batch size for the ingest write pipeline. 500 was chosen by
    /// back-of-the-envelope: GRDB BEGIN/COMMIT overhead dominates
    /// below ~50, memory of pending records grows past ~2 000, and
    /// cancellation latency grows linearly with the batch size (the
    /// cancel-check only runs between batches, not inside one).
    private static let insertBatchSize = 500

    /// Build an `ImageRecord` for a single file. Returns `nil` if the
    /// file should be skipped (unknown extension, no timestamp). No DB
    /// writes — the caller stages records in a batch and hands them to
    /// `flushPendingBatch` when the batch fills up.
    private func processFile(
        _ fileURL: URL,
        cameraType: CameraType
    ) async -> ImageRecord? {
        guard let cameraSource = cameraType.cameraSource(for: fileURL.pathExtension) else {
            skippedUnknownExtension += 1
            return nil
        }

        let meta = MetaJsonReader.read(for: fileURL)
        if meta != nil { enrichedWithMeta += 1 }

        guard let captureUtc = timestamp(for: fileURL, meta: meta) else {
            skippedNoTimestamp += 1
            return nil
        }

        let matchedReading = nearestReading(to: captureUtc)
        if matchedReading != nil { enrichedWithWeather += 1 }

        let matchedMeteoblue = nearestMeteoblueHour(to: captureUtc)

        let record = classify(
            filePath: fileURL.path,
            cameraSource: cameraSource,
            cameraType: cameraType,
            captureUtc: captureUtc,
            matchedReading: matchedReading,
            meteoblueHour: matchedMeteoblue,
            meta: meta
        )

        if record.isExcluded { excluded += 1 }
        if record.reflectionRiskScore >= 0.5 { reflectionFlagged += 1 }
        if record.transitionalRiskScore >= 0.7 { transitionalFlagged += 1 }

        return record
    }

    /// Commit the staged batch in a single GRDB write transaction.
    /// Each row is still checked for an existing `filePath` before
    /// insert so re-ingesting a folder is a no-op; the difference vs.
    /// the old per-file path is that SELECT + INSERT both live inside
    /// one transaction per 500 rows instead of one transaction per
    /// row. At 20 000 files that's ~40 transactions instead of 20 000.
    private func flushPendingBatch(
        _ batch: inout [ImageRecord],
        into db: DatabaseWriter
    ) async {
        guard !batch.isEmpty else { return }
        // Keep the working copy until the write transaction
        // succeeds — a GRDB error used to wipe `batch.removeAll`
        // early and orphan up to 500 staged frames. Only clear on
        // successful commit so a retry or a later `defer`-driven
        // flush can still pick them up.
        let records = batch
        do {
            let newInsertCount = try await db.write { db -> Int in
                var insertedInBatch = 0
                for record in records {
                    let existing = try ImageRecord
                        .filter(ImageRecord.Columns.filePath == record.filePath)
                        .fetchOne(db)
                    if existing == nil {
                        var mutable = record
                        try mutable.insert(db)
                        insertedInBatch += 1
                    }
                }
                return insertedInBatch
            }
            inserted += newInsertCount
            batch.removeAll(keepingCapacity: true)
        } catch {
            lastError = "Batch insert failed (\(records.count) records): \(error)"
            // Leave `batch` intact so the caller's retry path — or
            // the final flush in the `defer` — can try again.
        }
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

    /// Nearest meteoblue-forecast hour within ±30 min of the frame.
    /// Forecasts are hourly so the matching window is correspondingly
    /// wider than the cloudwatcher ±5 min. Returns the full row so the
    /// caller can both (a) store the FK and (b) denormalise the
    /// forecast values onto the image row for the aux features.
    private func nearestMeteoblueHour(
        to captureUtc: Date
    ) -> SupabaseClient.MeteoblueHour? {
        guard !latestMeteoblueHours.isEmpty else { return nil }
        var best: SupabaseClient.MeteoblueHour?
        var bestDelta = TimeInterval.greatestFiniteMagnitude
        for hour in latestMeteoblueHours {
            let delta = abs(hour.timestamp.timeIntervalSince(captureUtc))
            if delta < bestDelta {
                bestDelta = delta
                best = hour
            }
        }
        return bestDelta <= 1800 ? best : nil
    }

    // MARK: - Classification

    private func classify(
        filePath: String,
        cameraSource: ImageRecord.CameraSource,
        cameraType: CameraType,
        captureUtc: Date,
        matchedReading: SupabaseClient.CloudwatcherReading?,
        meteoblueHour: SupabaseClient.MeteoblueHour?,
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
            meteoblueHourId: meteoblueHour?.id,
            meteoblueTotalCloud: meteoblueHour?.totalcloud,
            meteoblueSeeingArcsec: meteoblueHour?.seeingArcsec,
            cloudwatcherSkyTempC: matchedReading?.skyTemperature,
            cloudwatcherSkyQualityRaw: matchedReading?.skyQualityRaw,
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
