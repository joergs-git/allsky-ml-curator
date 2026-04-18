import AppKit
import SwiftUI

/// Main app shell — a toolbar over the keyboard-rating matrix, with
/// ingest reachable as a sheet via `⌘O` or the toolbar button. When
/// the local DB is empty the matrix is replaced by an ingest CTA.
struct ContentView: View {

    // MARK: - State

    @State private var items: [ImageLibrary.ImageListItem] = []
    @State private var selectedIds: Set<Int64> = []
    @State private var cameraFilter: CameraType? = nil
    @State private var onlyUnrated: Bool = false
    @State private var columns: Int = 6
    @State private var showIngestSheet: Bool = false
    @State private var isLoading: Bool = false
    @State private var nightMode: Bool = AppSettings.shared.nightMode

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if items.isEmpty && !isLoading {
                emptyState
            } else {
                matrix
            }
        }
        .background(AppColors.bg(nightMode))
        .task { await reload() }
        .sheet(isPresented: $showIngestSheet, onDismiss: {
            Task { await reload() }
        }) {
            IngestSheet(isPresented: $showIngestSheet)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .openAllskyFolderRequested
        )) { _ in
            showIngestSheet = true
        }
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                showIngestSheet = true
            } label: {
                Label("Ingest…", systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider().frame(height: 20)

            Picker("Camera", selection: $cameraFilter) {
                Text("All cameras").tag(CameraType?.none)
                ForEach(CameraType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(CameraType?.some(type))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .onChange(of: cameraFilter) { _, _ in
                Task { await reload() }
            }

            Toggle("Only unrated", isOn: $onlyUnrated)
                .onChange(of: onlyUnrated) { _, _ in
                    Task { await reload() }
                }

            Spacer()

            HStack(spacing: 6) {
                Text("Grid")
                    .font(.caption)
                    .foregroundStyle(AppColors.fgDim(nightMode))
                Picker("", selection: $columns) {
                    Text("4").tag(4)
                    Text("6").tag(6)
                    Text("8").tag(8)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .labelsHidden()
            }

            Toggle("Night", isOn: $nightMode)
                .toggleStyle(.switch)
                .onChange(of: nightMode) { _, new in
                    AppSettings.shared.nightMode = new
                }

            summaryChip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.bgToolbar(nightMode))
    }

    private var summaryChip: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(items.count) frames")
                .font(.caption)
                .foregroundStyle(AppColors.fg(nightMode))
            let rated = items.filter { ($0.label?.ratingClass ?? .unrated) != .unrated }.count
            Text("\(rated) rated · \(selectedIds.count) selected")
                .font(.caption2)
                .foregroundStyle(AppColors.fgDim(nightMode))
        }
    }

    private var matrix: some View {
        MatrixView(
            items: items,
            columns: columns,
            nightMode: nightMode,
            onSelectionChange: { selectedIds = $0 },
            onMutation: { await reload() }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(AppColors.fgVeryDim(nightMode))
            Text("No images indexed yet")
                .font(.title3)
                .foregroundStyle(AppColors.fg(nightMode))
            Text("Pick a folder of allsky JPGs — the app scans it recursively, attaches weather + sidecar metadata, and shows the matrix here for rating.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .foregroundStyle(AppColors.fgDim(nightMode))
            Button("Open Folder…  (⌘O)") {
                showIngestSheet = true
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data loading

    private func reload() async {
        isLoading = true
        let loaded = await ImageLibrary.shared.fetchImages(
            cameraType: cameraFilter,
            onlyUnrated: onlyUnrated
        )
        items = loaded
        selectedIds.formIntersection(Set(loaded.map(\.id)))
        isLoading = false
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
