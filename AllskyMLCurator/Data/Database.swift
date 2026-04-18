import Foundation
import GRDB

/// Owns the local SQLite database. One `DatabasePool` is shared across
/// the app; writers are serialized, readers run in parallel.
///
/// Schema migrations live here — each migration bumps the layout and is
/// safe to re-run on a populated DB.
final class Database {

    // MARK: - Singleton

    static let shared = Database()
    private init() {}

    // MARK: - Pool

    private var dbPool: DatabasePool?

    /// Open the DB at the given path, creating the containing directory
    /// if needed. Idempotent — subsequent calls are a no-op.
    func open(at url: URL) throws {
        if dbPool != nil { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbPool = try DatabasePool(path: url.path)
        try migrator().migrate(dbPool!)
    }

    /// Default storage location under the app's Application Support dir.
    static func defaultURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("AllskyMLCurator", isDirectory: true)
            .appendingPathComponent("curator.sqlite")
    }

    // MARK: - Accessors

    var reader: DatabaseReader {
        guard let dbPool else {
            fatalError("Database.open(at:) must be called before reader access.")
        }
        return dbPool
    }

    var writer: DatabaseWriter {
        guard let dbPool else {
            fatalError("Database.open(at:) must be called before writer access.")
        }
        return dbPool
    }

    // MARK: - Migrations

    private func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "images") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("filePath", .text).notNull().unique()
                t.column("fileHashSha256", .text)
                t.column("cameraSource", .text).notNull()
                t.column("captureUtc", .datetime).notNull().indexed()
                t.column("timeOfDay", .text).notNull()
                t.column("supabaseReadingId", .integer)
                t.column("sunAltDeg", .double).notNull()
                t.column("sunAzDeg", .double).notNull()
                t.column("moonAltDeg", .double).notNull()
                t.column("moonAzDeg", .double).notNull()
                t.column("moonPhase", .double).notNull()
                t.column("reflectionRiskScore", .double).notNull()
                t.column("transitionalRiskScore", .double).notNull()
                t.column("isExcluded", .boolean).notNull().defaults(to: false)
                t.column("embeddingPath", .text)
                t.column("embeddingRevision", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_images_camera_source",
                          on: "images", columns: ["cameraSource"])
            try db.create(index: "idx_images_capture_date",
                          on: "images", columns: ["captureUtc"])

            try db.create(table: "labels") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("imageId", .integer).notNull()
                    .references("images", onDelete: .cascade)
                t.column("ratingClass", .integer).notNull()
                t.column("reflectionFlag", .boolean).notNull().defaults(to: false)
                t.column("transitionalFlag", .boolean).notNull().defaults(to: false)
                t.column("source", .text).notNull().defaults(to: "human")
                t.column("sampleWeight", .double).notNull().defaults(to: 1.0)
                t.column("confidence", .integer)
                t.column("annotatorId", .text).notNull()
                t.column("labeledAt", .datetime).notNull()
                t.column("syncedToSupabase", .boolean).notNull().defaults(to: false)
                t.column("isCurrent", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "idx_labels_image_current",
                          on: "labels", columns: ["imageId", "isCurrent"])
            try db.create(index: "idx_labels_unsynced",
                          on: "labels", columns: ["syncedToSupabase"])

            try db.create(table: "predictions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("imageId", .integer).notNull()
                    .references("images", onDelete: .cascade)
                t.column("modelVersion", .text).notNull()
                t.column("predictedClass", .integer).notNull()
                t.column("classProbabilities", .blob).notNull()
                t.column("reflectionProb", .double).notNull()
                t.column("motionVectorDegPerMin", .double)
                t.column("motionAzimuthDeg", .double)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["imageId", "modelVersion"])
            }

            try db.create(table: "model_versions") { t in
                t.primaryKey("version", .text)
                t.column("trainedAt", .datetime).notNull()
                t.column("trainingSetSize", .integer).notNull()
                t.column("classCounts", .blob).notNull()
                t.column("classifierType", .text).notNull()
                t.column("classifierWeights", .blob).notNull()
                t.column("accuracy5FoldCV", .double)
                t.column("notes", .text)
            }
        }

        // Pre-release schema pivot: an earlier draft carried a
        // `cameraProfileId` column referencing the (now-retired)
        // per-camera JSON profile system. Any dev DB created under
        // v0.2.0 will have that column — drop it so the new Swift
        // `ImageRecord` (without cameraProfileId) keeps inserting
        // cleanly. Safe no-op when the column does not exist.
        migrator.registerMigration("v2_drop_camera_profile_id") { db in
            if try db.columns(in: "images").contains(where: { $0.name == "cameraProfileId" }) {
                try db.alter(table: "images") { t in
                    t.drop(column: "cameraProfileId")
                }
            }
        }

        return migrator
    }
}
