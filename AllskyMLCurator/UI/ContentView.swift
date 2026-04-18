import AppKit
import SwiftUI

/// Main app shell — a toolbar over the keyboard-rating matrix, with
/// ingest reachable as a sheet via `⌘O` or the toolbar button. When
/// the local DB is empty the matrix is replaced by an ingest CTA.
struct ContentView: View {

    // MARK: - State

    @State private var items: [ImageLibrary.ImageListItem] = []
    @State private var selectedIds: Set<Int64> = []
    /// Default filter is `.color` so the dominant OSC feed is the
    /// focus on first launch — the user can flip to "All cameras" or
    /// "Monochrome" from the toolbar and the choice persists in
    /// `AppSettings.lastCameraFilterRaw` across restarts.
    @State private var cameraFilter: CameraType? = {
        if let raw = AppSettings.shared.lastCameraFilterRaw {
            return CameraType(rawValue: raw)
        }
        return nil    // user explicitly picked "All cameras" previously
    }()
    @State private var onlyUnrated: Bool = false
    @State private var columns: Int = 6
    @State private var showIngestSheet: Bool = false
    @State private var showInfoPopover: Bool = false
    @State private var isLoading: Bool = false
    @State private var nightMode: Bool = AppSettings.shared.nightMode

    @ObservedObject private var sync = SyncEngine.shared
    @ObservedObject private var classifier = ClassifierEngine.shared

    /// Coverage of the Vision feature-print sidecar cache — refreshed
    /// periodically so the toolbar chip shows "embed X / Y" progress
    /// while the background generator chews through the matrix.
    @State private var embeddedCount: Int = 0

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
        .task {
            // Poll the embedding sidecar count + classifier coverage
            // every 2 s so the toolbar chips advance live as the
            // background generator writes files and ratings flow in.
            while !Task.isCancelled {
                embeddedCount = EmbeddingPipeline.sidecarCount()
                await classifier.refreshCoverage()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .task {
            // Background warmer: extract embeddings for every rated
            // frame once at launch, independently of what the user
            // scrolls over. The MatrixTileCell .task path only fires
            // for visible tiles, which can leave hundreds of rated
            // frames without embeddings after a session of rapid
            // Cmd+A rating — the classifier then sees only one class
            // and refuses to train. This catches up the gap.
            await warmRatedEmbeddings()
        }
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

    // MARK: - Toolbar

    /// Doubled-height toolbar with a brand badge, Ingest button,
    /// filter controls, and three gauge-style status chips on the
    /// right. A trailing ⓘ button opens a floating info popover with
    /// the full live state.
    private var toolbar: some View {
        HStack(spacing: 16) {
            brandBadge

            Divider().frame(height: 42)

            Button {
                showIngestSheet = true
            } label: {
                Label("Ingest…", systemImage: "tray.and.arrow.down")
                    .font(.body.weight(.medium))
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            Divider().frame(height: 42)

            Picker("Camera", selection: $cameraFilter) {
                Text("All cameras").tag(CameraType?.none)
                ForEach(CameraType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(CameraType?.some(type))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .onChange(of: cameraFilter) { _, newValue in
                AppSettings.shared.lastCameraFilterRaw = newValue?.rawValue
                Task { await reload() }
            }

            Toggle("Only unrated", isOn: $onlyUnrated)
                .onChange(of: onlyUnrated) { _, _ in
                    Task { await reload() }
                }

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

            Spacer()

            classifierGauge
            embeddingGauge
            syncGauge

            infoButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 74)
        .background(AppColors.bgToolbar(nightMode))
    }

    // MARK: - Brand

    private var brandBadge: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.85), .purple.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                Image(systemName: "camera.metering.matrix")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AllSky")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(AppColors.fg(nightMode))
                Text("ML Curator")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.fgDim(nightMode))
            }
        }
    }

    // MARK: - Gauges

    /// Circular accuracy gauge that doubles as the Train button. Fills
    /// with the last training accuracy; pulses its icon while a train
    /// is in flight.
    private var classifierGauge: some View {
        Button {
            Task { await classifier.train() }
        } label: {
            GaugeChip(
                title: "Classifier",
                value: Double(classifier.summary?.trainAccuracy ?? 0),
                range: 0...1,
                primaryText: classifierPrimaryText,
                secondaryText: classifierSecondaryText,
                iconName: classifier.isTraining ? "sparkles" : "brain.head.profile",
                iconAnimates: classifier.isTraining,
                tint: classifierTint,
                nightMode: nightMode
            )
        }
        .buttonStyle(.plain)
        .help(classifier.lastError ?? "Retrain classifier on every current human label (⌘T)")
        .keyboardShortcut("t", modifiers: .command)
        .disabled(classifier.isTraining)
    }

    private var classifierPrimaryText: String {
        if let summary = classifier.summary {
            return "\(Int(summary.trainAccuracy * 100))%"
        }
        if let coverage = classifier.lastCoverage,
           coverage.totalRated > 0 {
            return "\(coverage.withEmbedding)/\(coverage.totalRated)"
        }
        return "—"
    }

