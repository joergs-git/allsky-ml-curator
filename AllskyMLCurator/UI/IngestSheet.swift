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

    @State private var selectedFolder: URL?
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
            HStack {
                Text("Folder:")
                    .frame(width: 70, alignment: .trailing)
                if let url = selectedFolder {
                    Text(url.path)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("none — click Change…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change…") { openFolderPicker() }
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
                Button(ingest.isRunning ? "Working…" : (dryRun ? "Dry-run" : "Ingest")) {
                    startIngest()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ingest.isRunning || selectedFolder == nil)

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
        panel.title = "Choose an allsky image folder"
        panel.message = "Pick the root folder — the app scans it recursively for JPG and FITS files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = selectedFolder {
            panel.directoryURL = current.deletingLastPathComponent()
        } else if let last = AppSettings.shared.lastIngestedFolderPath {
            panel.directoryURL = URL(fileURLWithPath: last)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolder = url
        AppSettings.shared.lastIngestedFolderPath = url.path
        // Persist a security-scoped bookmark so future app launches
        // retain read access to this folder and its SMB contents.
        BookmarkStore.shared.save(url)
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
        if selectedFolder == nil, let path = AppSettings.shared.lastIngestedFolderPath {
            selectedFolder = URL(fileURLWithPath: path)
        }
    }

    private func startIngest() {
        guard let folder = selectedFolder else { return }
        Task {
            await ingest.ingestFolder(
                folder,
                cameraType: cameraType,
                imageFormat: imageFormat,
                dryRun: dryRun
            )
        }
    }
}
