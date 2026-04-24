import Foundation
import GRDB

/// Read/write helpers for the matrix view and rating workflow.
///
/// `Database.shared` owns the pool; `ImageLibrary` wraps common
/// queries in typed methods so the UI doesn't have to embed SQL.
///
/// All public methods are `async` and dispatch onto the DB pool's
/// read/write queues — safe to call from `@MainActor` SwiftUI code
/// without blocking.
@MainActor
final class ImageLibrary: ObservableObject {

    // MARK: - Singleton

    static let shared = ImageLibrary()
    private init() {}

    // MARK: - Listing

    /// Pair of an image row with its current active label (if any).
    struct ImageListItem: Equatable, Identifiable {
        let image: ImageRecord
        let label: LabelRecord?
        var id: Int64 { image.id ?? 0 }
    }

    /// Ordered list of eligible images for the matrix view.
    /// Filter predicates:
    ///   - `cameraType`: nil = all cameras; else filter by cameraSource.cameraType
    ///   - `includeExcluded`: true retains mono-daylight rows (normally hidden)
    ///   - `onlyUnrated`: true restricts to class == 0 (or no active label)
    ///   - `limit`: cap on results. Defaults to `nil` (unbounded) so a
    ///     20 000+ frame library renders fully in the matrix — LazyVGrid
    ///     only materialises visible tiles anyway, and the item array
    ///     itself at 20 k × ~500 bytes ≈ 10 MB is inconsequential. The
    ///     previous 10 000 cap silently truncated larger libraries.
    func fetchImages(
        cameraType: CameraType? = nil,
        includeExcluded: Bool = false,
        ratingFilter: RatingFilter = .any,
        maxSunAltDeg: Double? = nil,
        minSunAltDeg: Double? = nil,
        limit: Int? = nil
    ) async -> [ImageListItem] {
        let reader = Database.shared.reader
        do {
            return try await reader.read { db in
                var builder: QueryInterfaceRequest<ImageRecord> = ImageRecord.all()

                // 0.8.6: the `.excluded` rating filter is a view of
                // soft-excluded frames (the trash bin). It overrides
                // the default `includeExcluded=false` gate and further
                // restricts to `isExcluded == true` — so the curator
                // sees exactly the exclude pile, no mixing.
                if ratingFilter.isExcludedView {
                    builder = builder.filter(ImageRecord.Columns.isExcluded == true)
                } else if !includeExcluded {
                    builder = builder.filter(ImageRecord.Columns.isExcluded == false)
                }
                if let cameraType {
                    let sources = Self.sources(for: cameraType)
                    builder = builder.filter(sources.contains(ImageRecord.Columns.cameraSource))
                }
                if let maxSunAltDeg {
                    // Night-only filter — drop any frame whose sun is
                    // higher than this threshold. Soft: the rows stay
                    // in the table, we just don't surface them.
                    builder = builder.filter(Column("sunAltDeg") <= maxSunAltDeg)
                }
                if let minSunAltDeg {
                    // Day-only filter — inverse of night-only. Both
                    // can technically compose (yielding no rows) but
                    // the UI prevents that by toggling them exclusively.
                    builder = builder.filter(Column("sunAltDeg") >= minSunAltDeg)
                }
                builder = builder.order(ImageRecord.Columns.captureUtc.asc)
                if let limit { builder = builder.limit(limit) }

                let images = try builder.fetchAll(db)

                // Fetch the current active label for each image in one
                // query, build a dictionary, then zip.
                let imageIds = images.compactMap(\.id)
                let labels = try LabelRecord
                    .filter(imageIds.contains(Column("imageId")))
                    .filter(Column("isCurrent") == true)
                    .fetchAll(db)
                let labelById = Dictionary(
                    uniqueKeysWithValues: labels.map { ($0.imageId, $0) }
                )

                var results = images.map { img -> ImageListItem in
                    let label = img.id.flatMap { labelById[$0] }
                    return ImageListItem(image: img, label: label)
                }

                if case .any = ratingFilter {
                    // no-op — most common case, skip predicate allocation
                } else {
                    results = results.filter { item in
                        let cls = item.label?.ratingClass ?? .unrated
                        return ratingFilter.includes(cls)
                    }
                }
                return results
            }
        } catch {
            NSLog("ImageLibrary.fetchImages failed: \(error)")
            return []
        }
    }

