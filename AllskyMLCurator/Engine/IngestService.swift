import Foundation
import GRDB
import SwiftUI

/// Ingest orchestrator for Phase 1.
///
/// Given a date range, queries the astro-weather Supabase project for
/// all `cloudwatcher_readings` rows with at least one populated image
/// URL, remaps NAS paths to the SMB mount, matches each row to a
/// `CameraProfile`, pre-computes ephemeris + reflection + transitional
/// risk scores, and inserts corresponding `ImageRecord` rows into the
/// local SQLite database.
///
/// `dryRun = true` performs every step except the database write, so
/// the UI can show expected counts before committing. The Phase 2
/// thumbnail + embedding pipeline runs on the populated `images` rows
/// in a later stage.
@MainActor
final class IngestService: ObservableObject {

    // MARK: - Observable state

    /// Total readings returned by the Supabase query (whole batch).
    @Published private(set) var totalReadings: Int = 0
    /// Readings examined so far in the current run.
    @Published private(set) var processed: Int = 0
    /// `ImageRecord` rows successfully inserted (or counted, for dry-run).
    @Published private(set) var inserted: Int = 0
    /// Rows skipped because the file is not on the SMB mount.
    @Published private(set) var skippedMissingFile: Int = 0
    /// Rows skipped because no camera profile matched.
    @Published private(set) var skippedNoProfile: Int = 0
    /// Rows set to `is_excluded = 1` (mono camera during sun_alt > -6°).
    @Published private(set) var excluded: Int = 0
    /// Rows flagged by the reflection prefilter (score ≥ 0.5).
    @Published private(set) var reflectionFlagged: Int = 0
    /// Rows flagged as likely transitional / gain-settling (score ≥ 0.7).
    @Published private(set) var transitionalFlagged: Int = 0
    /// Human-readable status message surfaced in the UI.
    @Published private(set) var statusMessage: String = "idle"
    /// True while a run is in progress.
    @Published private(set) var isRunning: Bool = false
    /// Last error (if any) from the most recent run.
    @Published private(set) var lastError: String?

    // MARK: - Control

    private var cancelToken = CancelToken()

    /// Main entry point. `dryRun = true` runs the full query and
    /// classification but does not write to the local DB.
    func ingest(
        from: Date,
        to: Date,
        dryRun: Bool
    ) async {
        guard !isRunning else { return }
        await MainActor.run { self.resetCounters() }
        isRunning = true
        lastError = nil
        statusMessage = dryRun ? "dry-run: querying Supabase…" : "querying Supabase…"
        cancelToken = CancelToken()
        let token = cancelToken

        do {
            let readings = try await SupabaseClient.shared
                .fetchCloudwatcherReadings(from: from, to: to)
            await MainActor.run { self.totalReadings = readings.count }
            statusMessage = "processing \(readings.count) readings…"

            try await process(
                readings: readings, dryRun: dryRun, token: token
            )

            statusMessage = dryRun
                ? "dry-run done — \(inserted) would be inserted"
                : "ingest done — \(inserted) inserted"
        } catch is CancellationError {
            statusMessage = "cancelled"
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            statusMessage = "failed: \(lastError ?? "?")"
        }

        isRunning = false
    }

    /// Request cancellation of the current run. Safe to call from any thread.
    func cancel() {
        cancelToken.cancel()
    }

    // MARK: - Processing

