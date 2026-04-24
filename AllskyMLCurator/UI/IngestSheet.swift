import AppKit
import SwiftUI

/// Modal sheet that drives the Phase-1 folder ingest flow. Pulled out
/// of the old ContentView so the main window can focus on the matrix.
///
/// Shows: folder breadcrumb + picker, camera type + image format
/// pickers, dry-run toggle, live counters. Dismisses itself with
/// `Close` when the user is done — the caller refreshes its image
/// list on dismiss.
struct IngestSheet: View {

    @Binding var isPresented: Bool
    @StateObject private var ingest = IngestService.shared

    /// 0.8.7: list rather than single folder so the curator can
    /// queue multiple nights in one ingest pass (NAS layout is one
    /// `YYYY-MM-DD/` directory per night, so a month's worth of
    /// backfill used to mean opening this sheet 30 times).
    @State private var selectedFolders: [URL] = []
    @State private var cameraType: CameraType = .color
    @State private var imageFormat: ImageFormat = .jpg
    @State private var dryRun: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            controls
            Divider()
            counters

            if let message = ingest.lastError {
                Text("⚠️ \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 520)
        .onAppear(perform: restoreLastSelection)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ingest folder")
                .font(.title2)
            Text("Scan a folder of allsky JPG/FITS images, pre-compute ephemeris + reflection + transitional scores, pull per-frame metadata from the sibling meta/ folder, and (if Supabase is configured) enrich every frame with the nearest CloudWatcher reading within ±5 min.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Folders:")
                    .frame(width: 70, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    if selectedFolders.isEmpty {
                        Text("none — click Add…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        // Summary line + scrollable list. Cmd-clicking
                        // through the picker can queue a month's worth
                        // of nightly folders; capping the list to a
                        // scroll view keeps the sheet compact.
                        Text("\(selectedFolders.count) folder\(selectedFolders.count == 1 ? "" : "s") queued")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(selectedFolders, id: \.path) { url in
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(url.path)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button {
                                            removeFolder(url)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove from the queue")
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 110)
                    }
                }
                Spacer()
                VStack(spacing: 4) {
                    Button("Add…") { openFolderPicker() }
                    if !selectedFolders.isEmpty {
                        Button("Clear") { selectedFolders = [] }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Text("Camera:")
                    .frame(width: 70, alignment: .trailing)
                Picker("", selection: $cameraType) {
                    ForEach(CameraType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .onChange(of: cameraType) { _, new in
                    AppSettings.shared.lastCameraTypeRaw = new.rawValue
                }
                Spacer()
            }

            HStack {
                Text("Format:")
                    .frame(width: 70, alignment: .trailing)
                Picker("", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .onChange(of: imageFormat) { _, new in
                    AppSettings.shared.lastImageFormatRaw = new.rawValue
                }
                if !imageFormat.isSupportedInCurrentBuild {
                    Text("(indexed only — loading lands in v1.1)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            Toggle("Dry-run (scan + count only, no DB writes)", isOn: $dryRun)

            HStack {
                Button(ingest.isRunning
                       ? "Working…"
                       : (dryRun
                          ? "Dry-run \(selectedFolders.count) folder\(selectedFolders.count == 1 ? "" : "s")"
                          : "Ingest \(selectedFolders.count) folder\(selectedFolders.count == 1 ? "" : "s")")) {
                    startIngest()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ingest.isRunning || selectedFolders.isEmpty)

                Button("Cancel") { ingest.cancel() }
                    .disabled(!ingest.isRunning)

                Spacer()

                Text(ingest.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Counters

    private var counters: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                counterCell("Total files",   value: ingest.totalFiles)
                counterCell("Processed",     value: ingest.processed)
            }
            GridRow {
                counterCell("Inserted",      value: ingest.inserted)
                counterCell("Excluded (mono/day)", value: ingest.excluded)
            }
            GridRow {
                counterCell("No timestamp",  value: ingest.skippedNoTimestamp)
                counterCell("Unsupported extension", value: ingest.skippedUnknownExtension)
            }
            GridRow {
                counterCell("Reflection risk ≥ 0.5",  value: ingest.reflectionFlagged)
                counterCell("Transitional risk ≥ 0.7", value: ingest.transitionalFlagged)
            }
            GridRow {
                counterCell("Weather-enriched",   value: ingest.enrichedWithWeather)
                counterCell("Meta-sidecar found", value: ingest.enrichedWithMeta)
            }
        }
    }

    private func counterCell(_ label: String, value: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(value)")
                .font(.system(.title3, design: .monospaced))
                .frame(minWidth: 72, alignment: .trailing)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose allsky image folders"
        panel.message = "Pick one or more night folders. Cmd-click or Shift-click in the picker to select multiple at once — the app scans each recursively for JPG and FITS files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        if let last = AppSettings.shared.lastIngestedFolderPath {
            panel.directoryURL = URL(fileURLWithPath: last)
                .deletingLastPathComponent()
        }

        guard panel.runModal() == .OK else { return }
        // Merge with the existing queue, dedup on path, preserve
        // insertion order (newest additions at the end).
        let existing = Set(selectedFolders.map(\.path))
        for url in panel.urls where !existing.contains(url.path) {
            selectedFolders.append(url)
            BookmarkStore.shared.save(url)
        }
        if let first = panel.urls.first {
            AppSettings.shared.lastIngestedFolderPath = first.path
        }
    }

    private func removeFolder(_ url: URL) {
        selectedFolders.removeAll { $0.path == url.path }
    }

    private func restoreLastSelection() {
        if let raw = AppSettings.shared.lastCameraTypeRaw,
           let saved = CameraType(rawValue: raw) {
            cameraType = saved
        }
        if let raw = AppSettings.shared.lastImageFormatRaw,
           let saved = ImageFormat(rawValue: raw) {
            imageFormat = saved
        }
        // Don't auto-fill the queue from the last single-folder
        // setting — most users hitting ⌘O again want to start clean.
        // The picker still opens at the previous parent directory.
    }

    private func startIngest() {
        guard !selectedFolders.isEmpty else { return }
        let folders = selectedFolders
        Task {
            await ingest.ingestFolders(
                folders,
                cameraType: cameraType,
                imageFormat: imageFormat,
                dryRun: dryRun
            )
        }
    }
}
