import AppKit
import SwiftUI

/// Phase-1 root view: folder-based ingest control and live counters.
///
/// Parity with AstroBlink — the user opens any folder via `Cmd+O` or
/// the sidebar button, picks a camera profile, and hits Ingest. Earlier
/// sessions remember the last folder + profile so repeated runs are
/// quick. The matrix view, single-image inspection view and autonomous
/// mode land in subsequent phases.
struct ContentView: View {

    @StateObject private var ingest = IngestService()

    @State private var selectedFolder: URL?
    @State private var selectedProfileId: String = ""
    @State private var dryRun: Bool = true

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, maxWidth: 360)
            ingestPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            restoreLastSelection()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .openAllskyFolderRequested
        )) { _ in
            openFolderPicker()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status").font(.headline)

            statusRow("Supabase config",
                      ok: SupabaseClient.shared.loadConfig() != nil,
                      okMsg: "URL + anon key present (used for weather enrichment)",
                      failMsg: "optional — set in Preferences → Supabase to enrich")

            statusRow("Camera profiles",
                      ok: !CameraProfileStore.shared.profiles.isEmpty,
                      okMsg: "\(CameraProfileStore.shared.profiles.count) loaded",
                      failMsg: "none found — check bundle resources")

            statusRow("Folder",
                      ok: selectedFolder != nil,
                      okMsg: selectedFolder?.path ?? "",
                      failMsg: "pick a folder with Cmd+O or the button below")

            Divider()

            Button { openFolderPicker() } label: {
                Label("Open Folder…  (⌘O)", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Divider()

            Text("Labels")
                .font(.headline)
            Text("Matrix + rating UI arrives in Phase 3.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .background(AppColors.bgToolbar(AppSettings.shared.nightMode))
    }

    private func statusRow(_ label: String, ok: Bool, okMsg: String, failMsg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline)
                Text(ok ? okMsg : failMsg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Ingest pane

    private var ingestPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ingest").font(.title2)
            Text("Scan a folder of allsky JPG/FITS images, pre-compute ephemeris + reflection + transitional scores, and (if Supabase is configured) enrich every frame with the nearest CloudWatcher reading within ±5 min.")
                .font(.body)
                .foregroundStyle(.secondary)

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
        }
        .padding()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Folder:")
                    .frame(width: 60, alignment: .trailing)
                if let url = selectedFolder {
                    Text(url.path)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("none — use ⌘O or the sidebar button")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change…") { openFolderPicker() }
            }

            HStack {
                Text("Camera:")
                    .frame(width: 60, alignment: .trailing)
                Picker("", selection: $selectedProfileId) {
                    ForEach(CameraProfileStore.shared.allIds, id: \.self) { id in
                        if let profile = CameraProfileStore.shared.profile(id: id) {
                            Text(profile.displayName).tag(id)
                        } else {
                            Text(id).tag(id)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 380)
                .onChange(of: selectedProfileId) { _, newId in
                    AppSettings.shared.lastCameraProfileId = newId
                }
                Spacer()
            }

            Toggle("Dry-run (scan + count only, no DB writes)", isOn: $dryRun)

            HStack {
                Button(ingest.isRunning ? "Working…" : (dryRun ? "Dry-run" : "Ingest")) {
                    startIngest()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(ingest.isRunning || selectedFolder == nil || selectedProfileId.isEmpty)

                Button("Cancel") { ingest.cancel() }
                    .disabled(!ingest.isRunning)

                Spacer()
                Text(ingest.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
                counterCell("Weather-enriched", value: ingest.enrichedWithWeather)
                Color.clear
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
    }

    private func restoreLastSelection() {
        if selectedProfileId.isEmpty {
            selectedProfileId = AppSettings.shared.lastCameraProfileId
                ?? CameraProfileStore.shared.allIds.first
                ?? ""
        }
        // Folder access from the last session is not persisted in v1 —
        // but the path is shown as a breadcrumb so the user can
        // re-pick it with one click.
        if selectedFolder == nil, let path = AppSettings.shared.lastIngestedFolderPath {
            selectedFolder = URL(fileURLWithPath: path)
        }
    }

    private func startIngest() {
        guard let folder = selectedFolder, !selectedProfileId.isEmpty else { return }
        Task {
            await ingest.ingestFolder(
                folder,
                profileId: selectedProfileId,
                dryRun: dryRun
            )
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