    private var classifierSecondaryText: String {
        if classifier.isTraining { return "training…" }
        if let summary = classifier.summary {
            return "\(summary.sampleCount) labels"
        }
        if classifier.lastCoverage != nil { return "untrained" }
        return "no labels"
    }

    private var classifierTint: Color {
        if classifier.lastError != nil { return .red }
        if classifier.isTraining       { return .blue }
        if classifier.summary != nil   { return .green }
        return .orange
    }

    /// Horizontal progress gauge for embedding coverage. Animates when
    /// the warmer is making progress.
    private var embeddingGauge: some View {
        GaugeChip(
            title: "Embeddings",
            value: Double(embeddedCount),
            range: 0...Double(max(items.count, 1)),
            primaryText: "\(embeddedCount) / \(items.count)",
            secondaryText: embeddedCount >= max(items.count, 1)
                ? "complete"
                : "warming…",
            iconName: "cpu",
            iconAnimates: embeddedCount < items.count && items.count > 0,
            tint: embeddedCount >= max(items.count, 1) ? .green : .blue,
            nightMode: nightMode
        )
        .help("Vision FeaturePrint sidecar coverage — warms in the background")
    }

    /// Sync gauge — no percentage, just a status orb + timestamp.
    private var syncGauge: some View {
        Button {
            Task { await sync.pushPending() }
        } label: {
            GaugeChip(
                title: "Sync",
                value: syncGaugeValue,
                range: 0...1,
                primaryText: syncPrimaryText,
                secondaryText: syncSecondaryText,
                iconName: syncIcon,
                iconAnimates: sync.status.isPushing,
                tint: syncTint,
                nightMode: nightMode
            )
        }
        .buttonStyle(.plain)
        .help(syncHelpText)
        .keyboardShortcut("s", modifiers: .command)
    }

    /// Tooltip text for the sync gauge — surfaces the real failure
    /// reason on hover so the user doesn't have to open the info
    /// popover to see why Supabase refused a batch.
    private var syncHelpText: String {
        if case .failed(let message) = sync.status {
            return "Sync failed: \(message)\nClick to retry (⌘S)"
        }
        return "Push unsynced labels to Supabase (⌘S)"
    }

    private var syncGaugeValue: Double {
        switch sync.status {
        case .upToDate:   return 1
        case .pushing(let pushed, let total):
            return total > 0 ? Double(pushed) / Double(total) : 0.5
        case .failed, .idle, .notConfigured:
            return 0
        }
    }

    private var syncPrimaryText: String {
        switch sync.status {
        case .idle:            return "—"
        case .notConfigured:   return "off"
        case .pushing(let n, let t): return "\(n)/\(t)"
        case .upToDate:        return "✓"
        case .failed:          return "!"
        }
    }

    private var syncSecondaryText: String {
        switch sync.status {
        case .idle:                  return "idle"
        case .notConfigured:         return "not set"
        case .pushing:               return "pushing"
        case .upToDate(_, let at):   return at.formatted(date: .omitted, time: .shortened)
        case .failed:                return "failed"
        }
    }

    private var syncIcon: String {
        switch sync.status {
        case .idle, .notConfigured: return "icloud.slash"
        case .pushing:              return "arrow.up.circle"
        case .upToDate:             return "checkmark.icloud.fill"
        case .failed:               return "exclamationmark.icloud.fill"
        }
    }

    private var syncTint: Color {
        switch sync.status {
        case .upToDate: return .green
        case .pushing:  return .blue
        case .failed:   return .red
        default:        return .gray
        }
    }

    // MARK: - Info popover

    private var infoButton: some View {
        Button {
            showInfoPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(AppColors.fgDim(nightMode))
        }
        .buttonStyle(.plain)
        .help("Live status & coverage details")
        .popover(isPresented: $showInfoPopover, arrowEdge: .top) {
            InfoPopoverContent(
                items: items,
                selectedIds: selectedIds,
                embeddedCount: embeddedCount,
                classifier: classifier,
                sync: sync
            )
            .frame(width: 420)
        }
    }

    private var matrix: some View {
        MatrixView(
            items: items,
            columns: columns,
            nightMode: nightMode,
            predictions: classifier.predictions,
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

    /// Walk every rated image sequentially and call
    /// `EmbeddingPipeline.generate` for any that don't yet have a
    /// cached `.fp` sidecar. The pipeline's internal AsyncSemaphore
    /// still caps concurrency at 3, so this doesn't saturate the SMB
    /// channel — it just keeps work flowing while the user rates.
    private func warmRatedEmbeddings() async {
        let rated = await ImageLibrary.shared.fetchRatedImages()
        for image in rated {
            if Task.isCancelled { return }
            if EmbeddingPipeline.shared.cached(for: image.filePath) != nil {
                continue
            }
            _ = await EmbeddingPipeline.shared.generate(
                for: image.filePath,
                cameraType: image.cameraSource.cameraType
            )
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
