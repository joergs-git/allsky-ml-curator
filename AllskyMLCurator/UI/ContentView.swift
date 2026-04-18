import SwiftUI

/// Phase-1 root view: ingest control and live counters.
///
/// The matrix view, single-image inspection view and autonomous-mode
/// overlay are added in subsequent phases — this first screen exists so
/// the curator can verify the Supabase + SMB + camera-profile plumbing
/// end-to-end before any UI complexity lands on top of it.
struct ContentView: View {

    @StateObject private var ingest = IngestService()

    @State private var fromDate: Date = Calendar.current.date(
        byAdding: .day, value: -7, to: Date()
    ) ?? Date()
    @State private var toDate: Date = Date()
    @State private var dryRun: Bool = true

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, maxWidth: 320)
            ingestPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status").font(.headline)

            statusRow("Supabase config",
                      ok: SupabaseClient.shared.loadConfig() != nil,
                      okMsg: "URL + anon key present",
                      failMsg: "set in Preferences → Supabase")

            statusRow("Camera profiles",
                      ok: !CameraProfileStore.shared.profiles.isEmpty,
                      okMsg: "\(CameraProfileStore.shared.profiles.count) loaded",
                      failMsg: "none found — check bundle resources")

            statusRow("Synology mount",
                      ok: FileManager.default.fileExists(atPath: AppSettings.shared.allskyMountPath),
                      okMsg: AppSettings.shared.allskyMountPath,
                      failMsg: "mount the SMB share in Finder")

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
            }
        }
    }

    // MARK: - Ingest pane

    private var ingestPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ingest").font(.title2)
            Text("Pull the Supabase readings for a date range, remap NAS paths to the SMB mount, and build the local image index with pre-computed ephemeris + reflection + transitional risk scores.")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DatePicker("From", selection: $fromDate, displayedComponents: [.date, .hourAndMinute])
                    .frame(maxWidth: 300)
                DatePicker("To",   selection: $toDate,   displayedComponents: [.date, .hourAndMinute])
                    .frame(maxWidth: 300)
            }
            Toggle("Dry-run (query + count only, no local writes)", isOn: $dryRun)

            HStack {
                Button(ingest.isRunning ? "Working…" : (dryRun ? "Dry-run" : "Ingest")) {
                    Task { await ingest.ingest(from: fromDate, to: toDate, dryRun: dryRun) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(ingest.isRunning)

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
                counterCell("Total readings", value: ingest.totalReadings)
                counterCell("Processed",      value: ingest.processed)
            }
            GridRow {
                counterCell("Inserted",       value: ingest.inserted)
                counterCell("Excluded (mono / day)", value: ingest.excluded)
            }
            GridRow {
                counterCell("Missing file",   value: ingest.skippedMissingFile)
                counterCell("No profile",     value: ingest.skippedNoProfile)
            }
            GridRow {
                counterCell("Reflection risk ≥ 0.5",   value: ingest.reflectionFlagged)
                counterCell("Transitional risk ≥ 0.7", value: ingest.transitionalFlagged)
            }
        }
    }

    private func counterCell(_ label: String, value: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(value)")
                .font(.system(.title3, design: .monospaced))
                .frame(minWidth: 64, alignment: .trailing)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
