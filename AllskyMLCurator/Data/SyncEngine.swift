import CryptoKit
import Foundation
import GRDB

/// Pushes locally-produced labels to the `ml_training_samples` table
/// in the shared `astro-weather` Supabase project, so they survive
/// machine swaps, feed the future cloudwatcher-threshold retuning
/// job, and (later) the portable classifier training pipeline.
///
/// Phase-4 scope is **push only**. Pull of predictions / model
/// metadata lands with Phase 5 once the embedding + classifier work
/// actually writes something to pull.
///
/// The engine tolerates a missing Supabase config — it just sits in
/// `.notConfigured` status and does nothing. That way label writes
/// never block on the network.
@MainActor
final class SyncEngine: ObservableObject {

    // MARK: - Singleton

    static let shared = SyncEngine()
    private init() {}

    // MARK: - Observable state

    enum Status: Equatable {
        case idle
        case notConfigured
        case pushing(pushed: Int, total: Int)
        case upToDate(synced: Int, at: Date)
        case failed(String)

        var statusText: String {
            switch self {
            case .idle:                     return "idle"
            case .notConfigured:            return "Supabase not configured"
            case .pushing(let n, let t):    return "pushing \(n)/\(t)…"
            case .upToDate(let n, _):       return "synced (\(n))"
            case .failed(let msg):          return "failed: \(msg)"
            }
        }

        var isProblem: Bool {
            if case .failed = self { return true }
            return false
        }

        /// True while the engine is actively pushing rows — drives
        /// the toolbar gauge icon's pulse animation.
        var isPushing: Bool {
            if case .pushing = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .idle

    // MARK: - Config

    /// Batch size for upserts — keeps request bodies well under the
    /// 1 MiB PostgREST payload ceiling while still amortising the
    /// round-trip cost across many rows.
    private static let batchSize = 500

    /// Guard to serialize sync runs — only one in-flight at a time so
    /// a rapid-fire burst of label writes doesn't kick off concurrent
    /// pushes that would all upsert the same rows.
    private var inFlight = false

    // MARK: - Public API

    /// Push every label whose `syncedToSupabase = false` flag is set.
    /// Safe to call from label-write paths; returns immediately if a
    /// sync is already running.
    func pushPending() async {
        guard !inFlight else { return }
        guard SupabaseClient.shared.loadConfig() != nil else {
            status = .notConfigured
            return
        }

        inFlight = true
        defer { inFlight = false }

        do {
            let pending = try await loadPendingSamples()
            guard !pending.isEmpty else {
                status = .upToDate(
                    synced: lastSyncCount,
                    at: Date()
                )
                return
            }

            status = .pushing(pushed: 0, total: pending.count)

            var pushed = 0
            for chunk in pending.chunked(into: Self.batchSize) {
                let dtos = chunk.map(\.dto)
                try await SupabaseClient.shared.upsertTrainingSamples(dtos)
                try await markSynced(ids: chunk.map(\.labelId))
                pushed += chunk.count
                status = .pushing(pushed: pushed, total: pending.count)
            }

            lastSyncCount = pushed
            status = .upToDate(synced: pushed, at: Date())
        } catch {
            let description = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            status = .failed(description)
        }
    }

    /// Mark every local label as unsynced so the next `pushPending`
    /// re-uploads the full set. Used after a DTO-shape change (new
    /// column, bug fix) where rows already in Supabase need their
    /// refreshed values. Safe to call any time — Supabase upserts
    /// on `image_path`, so identical content is a no-op server-side.
    func markAllForResync() async {
        let writer = Database.shared.writer
        do {
            try await writer.write { db in
                try LabelRecord
                    .filter(Column("syncedToSupabase") == true)
                    .updateAll(db, [
                        Column("syncedToSupabase").set(to: false)
                    ])
            }
        } catch {
            NSLog("SyncEngine.markAllForResync failed: \(error)")
        }
    }

    // MARK: - Data loading

    private var lastSyncCount: Int = 0

    private struct PendingSample {
        let labelId: Int64
        let dto: SupabaseClient.TrainingSampleDTO
    }

    /// Fetch up to `limit` unsynced labels joined with their image
    /// metadata, build the DTOs, and return them in label-id order so
    /// subsequent runs make progress even if some rows fail.
    private func loadPendingSamples(limit: Int = 10_000) async throws -> [PendingSample] {
        let reader = Database.shared.reader
        return try await reader.read { db in
            let labels = try LabelRecord
                .filter(Column("syncedToSupabase") == false)
                .filter(Column("isCurrent") == true)
                .order(Column("id").asc)
                .limit(limit)
                .fetchAll(db)

            let imageIds: [Int64] = labels.map { $0.imageId }
            guard !imageIds.isEmpty else { return [] }

            let images = try ImageRecord
                .filter(imageIds.contains(Column("id")))
                .fetchAll(db)
            let imageById = Dictionary(
                uniqueKeysWithValues: images.compactMap { img in
                    img.id.map { ($0, img) }
                }
            )

            return labels.compactMap { label -> PendingSample? in
                guard let labelId = label.id,
                      let image = imageById[label.imageId] else { return nil }
                return PendingSample(
                    labelId: labelId,
                    dto: Self.makeDTO(label: label, image: image)
                )
            }
        }
    }

    /// Flip `syncedToSupabase = true` for the given label ids.
    private func markSynced(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        let writer = Database.shared.writer
        try await writer.write { db in
            try LabelRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, [
                    Column("syncedToSupabase").set(to: true)
                ])
        }
    }

