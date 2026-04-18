import Foundation

/// REST client for the existing `astro-weather` Supabase project.
///
/// Uses URLSession directly rather than Supabase's own Swift SDK — the
/// surface we need is small (two SELECTs, one health-check), and the
/// sibling AstroTriage-blinkV2 project follows the same pattern, which
/// keeps tooling consistent.
///
/// The Supabase URL and anon key are loaded from `CredentialsStore`
/// (UserDefaults-backed — see that file for why Keychain was dropped
/// in the dev build) and paste-able from the Preferences window.
/// Environment variables override the stored values when present so
/// CI / dev loops can inject values via the Xcode scheme.
final class SupabaseClient {

    // MARK: - Singleton

    static let shared = SupabaseClient()
    private init() {}

    // MARK: - Errors

    enum ClientError: Error, LocalizedError {
        case notConfigured
        case invalidURL
        case transport(Error)
        case httpStatus(Int, String)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Supabase URL or anon key missing — paste them in Preferences."
            case .invalidURL:
                return "Supabase URL is malformed."
            case .transport(let error):
                return "Network error: \(error.localizedDescription)"
            case .httpStatus(let code, let body):
                return "Supabase returned HTTP \(code): \(body)"
            case .decoding(let error):
                return "Response decoding failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Configuration

    /// Keychain account name for the project URL.
    static let urlAccount = "supabase.astroWeather.url"
    /// Keychain account name for the anon key.
    static let anonKeyAccount = "supabase.astroWeather.anonKey"

    struct Config: Equatable {
        var urlString: String
        var anonKey: String

        var isValid: Bool {
            guard let url = URL(string: urlString) else { return false }
            return url.scheme?.hasPrefix("http") == true
                && !anonKey.isEmpty
        }
    }

    /// Current configuration. Environment variables win over Keychain —
    /// if `SUPABASE_URL` / `SUPABASE_ANON_KEY` are set in the process
    /// environment they are used directly so a dev can override without
    /// touching the Keychain.
    func loadConfig() -> Config? {
        let env = ProcessInfo.processInfo.environment
        let envURL = env["SUPABASE_URL"]
        let envKey = env["SUPABASE_ANON_KEY"]
        let url = (envURL?.isEmpty == false) ? envURL : (try? CredentialsStore.read(Self.urlAccount))
        let key = (envKey?.isEmpty == false) ? envKey : (try? CredentialsStore.read(Self.anonKeyAccount))
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let key = key?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty, !key.isEmpty else {
            return nil
        }
        let config = Config(urlString: url, anonKey: key)
        return config.isValid ? config : nil
    }

    /// Persist a new URL + anon key to the Keychain. Either value may be
    /// `nil` to clear it.
    func saveConfig(urlString: String?, anonKey: String?) throws {
        if let urlString, !urlString.isEmpty {
            try CredentialsStore.write(urlString, for: Self.urlAccount)
        } else {
            try CredentialsStore.delete(Self.urlAccount)
        }
        if let anonKey, !anonKey.isEmpty {
            try CredentialsStore.write(anonKey, for: Self.anonKeyAccount)
        } else {
            try CredentialsStore.delete(Self.anonKeyAccount)
        }
    }

    // MARK: - Response models

    /// Subset of `cloudwatcher_readings` relevant to the curator. Only
    /// the columns we consume are declared; Supabase's `?select=` uses
    /// this list so we don't drag the full row over the wire.
    ///
    /// Column names mirror the live astro-weather schema: `sky_quality_raw`
    /// (0 = cloudy, 1 = clear — see the CloudWatcher K-factor classifier)
    /// and `sky_minus_ambient` (more negative = clearer sky). The earlier
    /// draft referenced a non-existent `clouds_safe` column and Supabase
    /// responded with HTTP 400 / code 42703.
    struct CloudwatcherReading: Decodable, Identifiable, Sendable {
        let id: Int64
        let timestamp: Date
        let skyTemperature: Double?
        let ambientTemperature: Double?
        let skyMinusAmbient: Double?
        let skyQualityRaw: Int?
        let humidity: Double?
        let allskyUrl: String?
        let zwoUrl: String?
        let zwoFitsUrl: String?

        enum CodingKeys: String, CodingKey {
            case id
            case timestamp
            case skyTemperature     = "sky_temperature"
            case ambientTemperature = "ambient_temperature"
            case skyMinusAmbient    = "sky_minus_ambient"
            case skyQualityRaw      = "sky_quality_raw"
            case humidity
            case allskyUrl          = "allsky_url"
            case zwoUrl             = "zwo_url"
            case zwoFitsUrl         = "zwo_fits_url"
        }
    }

    struct MeteoblueHour: Decodable, Identifiable, Sendable {
        let id: Int64
        let timestamp: Date
        let totalcloud: Double?
        let lowclouds: Double?
        let midclouds: Double?
        let highclouds: Double?
        let seeingArcsec: Double?
        let moonlightActual: Double?
        let zenithAngle: Double?

        enum CodingKeys: String, CodingKey {
            case id
            case timestamp
            case totalcloud
            case lowclouds
            case midclouds
            case highclouds
            case seeingArcsec     = "seeing_arcsec"
            case moonlightActual  = "moonlight_actual"
            case zenithAngle      = "zenith_angle"
        }
    }

    // MARK: - Queries

    /// Tiny health-check: hit the PostgREST root so we get a 200 if the
    /// URL + anon key are valid. Called when the user taps "Test" in
    /// the Preferences window.
    func healthCheck() async throws {
        let config = try configOrThrow()
        let url = try endpoint(config: config, path: "/rest/v1/",
                               query: [])
        _ = try await get(url: url, config: config, as: EmptyResponse.self)
    }

