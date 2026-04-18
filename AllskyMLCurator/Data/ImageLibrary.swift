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
        limit: Int? = nil
    ) async -> [ImageListItem] {
        let reader = Database.shared.reader
        do {
            return try await reader.read { db in
                var builder: QueryInterfaceRequest<ImageRecord> = ImageRecord.all()

                if !includeExcluded {
                    builder = builder.filter(ImageRecord.Columns.isExcluded == false)
                }
                if let cameraType {
                    let sources = Self.sources(for: cameraType)
                    builder = builder.filter(sources.contains(ImageRecord.Columns.cameraSource))
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
    func fetchRatedImages() async -> [ImageRecord] {
        let reader = Database.shared.reader
        return (try? await reader.read { db in
            let ratedIds = try LabelRecord
                .filter(Column("isCurrent") == true)
                .filter(Column("source") == "human")
                .filter(Column("ratingClass") != RatingClass.unrated.rawValue)
                .select(Column("imageId"), as: Int64.self)
                .fetchAll(db)
            guard !ratedIds.isEmpty else { return [] }
            return try ImageRecord
                .filter(ratedIds.contains(Column("id")))
                .order(Column("captureUtc").asc)
                .fetchAll(db)
        }) ?? []
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
    /// label, if any, is demoted to `isCurrent=false`; a future manual
    /// rating from the curator will override. Never used to overwrite
    /// an existing human rating — the caller is expected to filter to
    /// unrated frames before calling.
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
}
