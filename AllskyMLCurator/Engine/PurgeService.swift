import Foundation
import GRDB

/// Destructive "fresh start" helpers. Each operation is confirmed by
/// the caller (Preferences → Advanced tab), so this service skips
/// its own confirmation and just does what it's told.
///
/// All methods return a short human-readable summary the caller can
/// surface in an inline status line or alert.
enum PurgeService {

    /// Scope of a purge action. Names are chosen to match what the
    /// curator actually lives with day to day — ratings, classifier
    /// model, the two on-disk caches, and the whole local index.
    enum Scope: String, CaseIterable, Identifiable {
        case ratings
        case classifierModel
        case embeddings
        case thumbnails
        case imagesAndCaches
        case everything

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ratings:          return "All ratings"
            case .classifierModel:  return "Trained classifier"
            case .embeddings:       return "Vision embeddings cache"
            case .thumbnails:       return "Thumbnail cache"
            case .imagesAndCaches:  return "Image index + all caches"
            case .everything:       return "Everything (full fresh start)"
            }
        }

        /// Short description shown in the confirmation alert body.
        var explanation: String {
            switch self {
            case .ratings:
                return "Deletes every row in the local `labels` and `predictions` tables. Supabase rows on `ml_training_samples` stay untouched — they'd be re-synced or re-pushed on the next rating. Images and ingested metadata keep their place."
            case .classifierModel:
                return "Wipes the in-memory classifier snapshot and the `model_versions` table. Rerun ⌘T to train fresh. Ratings are not touched."
            case .embeddings:
                return "Removes all cached Vision FeaturePrint sidecars under Library/Caches/AllskyMLCurator/embeddings. The launch-time warmer will rebuild them next session."
            case .thumbnails:
                return "Removes all cached HEIF tile thumbnails. The matrix regenerates them on scroll — first pass will be slow, second session fast again."
            case .imagesAndCaches:
                return "Clears the `images` table (with every label / prediction row cascading), plus the thumbnail and embedding caches. Re-ingest with ⌘O to rebuild the index. Your Supabase ratings survive — only the local index resets."
            case .everything:
                return "Maximum fresh start. Drops every row from every local SQLite table and clears both caches. Supabase rows are untouched so a re-ingest + re-sync would restore synced ratings. Keychain (Supabase URL + anon key) is kept."
            }
        }
    }

    // MARK: - Entry point

    @MainActor
    static func purge(_ scope: Scope) async -> String {
        do {
            switch scope {
            case .ratings:          return try await purgeRatings()
            case .classifierModel:  return try await purgeClassifier()
            case .embeddings:       return purgeDiskCache(at: "embeddings")
            case .thumbnails:       return purgeDiskCache(at: "thumbnails")
            case .imagesAndCaches:  return try await purgeImagesAndCaches()
            case .everything:       return try await purgeEverything()
            }
        } catch {
            return "Purge failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Implementation

    @MainActor
    private static func purgeRatings() async throws -> String {
        let writer = Database.shared.writer
        let result = try await writer.write { db -> (Int, Int) in
            let labelCount = try LabelRecord.deleteAll(db)
            let predictionCount = try PredictionRecord.deleteAll(db)
            return (labelCount, predictionCount)
        }
        await ClassifierEngine.shared.refreshCoverage()
        ClassifierEngine.shared.clear()
        return "Deleted \(result.0) labels and \(result.1) predictions."
    }

    @MainActor
    private static func purgeClassifier() async throws -> String {
        let writer = Database.shared.writer
        let versionCount = try await writer.write { db in
            try ModelVersionRecord.deleteAll(db)
        }
        ClassifierEngine.shared.clear()
        return "Dropped in-memory model and \(versionCount) stored model versions."
    }

    @MainActor
    private static func purgeImagesAndCaches() async throws -> String {
        let writer = Database.shared.writer
        let imageCount = try await writer.write { db -> Int in
            // FK cascades take labels + predictions with the images.
            return try ImageRecord.deleteAll(db)
        }
        ClassifierEngine.shared.clear()
        let thumbs = purgeDiskCache(at: "thumbnails")
        let embs = purgeDiskCache(at: "embeddings")
        return "Cleared \(imageCount) images from the index. \(thumbs). \(embs)."
    }

    @MainActor
    private static func purgeEverything() async throws -> String {
        let writer = Database.shared.writer
        let totals = try await writer.write { db -> (Int, Int, Int, Int) in
            let labels = try LabelRecord.deleteAll(db)
            let preds = try PredictionRecord.deleteAll(db)
            let models = try ModelVersionRecord.deleteAll(db)
            let images = try ImageRecord.deleteAll(db)
            return (labels, preds, models, images)
        }
        ClassifierEngine.shared.clear()
        let thumbs = purgeDiskCache(at: "thumbnails")
        let embs = purgeDiskCache(at: "embeddings")
        return "Wiped index — \(totals.0) labels, \(totals.1) predictions, \(totals.2) model versions, \(totals.3) image rows. \(thumbs). \(embs)."
    }

    /// Delete every file in `~/Library/Caches/AllskyMLCurator/<subdir>`
    /// and return a one-liner summary. Any errors during individual
    /// file removals are swallowed — the user is probably fine with
    /// "almost everything went".
    private static func purgeDiskCache(at subdirectory: String) -> String {
        let fm = FileManager.default
        guard let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return "no caches directory found" }
        let url = cacheRoot
            .appendingPathComponent("AllskyMLCurator", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        guard fm.fileExists(atPath: url.path) else {
            return "Cleared \(subdirectory) cache (nothing to remove)"
        }

        var removed = 0
        if let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in contents {
                if (try? fm.removeItem(at: file)) != nil {
                    removed += 1
                }
            }
        }
        return "Cleared \(removed) files from \(subdirectory) cache"
    }
}