    // MARK: - DTO conversion

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated private static func makeDTO(
        label: LabelRecord, image: ImageRecord
    ) -> SupabaseClient.TrainingSampleDTO {
        SupabaseClient.TrainingSampleDTO(
            image_path: image.filePath,
            image_hash_sha256: image.fileHashSha256,
            camera_source: image.cameraSource.rawValue,
            capture_utc: iso8601Formatter.string(from: image.captureUtc),
            cloudwatcher_reading_id: image.supabaseReadingId,
            meteoblue_hour_id: image.meteoblueHourId,
            sun_alt_deg: image.sunAltDeg,
            sun_az_deg: image.sunAzDeg,
            moon_alt_deg: image.moonAltDeg,
            moon_az_deg: image.moonAzDeg,
            moon_phase: image.moonPhase,
            reflection_risk_score: image.reflectionRiskScore,
            class: label.ratingClass.rawValue,
            reflection_flag: label.reflectionFlag ? 1 : 0,
            transitional_flag: label.transitionalFlag ? 1 : 0,
            camera_profile_id: cameraProfileHash(for: image),
            time_of_day: image.timeOfDay.rawValue,
            source: label.source.rawValue,
            sample_weight: label.sampleWeight,
            confidence: label.confidence,
            annotator_id: label.annotatorId,
            labeled_at: iso8601Formatter.string(from: label.labeledAt)
        )
    }

    /// Derive a stable profile identifier from the observatory
    /// coordinates + camera parameters actually used at ingest time.
    /// Same rig across two machines produces the same hash (good for
    /// cross-user dataset sharing later), two different rigs at the
    /// same site produce different hashes, two identical rigs at
    /// different sites produce different hashes.
    nonisolated private static func cameraProfileHash(
        for image: ImageRecord
    ) -> String {
        let s = AppSettings.shared
        let cameraType = image.cameraSource.cameraType
        let fov: Double
        let centerX: Int, centerY: Int, radius: Int
        switch cameraType {
        case .color:
            fov = s.colorFovDeg
            centerX = s.colorFisheyeCenterXPx
            centerY = s.colorFisheyeCenterYPx
            radius  = s.colorFisheyeRadiusPx
        case .monochrome:
            fov = s.monoFovDeg
            centerX = s.monoFisheyeCenterXPx
            centerY = s.monoFisheyeCenterYPx
            radius  = s.monoFisheyeRadiusPx
        }
        let material = String(
            format: "%.3f|%.3f|%@|%.1f|%d|%d|%d",
            s.latitudeDeg, s.longitudeDeg,
            cameraType.rawValue, fov,
            centerX, centerY, radius
        )
        let digest = SHA256.hash(data: Data(material.utf8))
        // 12 hex chars of digest keeps the column readable while still
        // being collision-free in any realistic multi-rig setting.
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }
}

// MARK: - Array chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