    /// Every image that currently carries a non-unrated human label.
    /// Used by the app-start embedding warmer so the classifier's
    /// training set grows even if the user rated frames without
    /// scrolling through every tile.
    ///
    /// 0.8.8: optional `maxSunAltDeg` / `minSunAltDeg` filters so
    /// the warmer can honour the Night-only / Day-only app setting
    /// and skip frames that will never enter training. Defaults to
    /// nil (no filter) — callers that don't care about sun altitude
    /// keep the original behaviour.
    func fetchRatedImages(
        maxSunAltDeg: Double? = nil,
        minSunAltDeg: Double? = nil
    ) async -> [ImageRecord] {
        let reader = Database.shared.reader
        return (try? await reader.read { db in
            let ratedIds = try LabelRecord
                .filter(Column("isCurrent") == true)
                .filter(Column("source") == "human")
                .filter(Column("ratingClass") != RatingClass.unrated.rawValue)
                .select(Column("imageId"), as: Int64.self)
                .fetchAll(db)
            guard !ratedIds.isEmpty else { return [] }
            var builder = ImageRecord
                .filter(ratedIds.contains(Column("id")))
            if let maxSunAltDeg {
                builder = builder.filter(Column("sunAltDeg") <= maxSunAltDeg)
            }
            if let minSunAltDeg {
                builder = builder.filter(Column("sunAltDeg") >= minSunAltDeg)
            }
            return try builder
                .order(Column("captureUtc").asc)
                .fetchAll(db)
        }) ?? []
    }

    /// Every non-excluded image that currently has no active
    /// human label (so no rating at all, or a rating that was
    /// later demoted to `isCurrent=false`). Drives the unrated
    /// half of the embedding warmer — without embeddings for
    /// these frames the classifier has no prediction to show,
    /// so the matrix shows no brain badges.
    ///
    /// 0.8.8: same `maxSunAltDeg` / `minSunAltDeg` filter as
    /// `fetchRatedImages` so the warmer can honour Night-only /
    /// Day-only and skip ~61 % of the work on a night-focused
    /// library (Rheine captures more daytime than nighttime frames
    /// per UTC day).
    func fetchUnratedImages(
        maxSunAltDeg: Double? = nil,
        minSunAltDeg: Double? = nil
    ) async -> [ImageRecord] {
        let reader = Database.shared.reader
        return (try? await reader.read { db in
            let ratedIds = try LabelRecord
                .filter(Column("isCurrent") == true)
                .filter(Column("source") == "human")
                .filter(Column("ratingClass") != RatingClass.unrated.rawValue)
                .select(Column("imageId"), as: Int64.self)
                .fetchAll(db)
            let ratedSet = Set(ratedIds)
            var builder = ImageRecord
                .filter(ImageRecord.Columns.isExcluded == false)
            if let maxSunAltDeg {
                builder = builder.filter(Column("sunAltDeg") <= maxSunAltDeg)
            }
            if let minSunAltDeg {
                builder = builder.filter(Column("sunAltDeg") >= minSunAltDeg)
            }
            let allImages = try builder
                .order(Column("captureUtc").asc)
                .fetchAll(db)
            return allImages.filter { image in
                guard let id = image.id else { return false }
                return !ratedSet.contains(id)
            }
        }) ?? []
    }

    // MARK: - Removal

    /// Delete the given image rows from the local index and purge
    /// their cached sidecars (thumbnail HEIC + Vision FeaturePrint).
    /// 0.8.6: soft-exclude instead of hard-delete. Previously this
    /// ran `DELETE FROM images` which dropped the row entirely — the
    /// weather-filtered ingest (`WeatherIngestSheet` / `IngestService`)
    /// deduplicates by `filePath` only, so on the next re-ingest the
    /// "deleted" files walked straight back in because the DB no
    /// longer knew about their paths. User-visible effect: the Delete
    /// action felt useless.
    ///
    /// New behaviour: flip `is_excluded = 1`, keep the row (and its
    /// labels + predictions for audit). The matrix already filters
    /// out excluded rows (`fetchImages` default `includeExcluded =
    /// false`) and the trainer already skips them, so the tiles
    /// disappear from view exactly like before. Crucially the
    /// filePath stays in the DB, so re-ingest dedup recognises the
    /// file and won't re-insert a duplicate row.
    ///
    /// Thumbnails + Vision FeaturePrint sidecars are still purged —
    /// they're disposable and reclaim real disk space. If the user
    /// ever un-excludes a row (not yet wired), the warmer regenerates
    /// them.
    ///
    /// Supabase `ml_training_samples` is untouched (same as before) —
    /// image rows never sync upstream anyway.
    ///
    /// Returns the number of rows flipped.
    @discardableResult
    func deleteImages(_ imageIds: [Int64]) async -> Int {
        guard !imageIds.isEmpty else { return 0 }

        // Read the paths + camera sources BEFORE we touch the rows so
        // we can purge the right HEIC + .fp sidecars afterwards.
        // Filter to rows that are currently `isExcluded == false` —
        // already-excluded rows don't need a second flip or a second
        // round of cache-purging.
        let reader = Database.shared.reader
        let doomed: [(path: String, camera: CameraType)] = (
            try? await reader.read { db in
                try ImageRecord
                    .filter(imageIds.contains(Column("id")))
                    .filter(ImageRecord.Columns.isExcluded == false)
                    .fetchAll(db)
                    .compactMap { image in
                        (image.filePath, image.cameraSource.cameraType)
                    }
            }
        ) ?? []

        var excludedCount = 0
        do {
            try await Database.shared.writer.write { db in
                excludedCount = try ImageRecord
                    .filter(imageIds.contains(Column("id")))
                    .filter(ImageRecord.Columns.isExcluded == false)
                    .updateAll(
                        db,
                        ImageRecord.Columns.isExcluded.set(to: true)
                    )
            }
        } catch {
            NSLog("ImageLibrary.deleteImages soft-exclude failed: \(error)")
            return 0
        }

        // Reclaim disk: thumbnails + embedding sidecars are cheap to
        // regenerate, so purging on exclude is a clear win.
        for entry in doomed {
            ThumbnailCache.shared.purgeCache(
                for: entry.path, cameraType: entry.camera
            )
            EmbeddingPipeline.shared.purgeCache(for: entry.path)
        }
        return excludedCount
    }