    /// Read all `cloudwatcher_readings` rows whose `timestamp` falls
    /// within `[from, to)` that have at least one populated image URL.
    func fetchCloudwatcherReadings(
        from: Date,
        to: Date,
        limit: Int = 20_000
    ) async throws -> [CloudwatcherReading] {
        let config = try configOrThrow()
        let iso = iso8601Formatter()
        let url = try endpoint(
            config: config,
            path: "/rest/v1/cloudwatcher_readings",
            query: [
                URLQueryItem(name: "select", value:
                    "id,timestamp,sky_temperature,ambient_temperature,sky_minus_ambient,sky_quality_raw,humidity,allsky_url,zwo_url,zwo_fits_url"),
                URLQueryItem(name: "timestamp", value: "gte.\(iso.string(from: from))"),
                URLQueryItem(name: "timestamp", value: "lt.\(iso.string(from: to))"),
                URLQueryItem(name: "or", value:
                    "(allsky_url.not.is.null,zwo_url.not.is.null,zwo_fits_url.not.is.null)"),
                URLQueryItem(name: "order", value: "timestamp.asc"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        return try await get(url: url, config: config, as: [CloudwatcherReading].self)
    }

    /// Payload for a single row upserted into `ml_training_samples`.
    /// Matches the migration's column set exactly; the server-side
    /// `UNIQUE (image_path)` constraint drives the upsert semantics.
    struct TrainingSampleDTO: Encodable, Sendable {
        let image_path: String
        let image_hash_sha256: String?
        let camera_source: String
        let capture_utc: String           // ISO-8601 UTC
        let cloudwatcher_reading_id: Int64?
        let meteoblue_hour_id: Int64?
        let sun_alt_deg: Double?
        let sun_az_deg: Double?
        let moon_alt_deg: Double?
        let moon_az_deg: Double?
        let moon_phase: Double?
        let reflection_risk_score: Double?
        let `class`: Int
        let reflection_flag: Int
        let transitional_flag: Int
        let camera_profile_id: String?     // retired client-side, kept nullable for schema compat
        let time_of_day: String?
        let source: String
        let sample_weight: Double
        let confidence: Int?
        let annotator_id: String?
        let labeled_at: String             // ISO-8601 UTC
    }

    /// Upsert a batch of training-sample rows. PostgREST only treats a
    /// POST as an upsert when BOTH the `on_conflict=<col>` query
    /// parameter AND the `Prefer: resolution=merge-duplicates` header
    /// are set. Missing either one makes the server reject duplicate
    /// rows with HTTP 409 (code 23505). The earlier omission was the
    /// classic PostgREST upsert gotcha — it still looked like a plain
    /// INSERT on the server side.
    func upsertTrainingSamples(_ samples: [TrainingSampleDTO]) async throws {
        guard !samples.isEmpty else { return }
        let config = try configOrThrow()
        let url = try endpoint(
            config: config,
            path: "/rest/v1/ml_training_samples",
            query: [URLQueryItem(name: "on_conflict", value: "image_path")]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates,return=minimal",
                         forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try encoder.encode(samples)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw ClientError.httpStatus(http.statusCode, body)
        }
    }

    /// Read all `meteoblue_hourly` rows whose `timestamp` falls within
    /// `[from, to)`. Always complete hours — 24 rows per day.
    func fetchMeteoblueHours(
        from: Date,
        to: Date,
        limit: Int = 2_000
    ) async throws -> [MeteoblueHour] {
        let config = try configOrThrow()
        let iso = iso8601Formatter()
        let url = try endpoint(
            config: config,
            path: "/rest/v1/meteoblue_hourly",
            query: [
                URLQueryItem(name: "select", value:
                    "id,timestamp,totalcloud,lowclouds,midclouds,highclouds,seeing_arcsec,moonlight_actual,zenith_angle"),
                URLQueryItem(name: "timestamp", value: "gte.\(iso.string(from: from))"),
                URLQueryItem(name: "timestamp", value: "lt.\(iso.string(from: to))"),
                URLQueryItem(name: "order", value: "timestamp.asc"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        return try await get(url: url, config: config, as: [MeteoblueHour].self)
    }

    // MARK: - Helpers

    private func configOrThrow() throws -> Config {
        guard let config = loadConfig() else { throw ClientError.notConfigured }
        return config
    }

    private func endpoint(
        config: Config, path: String, query: [URLQueryItem]
    ) throws -> URL {
        guard var components = URLComponents(string: config.urlString) else {
            throw ClientError.invalidURL
        }
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw ClientError.invalidURL }
        return url
    }

    /// Single GET helper: attaches the anon key, checks the status, and
    /// decodes the body against `T`. Uses a bounded timeout so UI threads
    /// waiting on `await` don't stall indefinitely.
    private func get<T: Decodable>(
        url: URL, config: Config, as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw ClientError.httpStatus(http.statusCode, body)
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.primaryTimestampFormatter.date(from: raw) { return date }
            if let date = Self.fallbackTimestampFormatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Could not parse timestamp: \(raw)"
            )
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(error)
        }
    }

    // MARK: - Date formatting

    /// Formatter for outgoing PostgREST query filters (ISO-8601 UTC).
    private func iso8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// Supabase returns either `2024-06-21T09:50:46+00:00` or
    /// `2024-06-21T09:50:46.123456+00:00`. Try the fractional variant
    /// first so the longer precision doesn't fall through to a failure.
    private static let primaryTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private struct EmptyResponse: Decodable {}
}
