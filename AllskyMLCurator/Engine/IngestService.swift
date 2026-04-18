import Foundation
import GRDB
import SwiftUI

/// Folder-based ingest for Phase 1.
///
/// The user chooses any folder via `Cmd+O` (parity with AstroBlink's
/// "Open folder" flow). The service walks the folder recursively for
/// supported image extensions, parses a capture timestamp from every
/// filename, matches each file to a `CameraProfile` picked by the user,
/// and pre-computes ephemeris + reflection + geometric transitional
/// risk scores. Supabase is used purely for *enrichment* — if
/// credentials are configured, the service fetches cloudwatcher
/// readings covering the folder's time range in a single batch and
/// attaches the nearest match (within ±5 min) to each image.
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
    @Published private(set) var statusMessage: String = "idle"
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?

    // MARK: - Entry point

    /// Ingest every supported image in `folderURL` as captures from the
    /// camera described by `profileId`.
    func ingestFolder(
        _ folderURL: URL,
        profileId: String,
        dryRun: Bool
    ) async {
        guard !isRunning else { return }
        resetCounters()
        isRunning = true
        lastError = nil
        cancelToken = CancelToken()
        let token = cancelToken

        guard let profile = CameraProfileStore.shared.profile(id: profileId) else {
            statusMessage = "unknown camera profile"
            lastError = "Camera profile '\(profileId)' not found in the bundle."
            isRunning = false
            return
        }

        // Sandbox: keep the folder accessible for the duration of the run.
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { folderURL.stopAccessingSecurityScopedResource() }
        }

        statusMessage = "scanning \(folderURL.lastPathComponent)…"

        do {
            let files = scanFolder(folderURL)
            totalFiles = files.count
            statusMessage = "processing \(files.count) files…"

            let readingsIndex = try await buildWeatherIndex(forFiles: files)
            let dbWriter: DatabaseWriter? =
                dryRun ? nil : Database.shared.writer

            for file in files {
                try token.checkCancelled()
                await processFile(
                    file,
                    profile: profile,
                    readingsIndex: readingsIndex,
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

    /// Walk `folderURL` recursively and return every supported image file,
    /// sorted by path so the UI counter advances in a stable order.
    private func scanFolder(_ folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - Weather enrichment

    /// Build a timestamp-keyed index of Supabase `cloudwatcher_readings`
    /// covering the folder's time range, so per-file lookup is O(log n)
    /// rather than n network round-trips. Returns an empty index when
    /// Supabase is not configured (enrichment becomes a no-op).
    private func buildWeatherIndex(
        forFiles files: [URL]
    ) async throws -> [Date] {
        guard SupabaseClient.shared.loadConfig() != nil else { return [] }
        guard let range = timeRange(of: files) else { return [] }

        statusMessage = "fetching weather for \(range.lowerBound.iso8601Short()) … \(range.upperBound.iso8601Short())"

        // Widen ±10 min so edge files still find a neighbor.
        let lower = range.lowerBound.addingTimeInterval(-600)
        let upper = range.upperBound.addingTimeInterval(600)
        let readings = try await SupabaseClient.shared
            .fetchCloudwatcherReadings(from: lower, to: upper)
        latestWeatherReadings = readings
        return readings.map(\.timestamp).sorted()
    }

    /// Cache of the most recent fetch so `processFile` can look up the
    /// full reading row (not just the timestamp) when it finds a match.
    private var latestWeatherReadings: [SupabaseClient.CloudwatcherReading] = []

    /// Timestamp range covered by the given files, based on filename
    /// parsing + modification-date fallback.
    private func timeRange(of files: [URL]) -> ClosedRange<Date>? {
        var earliest: Date?
        var latest: Date?
        for url in files {
            guard let ts = timestamp(for: url) else { continue }
            earliest = min(earliest ?? ts, ts)
            latest   = max(latest   ?? ts, ts)
        }
        guard let e = earliest, let l = latest else { return nil }
        return e...l
    }

    // MARK: - Per-file processing

    private func processFile(
        _ fileURL: URL,
        profile: CameraProfile,
        readingsIndex: [Date],
        dbWriter: DatabaseWriter?
    ) async {
        guard let cameraSource = cameraSource(for: fileURL, profile: profile) else {
            skippedUnknownExtension += 1
            return
        }

        guard let captureUtc = timestamp(for: fileURL) else {
            skippedNoTimestamp += 1
            return
        }

        let matchedReading = nearestReading(to: captureUtc)
        if matchedReading != nil { enrichedWithWeather += 1 }

        let record = classify(
            filePath: fileURL.path,
            cameraSource: cameraSource,
            captureUtc: captureUtc,
            profile: profile,
            matchedReading: matchedReading
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

    /// Determine the correct `camera_source` for a file given the user's
    /// chosen profile and the file extension.
    private func cameraSource(
        for url: URL, profile: CameraProfile
    ) -> ImageRecord.CameraSource? {
        let ext = url.pathExtension.lowercased()
        switch (profile.sensor.type, ext) {
        case (.color, "jpg"), (.color, "jpeg"):
            return .colorAllskyJpg
        case (.monochrome, "jpg"), (.monochrome, "jpeg"):
            return .monoZwoJpg
        case (.monochrome, "fit"), (.monochrome, "fits"):
            return .monoZwoFits
        default:
            return nil
        }
    }

    /// Timestamp from filename if parseable, else file modification date.
    private func timestamp(for url: URL) -> Date? {
        if let date = FilenameTimestamp.parse(url.lastPathComponent) {
            return date
        }
        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        )
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
        captureUtc: Date,
        profile: CameraProfile,
        matchedReading: SupabaseClient.CloudwatcherReading?
    ) -> ImageRecord {
        let sun = Ephemeris.sun(
            at: captureUtc,
            latitudeDeg: profile.site.latitudeDeg,
            longitudeDeg: profile.site.longitudeDeg
        )
        let moon = Ephemeris.moon(
            at: captureUtc,
            latitudeDeg: profile.site.latitudeDeg,
            longitudeDeg: profile.site.longitudeDeg
        )

        let isExcluded = profile.sensor.isExcludedAtSunAlt(sun.horizontal.altitudeDeg)

        let reflectionScore = ReflectionPrefilter.score(
            .init(
                sunAltDeg: sun.horizontal.altitudeDeg,
                moonAltDeg: moon.horizontal.altitudeDeg,
                moonIlluminationFraction: moon.illumination,
                cameraIsDayCapable: profile.sensor.dayCapable
            )
        )

        // Geometric transitional pre-score — histogram refinement runs
        // later, when the embedding pipeline opens the actual file.
        let transitionalScoreGeometric: Double =
            TransitionalDetector.transitionWindowDeg.contains(sun.horizontal.altitudeDeg)
            && profile.sensor.dayCapable
            ? 0.5
            : 0.0

        return ImageRecord(
            id: nil,
            filePath: filePath,
            fileHashSha256: nil,
            cameraSource: cameraSource,
            cameraProfileId: profile.id,
            captureUtc: captureUtc,
            timeOfDay: sun.timeOfDay,
            supabaseReadingId: matchedReading?.id,
            sunAltDeg: sun.horizontal.altitudeDeg,
            sunAzDeg: sun.horizontal.azimuthDeg,
            moonAltDeg: moon.horizontal.altitudeDeg,
            moonAzDeg: moon.horizontal.azimuthDeg,
            moonPhase: moon.illumination,
            reflectionRiskScore: reflectionScore,
            transitionalRiskScore: transitionalScoreGeometric,
            isExcluded: isExcluded,
            embeddingPath: nil,
            embeddingRevision: 0,
            createdAt: Date()
        )
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
