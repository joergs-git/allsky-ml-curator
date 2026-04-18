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

    @ObservedObject private var sync = SyncEngine.shared

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if items.isEmpty && !isLoading {
                emptyState
            } else {
                matrix
                Divider()
                keybindLegend
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

            syncChip

            summaryChip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.bgToolbar(nightMode))
    }

    /// Toolbar chip showing the current Supabase-sync status. Tapping
    /// (or ⌘S) triggers an immediate push of any unsynced labels.
    private var syncChip: some View {
        Button {
            Task { await sync.pushPending() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: syncIcon)
                    .foregroundStyle(syncIconColor)
                Text(sync.status.statusText)
                    .font(.caption)
                    .foregroundStyle(sync.status.isProblem
                                     ? Color.red
                                     : AppColors.fgDim(nightMode))
            }
        }
        .buttonStyle(.plain)
        .help("Push unsynced labels to Supabase (⌘S)")
        .keyboardShortcut("s", modifiers: .command)
    }

    private var syncIcon: String {
        switch sync.status {
        case .idle, .notConfigured: return "arrow.triangle.2.circlepath"
        case .pushing:              return "arrow.up.circle"
        case .upToDate:             return "checkmark.icloud"
        case .failed:               return "exclamationmark.icloud"
        }
    }

    private var syncIconColor: Color {
        switch sync.status {
        case .upToDate:  return .green
        case .failed:    return .red
        case .pushing:   return .blue
        default:         return AppColors.fgDim(nightMode)
        }
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

    private var keybindLegend: some View {
        HStack(spacing: 8) {
            legendRatingChip(key: "0", ratingClass: .unrated,   label: "unrated")
            legendRatingChip(key: "1", ratingClass: .fullCloud, label: "full clouds")
            legendRatingChip(key: "2", ratingClass: .mostly,    label: "mostly")
            legendRatingChip(key: "3", ratingClass: .some,      label: "some clouds")
            legendRatingChip(key: "4", ratingClass: .thin,      label: "thin / dust")
            legendRatingChip(key: "5", ratingClass: .clear,     label: "clear")

            Divider().frame(height: 18)

            legendFlagChip(key: "R", color: AppColors.reflectionFlag(nightMode),
                           label: "reflection (sun / moon on the dome)")
            legendFlagChip(key: "T", color: AppColors.transitionalFlag(nightMode),
                           label: "transitional (dusk / gain-settling garbage)")

            Spacer()

            Text("arrows / page / home-end nav · shift extends · ⌘A select all")
                .font(.caption)
                .foregroundStyle(AppColors.fgVeryDim(nightMode))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.bgToolbar(nightMode))
    }

    private func legendRatingChip(
        key: String, ratingClass: RatingClass, label: String
    ) -> some View {
        legendChip(
            key: key,
            keyBackground: ratingClass == .unrated
                ? AppColors.bgControl(nightMode)
                : AppColors.tier(ratingClass, night: nightMode),
            keyForeground: ratingClass == .unrated
                ? AppColors.fgDim(nightMode)
                : Color.white,
            label: label
        )
    }

    private func legendFlagChip(
        key: String, color: Color, label: String
    ) -> some View {
        legendChip(
            key: key,
            keyBackground: color,
            keyForeground: .white,
            label: label
        )
    }

    private func legendChip(
        key: String,
        keyBackground: Color,
        keyForeground: Color,
        label: String
    ) -> some View {
        VStack(spacing: 3) {
            Text(key)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .frame(minWidth: 20)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(keyBackground)
                .foregroundStyle(keyForeground)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(AppColors.fgDim(nightMode))
        }
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
