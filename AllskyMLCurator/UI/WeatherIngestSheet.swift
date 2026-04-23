import AppKit
import GRDB
import SwiftUI

/// Weather-filtered ingest: the curator picks a sky-temperature
/// range (e.g. −7 °C to −5 °C = "fairly clear but probably not
/// fully") and the app queries Supabase `cloudwatcher_readings` for
/// every matching reading in a date window, resolves the per-reading
/// `allsky_url` / `zwo_url` to local paths, deduplicates against
/// rows already in the library, then offers a preview before any DB
/// writes happen.
///
/// This is the second ingest flow next to the folder-walk one
/// (`IngestSheet`). Motivation: the matrix-view workflow benefits
/// from *targeted* batches — "give me ambiguous-sky frames for the
/// classifier's blind spot" beats "ingest the whole month and sort
/// out 95 % of fully-cloudy frames later".
struct WeatherIngestSheet: View {

    @Binding var isPresented: Bool

    @StateObject private var ingest = IngestService.shared

    // MARK: - User inputs

    @State private var skyTempMin: Double = -20
    @State private var skyTempMax: Double = -5
    @State private var dateFrom: Date = Calendar.current.date(
        byAdding: .day, value: -30, to: Date()
    ) ?? Date()
    @State private var dateTo: Date = Date()
    @State private var cameraType: CameraType = .color

    // MARK: - Query state

    @State private var queryState: QueryState = .idle
    @State private var candidateFiles: [URL] = []
    @State private var duplicateCount: Int = 0
    @State private var unresolvedCount: Int = 0
    @State private var sampleFilenames: [String] = []
    @State private var ingestMode: IngestMode = .idle

    /// 0.8.4: result of the "seed from class-2 labels" action. Shown
    /// inline under the sky-temp fields so the user understands why
    /// the window jumped to those exact values.
    @State private var seedSummary: String?

    enum QueryState: Equatable {
        case idle
        case querying
        case ready(matchedReadings: Int)
        case failed(String)
    }

