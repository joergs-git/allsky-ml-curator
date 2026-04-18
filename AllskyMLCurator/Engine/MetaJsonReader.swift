import Foundation

/// Reads the per-frame `*_metadata.json` sidecar written by the allsky
/// capture software next to every image file.
///
/// Layout in the user's Rheine rig:
/// ```
/// zwo/2026-04-17/jpg/zwo_20260417T000820Z.jpg
/// zwo/2026-04-17/meta/zwo_20260417T000820Z_metadata.json
/// ```
///
/// When a sidecar is present the values are authoritative — timestamp
/// comes from the capture clock (`time` as Unix epoch seconds, UTC),
/// `stable_exposure == 0` is a far stronger transitional-frame signal
/// than the geometric sun-altitude heuristic, and camera sensor temp /
/// gain / exposure are used later as auxiliary classifier features.
enum MetaJsonReader {

    /// Subset of fields the curator currently cares about. The raw
    /// JSON carries many more (aurora, 60-slot sensor arrays, SQM
    /// statistics) — those can be parsed on demand later without
    /// schema changes here.
    struct Metadata: Decodable, Sendable {

        // Timing
        let captureUtc: Date

        // Capture state
        let deviceName: String?
        let isNight: Bool
        let stableExposure: Bool

        // Sensor / exposure params
        let exposureSec: Double?
        let gain: Double?
        let sensorTempC: Double?

        // Observatory (overrides AppSettings when present — sanity check only
        // in Phase 1, may be used later to auto-detect site moves)
        let latitudeDeg: Double?
        let longitudeDeg: Double?

        // MARK: - Decoding

        enum CodingKeys: String, CodingKey {
            case time
            case tz
            case device
            case night
            case stableExposure = "stable_exposure"
            case exposure
            case gain
            case temp
            case latitude
            case longitude
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            // `time` is a string holding a Unix epoch; `tz` confirms UTC.
            let timeString = try c.decode(String.self, forKey: .time)
            guard let epoch = TimeInterval(timeString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .time, in: c,
                    debugDescription: "Expected numeric epoch, got \"\(timeString)\""
                )
            }
            captureUtc = Date(timeIntervalSince1970: epoch)

            deviceName  = try c.decodeIfPresent(String.self, forKey: .device)
            isNight     = (try c.decodeIfPresent(Int.self, forKey: .night) ?? 0) == 1
            stableExposure =
                (try c.decodeIfPresent(Int.self, forKey: .stableExposure) ?? 1) == 1
            exposureSec = try c.decodeIfPresent(Double.self, forKey: .exposure)
            gain        = try c.decodeIfPresent(Double.self, forKey: .gain)
            sensorTempC = try c.decodeIfPresent(Double.self, forKey: .temp)
            latitudeDeg  = try c.decodeIfPresent(Double.self, forKey: .latitude)
            longitudeDeg = try c.decodeIfPresent(Double.self, forKey: .longitude)
        }
    }

    // MARK: - Sidecar lookup

    /// Try to read the sidecar for a given image URL. Returns `nil` when
    /// no sidecar file exists or when decoding fails — the caller falls
    /// back to filename parsing + `contentModificationDate`.
    static func read(for imageURL: URL) -> Metadata? {
        guard let metaURL = sidecarURL(for: imageURL),
              FileManager.default.fileExists(atPath: metaURL.path),
              let data = try? Data(contentsOf: metaURL)
        else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    /// Compute `../meta/{basename}_metadata.json` from an image path.
    /// Returns `nil` when the image URL has no parent (shouldn't happen
    /// for real ingest inputs).
    static func sidecarURL(for imageURL: URL) -> URL? {
        let base = imageURL.deletingPathExtension().lastPathComponent
        let parent = imageURL.deletingLastPathComponent()
        guard !parent.path.isEmpty else { return nil }
        let dateFolder = parent.deletingLastPathComponent()
        let metaDir = dateFolder.appendingPathComponent("meta", isDirectory: true)
        return metaDir.appendingPathComponent("\(base)_metadata.json")
    }
}
