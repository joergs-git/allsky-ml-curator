import AppKit
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

    /// Pick the right URL column per camera pick. Returns nil when
    /// the requested column is null (e.g. no mono JPG for a daytime
    /// reading).
    private func urlForReading(
        _ reading: SupabaseClient.CloudwatcherReading, camera: CameraType
    ) -> String? {
        switch camera {
        case .color:      return reading.allskyUrl
        case .monochrome: return reading.zwoUrl ?? reading.zwoFitsUrl
        }
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