    private func process(
        readings: [SupabaseClient.CloudwatcherReading],
        dryRun: Bool,
        token: CancelToken
    ) async throws {
        // Resolve dependencies once per run.
        let settings = AppSettings.shared
        let profileStore = CameraProfileStore.shared

        // The DB writer is touched only in non-dry-run mode.
        let dbWriter: DatabaseWriter? = dryRun ? nil : Database.shared.writer

        for reading in readings {
            try token.checkCancelled()

            // Each Supabase row can have 1..3 image URLs (color + mono JPG + mono FITS).
            var candidates: [(ImageRecord.CameraSource, String)] = []
            if let path = reading.allskyUrl  { candidates.append((.colorAllskyJpg, path)) }
            if let path = reading.zwoUrl     { candidates.append((.monoZwoJpg, path)) }
            if let path = reading.zwoFitsUrl { candidates.append((.monoZwoFits, path)) }

            for (cameraSource, nasPath) in candidates {
                guard let profile = profileStore.profile(for: cameraSource) else {
                    skippedNoProfile += 1
                    continue
                }

                let localPath = remap(
                    nasPath: nasPath,
                    fromPrefix: settings.nasPathPrefix,
                    toMount: settings.allskyMountPath
                )

                // Skip when the SMB mount doesn't actually hold this file —
                // dry-run still records the skip so the user sees the count.
                if !FileManager.default.fileExists(atPath: localPath) {
                    skippedMissingFile += 1
                    continue
                }

                let record = classify(
                    reading: reading,
                    cameraSource: cameraSource,
                    localPath: localPath,
                    profile: profile,
                    settings: settings
                )

                if record.isExcluded { excluded += 1 }
                if record.reflectionRiskScore >= 0.5 { reflectionFlagged += 1 }
                if record.transitionalRiskScore >= 0.7 { transitionalFlagged += 1 }

                if let dbWriter {
                    try await insertIfNew(record, into: dbWriter)
                }
                inserted += 1
            }

            processed += 1
        }
    }

    // MARK: - Classification

    private func classify(
        reading: SupabaseClient.CloudwatcherReading,
        cameraSource: ImageRecord.CameraSource,
        localPath: String,
        profile: CameraProfile,
        settings: AppSettings
    ) -> ImageRecord {
        let sun = Ephemeris.sun(
            at: reading.timestamp,
            latitudeDeg: profile.site.latitudeDeg,
            longitudeDeg: profile.site.longitudeDeg
        )
        let moon = Ephemeris.moon(
            at: reading.timestamp,
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

        // The statistical part of TransitionalDetector needs histogram
        // stats from the file itself. For Phase 1 ingest we only evaluate
        // the geometric trigger so the counter is still meaningful — the
        // statistical refinement happens when the embedding pipeline opens
        // the image in Phase 2.
        let transitionalScoreGeometric: Double =
            TransitionalDetector.transitionWindowDeg.contains(sun.horizontal.altitudeDeg)
            && profile.sensor.dayCapable
            ? 0.5
            : 0.0

        return ImageRecord(
            id: nil,
            filePath: localPath,
            fileHashSha256: nil,
            cameraSource: cameraSource,
            cameraProfileId: profile.id,
            captureUtc: reading.timestamp,
            timeOfDay: sun.timeOfDay,
            supabaseReadingId: reading.id,
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

    /// Insert a record if no row with the same `file_path` exists yet.
    /// Unchanged rows are left alone so repeated ingest runs are idempotent.
    private func insertIfNew(_ record: ImageRecord, into db: DatabaseWriter) async throws {
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

    // MARK: - Path remapping

    /// Rewrite a Synology NAS path (`/volume1/AllSky-Rheine/...`) to the
    /// local SMB mount (`/Volumes/AllSky-Rheine/...`). Paths that don't
    /// match the known prefix are returned unchanged — the existence
    /// check downstream then skips them.
    private func remap(nasPath: String, fromPrefix: String, toMount: String) -> String {
        if nasPath.hasPrefix(fromPrefix) {
            return toMount + String(nasPath.dropFirst(fromPrefix.count))
        }
        return nasPath
    }

    // MARK: - Counters

    private func resetCounters() {
        totalReadings = 0
        processed = 0
        inserted = 0
        skippedMissingFile = 0
        skippedNoProfile = 0
        excluded = 0
        reflectionFlagged = 0
        transitionalFlagged = 0
    }

    // MARK: - Cancellation token

    /// Lightweight cancel flag used instead of Swift Task cancellation so
    /// a cancel request from the UI (button press) can surface without
    /// passing the enclosing Task around.
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