    enum IngestMode {
        case idle
        case dryRunning
        case writing
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section("Sky temperature filter") {
                    HStack {
                        Text("Min")
                        TextField("", value: $skyTempMin, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        Text("°C")
                        Spacer()
                        Text("Max")
                        TextField("", value: $skyTempMax, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        Text("°C")
                    }
                    Text("Rule of thumb: sky_temp < −13 °C is clearly clear; −13 … −11 °C is cloudy; > −11 °C is overcast. The ambiguous −7 … −5 °C window is where the classifier needs the most help.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 0.8.4: "hunt more class-2 frames" helper. Reads
                    // the IQR of current class-2 sky-temps for the
                    // selected camera and writes it into the fields,
                    // also widens the date window to "all time" —
                    // class-2 frames can come from any historical
                    // session, not just the default last-30-days.
                    Divider()
                    HStack {
                        Button {
                            seedFromClassTwo()
                        } label: {
                            Label("Seed window from current class-2 labels",
                                  systemImage: "target")
                        }
                        .help("Reads the sky-temp IQR (p25…p75) of frames currently labelled class-2 for the selected camera, pads ±0.5 °C, and widens the date window to cover all history. Higher probability of finding more class-2 candidates than a manual guess.")
                        Spacer()
                    }
                    if let seedSummary {
                        Text(seedSummary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Date window") {
                    DatePicker("From", selection: $dateFrom,
                               displayedComponents: [.date])
                    DatePicker("To",   selection: $dateTo,
                               displayedComponents: [.date])
                }

                Section("Camera") {
                    Picker("", selection: $cameraType) {
                        ForEach(CameraType.allCases, id: \.self) { cam in
                            Text(cam.displayName).tag(cam)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("The color allsky has day + night frames; mono ZWO is night-only. Each row in cloudwatcher_readings carries up to three URLs (color JPG, mono JPG, mono FITS) — this picker decides which column drives the ingest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Preview") {
                    queryPanel
                }
            }
            .formStyle(.grouped)
            .disabled(ingestMode != .idle)

            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 540)
        .onAppear { runQuery() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "thermometer.sun")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Weather-filtered ingest")
                    .font(.title3.weight(.bold))
                Text("Query cloudwatcher readings, resolve files, preview before writing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: - Query panel

    @ViewBuilder
    private var queryPanel: some View {
        HStack {
            Button("Refresh preview") { runQuery() }
                .disabled(queryState == .querying || ingestMode != .idle)
            Spacer()
            switch queryState {
            case .idle:
                Text("Hit refresh to run the query.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .querying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("querying Supabase…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ready(let readingCount):
                Text("\(readingCount) readings matched")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .failed(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }

        if case .ready = queryState {
            VStack(alignment: .leading, spacing: 2) {
                row("Files resolvable", "\(candidateFiles.count)")
                row("Already in library", "\(duplicateCount)", color: .orange)
                row("New to ingest", "\(newFileCount)",
                    color: newFileCount > 0 ? .green : .secondary)
                if unresolvedCount > 0 {
                    row("Readings without a file for \(cameraType.displayName)",
                        "\(unresolvedCount)", color: .secondary)
                }
                if !sampleFilenames.isEmpty {
                    Text("Samples:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(sampleFilenames.prefix(5), id: \.self) { name in
                        Text(name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if ingestMode != .idle || ingest.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(
                    value: Double(ingest.processed),
                    total: max(Double(ingest.totalFiles), 1)
                )
                Text("\(ingest.processed) / \(ingest.totalFiles) — \(ingest.statusMessage)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private func row(
        _ label: String, _ value: String, color: Color = .primary
    ) -> some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
    }

    // MARK: - Footer actions

    private var footer: some View {
        HStack {
            Spacer()
            Button("Dry run") { startDryRun() }
                .disabled(!canIngest)
            Button("Ingest \(newFileCount) new") { startRealIngest() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canIngest || newFileCount == 0)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var canIngest: Bool {
        switch queryState {
        case .ready: return ingestMode == .idle && !ingest.isRunning
        default:     return false
        }
    }

    private var newFileCount: Int {
        max(0, candidateFiles.count - duplicateCount)
    }

    // MARK: - Class-2 seeding

    /// 0.8.4: drive the "hunt more class-2 frames" workflow. Reads
    /// the sky-temp IQR of current class-2 labels for the selected
    /// camera, pads ±0.5 °C, widens the date window to all-time, and
    /// kicks a fresh query. Falls back with an informative message
    /// when fewer than 5 class-2 labels exist (IQR is unreliable at
    /// that point — user should hand-pick a window instead).
    private func seedFromClassTwo() {
        let cam = cameraType
        let sources = cam.filePathCameraSources
        Task {
            do {
                let values: [Double] = try await Database.shared.reader.read { db in
                    // Hand-SQL rather than GRDB query-interface so we
                    // can inline the image-label join + the night-only
                    // sun-alt filter in one pass. Rated night class-2
                    // frames only; ignore auto-labels so noisy
                    // predictions don't skew the seed window.
                    let sourcesList = sources
                        .map { "'\($0)'" }
                        .joined(separator: ",")
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT i.cloudwatcherSkyTempC AS t
                        FROM labels l
                        JOIN images i ON i.id = l.imageId
                        WHERE l.isCurrent = 1
                          AND l.source = 'human'
                          AND l.ratingClass = 2
                          AND i.cloudwatcherSkyTempC IS NOT NULL
                          AND i.sunAltDeg < -12
                          AND i.cameraSource IN (\(sourcesList))
                        ORDER BY t ASC
                        """)
                    return rows.compactMap { $0["t"] as Double? }
                }
                await MainActor.run {
                    applySeedWindow(from: values, cam: cam)
                }
            } catch {
                await MainActor.run {
                    seedSummary = "Seed failed: " +
                        ((error as? LocalizedError)?.errorDescription
                         ?? String(describing: error))
                }
            }
        }
    }

    /// Given the sorted list of class-2 sky-temps, pick the window
    /// and rewrite the UI fields. IQR (p25…p75) + 0.5 °C pad keeps
    /// the query on the dense part of the distribution; the long
    /// tail above p75 / below p25 is typically mis-labels or
    /// edge-of-class frames and would dilute the hunt.
    private func applySeedWindow(from values: [Double], cam: CameraType) {
        guard values.count >= 5 else {
            seedSummary = "Need ≥ 5 class-2 labels for \(cam.displayName); found \(values.count). Hand-pick a window or rate more class-2 first."
            return
        }
        let n = values.count
        let p25 = values[Int(0.25 * Double(n - 1))]
        let p75 = values[Int(0.75 * Double(n - 1))]
        // Round to one decimal so the UI fields don't show long
        // floating-point tails.
        let roundTenth: (Double) -> Double = { (x: Double) in
            (x * 10).rounded() / 10
        }
        let padded = (min: roundTenth(p25 - 0.5),
                      max: roundTenth(p75 + 0.5))
        skyTempMin = padded.min
        skyTempMax = padded.max
        // All-time window: Supabase data starts late 2023 at the
        // earliest, so 2023-01-01 is a safe lower bound that still
        // fits well under the 20 000-row PostgREST limit.
        dateFrom = Calendar.current.date(
            from: DateComponents(year: 2023, month: 1, day: 1)
        ) ?? dateFrom
        dateTo = Date()
        seedSummary = String(
            format: "Seeded from %d class-2 \(cam.displayName) labels · p25=%.1f °C, p75=%.1f °C · padded window %.1f … %.1f °C, all-time.",
            n, p25, p75, padded.min, padded.max
        )
        runQuery()
    }

    // MARK: - Queries

    private func runQuery() {
        queryState = .querying
        candidateFiles = []
        duplicateCount = 0
        unresolvedCount = 0
        sampleFilenames = []

        let minT = skyTempMin
        let maxT = skyTempMax
        let from = dateFrom
        let to = dateTo
        let cam = cameraType

        Task {
            do {
                // Cloudwatcher readings are stored at ≈ 5-min cadence,
                // so a ~30-day window fits comfortably under the 20 k
                // Supabase limit. The REST endpoint filters timestamp
                // for us; sky_temperature is filtered client-side so
                // one query shape covers every temperature range.
                let readings = try await SupabaseClient.shared
                    .fetchCloudwatcherReadings(from: from, to: to)
                    .filter { reading in
                        guard let temp = reading.skyTemperature else {
                            return false
                        }
                        return temp >= minT && temp <= maxT
                    }

                var resolved: [URL] = []
                var unresolved = 0
                for reading in readings {
                    guard let path = urlForReading(reading, camera: cam) else {
                        unresolved += 1
                        continue
                    }
                    resolved.append(URL(fileURLWithPath: path))
                }

                // Dedup against existing DB rows so we don't ingest
                // the same file twice.
                let existingPaths = try await Database.shared.reader.read { db in
                    try ImageRecord
                        .select(ImageRecord.Columns.filePath, as: String.self)
                        .fetchAll(db)
                }
                let existingSet = Set(existingPaths)
                let duplicates = resolved.filter { existingSet.contains($0.path) }.count

                let samples = Array(resolved.suffix(5).map { $0.lastPathComponent })

                await MainActor.run {
                    candidateFiles = resolved
                    duplicateCount = duplicates
                    unresolvedCount = unresolved
                    sampleFilenames = samples
                    queryState = .ready(matchedReadings: readings.count)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                await MainActor.run {
                    queryState = .failed(message)
                }
            }
        }
    }

    /// Pick the right URL column per camera + rewrite Synology's
    /// internal `/volume1/...` prefix to the local SMB mount's
    /// `/Volumes/...`. Returns nil when the requested column is null
    /// (e.g. no color JPG for a daytime reading before the ZWO was
    /// installed).
    ///
    /// Column mapping for the Rheine setup:
    ///   - `zwo_url`        → color (ZWO ASI676MC, the OSC cam)
    ///   - `zwo_fits_url`   → color FITS from the same cam
    ///   - `allsky_url`     → mono  (SX CCD SuperStar, the night cam)
    ///
    /// The historical CLAUDE.md assumption was the opposite
    /// ("allsky = color, zwo = mono"), which reflects a generic
    /// reading of those column names — for this user's physical
    /// rig the zwo hardware is the colour cam and the allsky label
    /// belongs to the SX mono sensor. Verified against existing
    /// image-row paths in the local DB.
    private func urlForReading(
        _ reading: SupabaseClient.CloudwatcherReading, camera: CameraType
    ) -> String? {
        let raw: String?
        switch camera {
        case .color:      raw = reading.zwoUrl ?? reading.zwoFitsUrl
        case .monochrome: raw = reading.allskyUrl
        }
        return raw.map(Self.remapVolumePrefix)
    }

    /// Synology exposes files internally at `/volume1/<share>/...`
    /// but macOS mounts the SMB share at `/Volumes/<share>/...`. The
    /// two differ only in the prefix. A simple string replace keeps
    /// every downstream path operation sandbox-safe.
    static func remapVolumePrefix(_ path: String) -> String {
        guard path.hasPrefix("/volume1/") else { return path }
        return "/Volumes/" + path.dropFirst("/volume1/".count)
    }

    // MARK: - Ingest actions

    private func startDryRun() {
        let newOnes = newFiles()
        ingestMode = .dryRunning
        Task {
            await ingest.ingestFiles(
                newOnes, cameraType: cameraType, dryRun: true
            )
            ingestMode = .idle
        }
    }

    private func startRealIngest() {
        let newOnes = newFiles()
        ingestMode = .writing
        Task {
            await ingest.ingestFiles(
                newOnes, cameraType: cameraType, dryRun: false
            )
            ingestMode = .idle
        }
    }

    private func newFiles() -> [URL] {
        // Recompute against the duplicate set so the count shown in
        // the button and the actual ingest list never diverge.
        let existing: Set<String> = (
            try? Database.shared.reader.read { db in
                try ImageRecord
                    .select(ImageRecord.Columns.filePath, as: String.self)
                    .fetchAll(db)
            }.reduce(into: Set<String>()) { $0.insert($1) }
        ) ?? []
        return candidateFiles.filter { !existing.contains($0.path) }
    }
}