    /// 0.8.6: inverse of the soft-exclude. Flips `is_excluded` back
    /// to 0 so the frame re-enters the matrix + training set on the
    /// next reload. Thumbnails + embedding sidecars were purged on
    /// exclude (to reclaim disk); the warmer regenerates them on the
    /// next coverage pass. No Supabase call — image rows never
    /// travel upstream.
    ///
    /// Returns the number of rows actually un-excluded.
    @discardableResult
    func restoreImages(_ imageIds: [Int64]) async -> Int {
        guard !imageIds.isEmpty else { return 0 }
        do {
            return try await Database.shared.writer.write { db in
                try ImageRecord
                    .filter(imageIds.contains(Column("id")))
                    .filter(ImageRecord.Columns.isExcluded == true)
                    .updateAll(
                        db,
                        ImageRecord.Columns.isExcluded.set(to: false)
                    )
            }
        } catch {
            NSLog("ImageLibrary.restoreImages failed: \(error)")
            return 0
        }
    }

    // MARK: - Rating writes

    /// Apply a class rating (0-5) to one or more images. Existing
    /// active labels for the same image are demoted to `isCurrent=false`
    /// so the history is preserved without UNIQUE constraint churn.
    /// Reflection / transitional flags on a prior active label are
    /// carried forward unless `resetFlags` is `true`. `confidence` is
    /// forwarded into `labels.confidence` (1 = quick, 2 = normal,
    /// 3 = certain) — `nil` leaves the column null, matching the
    /// default digit-press behaviour.
    func setRating(
        _ ratingClass: RatingClass,
        forImageIds imageIds: [Int64],
        resetFlags: Bool = false,
        confidence: Int? = nil
    ) async {
        await withDB { db in
            for imageId in imageIds {
                let previous = try LabelRecord
                    .filter(Column("imageId") == imageId)
                    .filter(Column("isCurrent") == true)
                    .fetchOne(db)
                if var prev = previous {
                    prev.isCurrent = false
                    try prev.update(db)
                }
                var label = LabelRecord.human(
                    imageId: imageId,
                    ratingClass: ratingClass,
                    reflection: resetFlags ? false : (previous?.reflectionFlag ?? false),
                    transitional: resetFlags ? false : (previous?.transitionalFlag ?? false),
                    confidence: confidence
                )
                try label.insert(db)
            }
        }
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Apply a provisional machine rating (`source='auto'`) to every
    /// image id — used by the autonomous rater. The previous active
    /// label is demoted to `isCurrent=false` **only when it's not a
    /// human rating** — otherwise the auto path would silently
    /// overwrite work the curator applied mid-stream (e.g., they
    /// corrected a tile while the streamer was still queuing up
    /// writes to it). Human labels, once attached, can only be
    /// replaced by further human input.
    func setAutoRating(
        _ ratingClass: RatingClass,
        forImageIds imageIds: [Int64]
    ) async {
        await withDB { db in
            for imageId in imageIds {
                let previous = try LabelRecord
                    .filter(Column("imageId") == imageId)
                    .filter(Column("isCurrent") == true)
                    .fetchOne(db)
                // Guard: leave any current human label in place and
                // skip the insert. The auto stream is advisory —
                // never authoritative over a human decision.
                if let prev = previous, prev.source == .human {
                    continue
                }
                if var prev = previous {
                    prev.isCurrent = false
                    try prev.update(db)
                }
                var label = LabelRecord.auto(
                    imageId: imageId,
                    ratingClass: ratingClass
                )
                try label.insert(db)
            }
        }
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Count of human-sourced, non-unrated, currently-active labels —
    /// feeds the autonomous-mode gate (the 200-label minimum guards
    /// against confirmation bias on a freshly seeded classifier).
    func humanLabelCount() async -> Int {
        let reader = Database.shared.reader
        return (try? await reader.read { db in
            try LabelRecord
                .filter(Column("isCurrent") == true)
                .filter(Column("source") == "human")
                .filter(Column("ratingClass") != RatingClass.unrated.rawValue)
                .fetchCount(db)
        }) ?? 0
    }

    /// Toggle the reflection (`R`) flag on one or more images. If the
    /// image has no active label yet, a fresh one is created with
    /// class=unrated + reflection_flag=true. Triggers a background
    /// Supabase sync after the write.
    func toggleReflection(forImageIds imageIds: [Int64]) async {
        await toggleFlag(on: imageIds, flagPath: \.reflectionFlag) {
            $0.reflectionFlag.toggle()
        }
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Toggle the transitional (`T`) flag on one or more images.
    /// Triggers a background Supabase sync after the write.
    func toggleTransitional(forImageIds imageIds: [Int64]) async {
        await toggleFlag(on: imageIds, flagPath: \.transitionalFlag) {
            $0.transitionalFlag.toggle()
        }
        Task { await SyncEngine.shared.pushPending() }
    }

    // MARK: - Helpers

    /// Map a coarse `CameraType` back to the three `CameraSource`
    /// enum cases it covers. Used as a WHERE-IN filter. Marked
    /// `nonisolated` so it can be called from inside a GRDB read
    /// closure, which runs on a DB pool queue rather than MainActor.
    nonisolated private static func sources(for cameraType: CameraType) -> [String] {
        switch cameraType {
        case .color:      return [ImageRecord.CameraSource.colorAllskyJpg.rawValue]
        case .monochrome: return [
            ImageRecord.CameraSource.monoAllskyJpg.rawValue,
            ImageRecord.CameraSource.monoAllskyFits.rawValue
        ]
        }
    }

    private func toggleFlag(
        on imageIds: [Int64],
        flagPath: KeyPath<LabelRecord, Bool>,
        mutator: @Sendable @escaping (inout LabelRecord) -> Void
    ) async {
        let writer = Database.shared.writer
        do {
            try await writer.write { db in
                for imageId in imageIds {
                    let existing = try LabelRecord
                        .filter(Column("imageId") == imageId)
                        .filter(Column("isCurrent") == true)
                        .fetchOne(db)
                    if var label = existing {
                        mutator(&label)
                        label.labeledAt = Date()
                        label.syncedToSupabase = false
                        try label.update(db)
                    } else {
                        var label = LabelRecord.human(
                            imageId: imageId,
                            ratingClass: .unrated
                        )
                        mutator(&label)
                        try label.insert(db)
                    }
                }
            }
        } catch {
            NSLog("ImageLibrary.toggleFlag failed: \(error)")
        }
    }

    private func withDB(_ body: @escaping (GRDB.Database) throws -> Void) async {
        let writer = Database.shared.writer
        do {
            try await writer.write { db in
                try body(db)
            }
        } catch {
            NSLog("ImageLibrary DB write failed: \(error)")
        }
    }

    // MARK: - SQM backfill (0.7.2)

    /// Progress emitted by the SQM backfill so the Preferences UI can
    /// show a live counter. All values are cumulative since `run` was
    /// called.
    struct SkyQualityBackfillProgress: Equatable, Sendable {
        var totalEligible: Int
        var batchesDone: Int
        var totalBatches: Int
        var rowsUpdated: Int
        var rowsMissing: Int     // id was set but Supabase returned no match
    }

    /// Result summary returned when the backfill completes (or is
    /// cancelled). `durationSeconds` is wall-clock time including
    /// Supabase round-trips.
    struct SkyQualityBackfillResult: Equatable, Sendable {
        var totalEligible: Int
        var rowsUpdated: Int
        var rowsMissing: Int
        var rowsSkippedNoSqmOnReading: Int
        var durationSeconds: Double
    }

    /// Walk every image row with `supabaseReadingId != nil` and
    /// `cloudwatcherSkyQualityRaw IS NULL`, batch-fetch the
    /// corresponding `cloudwatcher_readings` rows from Supabase, and
    /// write `sky_quality_raw` into the local image row.
    ///
    /// Batches of 500 ids per request — PostgREST's `in.()` filter
    /// takes a URL-encoded list, so we stay well under the URL limit.
    /// `progress` fires after each batch commits so the UI can
    /// animate smoothly; cancellation is checked before each batch.
    func backfillSkyQuality(
        progress: @Sendable @escaping (SkyQualityBackfillProgress) -> Void
    ) async -> SkyQualityBackfillResult {
        let started = Date()
        let reader = Database.shared.reader
        let writer = Database.shared.writer

        // Gather (imageId, readingId) pairs for rows that still need
        // SQM. Keep the initial read small — we only need two Int64s
        // per row.
        let eligible: [(imageId: Int64, readingId: Int64)] = (try? await reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, supabaseReadingId
                FROM images
                WHERE supabaseReadingId IS NOT NULL
                  AND cloudwatcherSkyQualityRaw IS NULL
                ORDER BY id ASC
            """)
            return rows.compactMap { row -> (Int64, Int64)? in
                guard let imgId: Int64 = row["id"],
                      let rid: Int64 = row["supabaseReadingId"]
                else { return nil }
                return (imgId, rid)
            }
        }) ?? []

        if eligible.isEmpty {
            return SkyQualityBackfillResult(
                totalEligible: 0,
                rowsUpdated: 0,
                rowsMissing: 0,
                rowsSkippedNoSqmOnReading: 0,
                durationSeconds: Date().timeIntervalSince(started)
            )
        }

        // Group image ids by their reading id so a single SQM
        // response can update all images that shared a reading.
        var imagesByReading: [Int64: [Int64]] = [:]
        for pair in eligible {
            imagesByReading[pair.readingId, default: []].append(pair.imageId)
        }
        let uniqueReadingIds = Array(imagesByReading.keys).sorted()
        let batchSize = 500
        let totalBatches = (uniqueReadingIds.count + batchSize - 1) / batchSize

        progress(SkyQualityBackfillProgress(
            totalEligible: eligible.count,
            batchesDone: 0,
            totalBatches: totalBatches,
            rowsUpdated: 0,
            rowsMissing: 0
        ))

        var rowsUpdated = 0
        var rowsMissing = 0
        var rowsSkippedNoSqmOnReading = 0

        for (batchIdx, start) in stride(from: 0, to: uniqueReadingIds.count, by: batchSize).enumerated() {
            if Task.isCancelled { break }

            let batch = Array(
                uniqueReadingIds[start ..< min(start + batchSize, uniqueReadingIds.count)]
            )

            let readings: [SupabaseClient.CloudwatcherReading]
            do {
                readings = try await SupabaseClient.shared
                    .fetchCloudwatcherReadings(ids: batch)
            } catch {
                NSLog("SQM backfill batch \(batchIdx + 1) / \(totalBatches) failed: \(error)")
                continue
            }

            // Map reading.id → sky_quality_raw, then write each
            // image row that pointed at that reading.
            let sqmByReading: [Int64: Int?] = Dictionary(
                uniqueKeysWithValues: readings.map { ($0.id, $0.skyQualityRaw) }
            )
            let matchedReadings = Set(readings.map(\.id))
            let batchSet = Set(batch)
            rowsMissing += batchSet.subtracting(matchedReadings).count

            try? await writer.write { db in
                for readingId in batch {
                    guard let imageIds = imagesByReading[readingId] else { continue }
                    guard let maybeSqm = sqmByReading[readingId] else { continue }
                    guard let sqm = maybeSqm else {
                        rowsSkippedNoSqmOnReading += imageIds.count
                        continue
                    }
                    for imgId in imageIds {
                        try db.execute(
                            sql: "UPDATE images SET cloudwatcherSkyQualityRaw = ? WHERE id = ?",
                            arguments: [sqm, imgId]
                        )
                        rowsUpdated += 1
                    }
                }
            }

            progress(SkyQualityBackfillProgress(
                totalEligible: eligible.count,
                batchesDone: batchIdx + 1,
                totalBatches: totalBatches,
                rowsUpdated: rowsUpdated,
                rowsMissing: rowsMissing
            ))
        }

        return SkyQualityBackfillResult(
            totalEligible: eligible.count,
            rowsUpdated: rowsUpdated,
            rowsMissing: rowsMissing,
            rowsSkippedNoSqmOnReading: rowsSkippedNoSqmOnReading,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }
}
