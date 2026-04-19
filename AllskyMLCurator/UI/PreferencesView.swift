import SwiftUI

/// Preferences window. Two tabs for now: Observatory location and
/// Supabase credentials. Further tabs (autonomous-mode tuning,
/// thumbnail cache limits) join in later phases.
///
/// Layout uses `LabeledContent` + `formStyle(.grouped)` so the window
/// sizes to its content and stays readable at the default macOS
/// Preferences width. A `minWidth / minHeight` frame keeps the window
/// resizable but prevents a manual shrink below usable dimensions.
struct PreferencesView: View {

    // MARK: - Observatory state

    @State private var latitude: Double  = AppSettings.shared.latitudeDeg
    @State private var longitude: Double = AppSettings.shared.longitudeDeg

    // MARK: - Camera geometry state

    @State private var colorCenterX: Int = AppSettings.shared.colorFisheyeCenterXPx
    @State private var colorCenterY: Int = AppSettings.shared.colorFisheyeCenterYPx
    @State private var colorRadius:  Int = AppSettings.shared.colorFisheyeRadiusPx
    @State private var monoCenterX:  Int = AppSettings.shared.monoFisheyeCenterXPx
    @State private var monoCenterY:  Int = AppSettings.shared.monoFisheyeCenterYPx
    @State private var monoRadius:   Int = AppSettings.shared.monoFisheyeRadiusPx
    @State private var colorFov:     Double = AppSettings.shared.colorFovDeg
    @State private var monoFov:      Double = AppSettings.shared.monoFovDeg
    @State private var horizonExclusion: Double = AppSettings.shared.horizonExclusionDeg
    @State private var colorNorthOffset: Double = AppSettings.shared.colorNorthOffsetDeg
    @State private var monoNorthOffset:  Double = AppSettings.shared.monoNorthOffsetDeg

    // MARK: - Training tab state

    @State private var trainingLR: Double       = AppSettings.shared.trainingLearningRate
    @State private var trainingIterations: Int  = AppSettings.shared.trainingIterations
    @State private var trainingL2: Double       = AppSettings.shared.trainingL2
    @State private var classBoosts: [Double]    = AppSettings.shared.classWeightBoosts
    @State private var autoThreshold: Double    = AppSettings.shared.autonomousConfidenceThreshold
    @State private var autoMinLabels: Int       = AppSettings.shared.autonomousMinLabels

    // MARK: - Advanced tab state

    @State private var purgeConfirmScope: PurgeService.Scope?
    @State private var purgeStatus: String = ""
    @State private var isPurging: Bool = false
    @State private var isRebuildingThumbnails: Bool = false
    @State private var rebuildProgress: ThumbnailCache.RebuildProgress?
    @State private var rebuildTask: Task<Void, Never>?
    @ObservedObject private var warmer = EmbeddingWarmer.shared

    // MARK: - Supabase state

    @State private var supabaseUrl: String      = ""
    @State private var supabaseAnonKey: String  = ""
    @State private var supabaseStatus: String   = ""
    @State private var supabaseTesting: Bool    = false

    var body: some View {
        TabView {
            observatoryTab
                .tabItem { Label("Observatory", systemImage: "location") }
            cameraTab
                .tabItem { Label("Camera", systemImage: "camera") }
            trainingTab
                .tabItem { Label("Training", systemImage: "brain.head.profile") }
            supabaseTab
                .tabItem { Label("Supabase", systemImage: "externaldrive.connected.to.line.below") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "exclamationmark.triangle") }
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear(perform: loadSupabaseConfig)
    }

    // MARK: - Observatory tab

    private var observatoryTab: some View {
        Form {
            Section("Location") {
                LabeledContent("Latitude (°N)") {
                    TextField("52.17", value: $latitude, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: latitude) { _, newValue in
                            AppSettings.shared.latitudeDeg = newValue
                        }
                }
                LabeledContent("Longitude (°E)") {
                    TextField("7.25", value: $longitude, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: longitude) { _, newValue in
                            AppSettings.shared.longitudeDeg = newValue
                        }
                }
            }
            Section {
                Text("Latitude / longitude are used to compute sun and moon ephemeris for every ingested frame. Default is the Rheine observatory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Camera tab

    private var cameraTab: some View {
        Form {
            Section("Color (OSC) fisheye geometry") {
                LabeledContent("Center X (px)") {
                    TextField("", value: $colorCenterX, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: colorCenterX) { _, new in
                            AppSettings.shared.colorFisheyeCenterXPx = new
                        }
                }
                LabeledContent("Center Y (px)") {
                    TextField("", value: $colorCenterY, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: colorCenterY) { _, new in
                            AppSettings.shared.colorFisheyeCenterYPx = new
                        }
                }
                LabeledContent("Radius (px)") {
                    TextField("", value: $colorRadius, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: colorRadius) { _, new in
                            AppSettings.shared.colorFisheyeRadiusPx = new
                        }
                }
            }

            Section("Monochrome fisheye geometry") {
                LabeledContent("Center X (px)") {
                    TextField("", value: $monoCenterX, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: monoCenterX) { _, new in
                            AppSettings.shared.monoFisheyeCenterXPx = new
                        }
                }
                LabeledContent("Center Y (px)") {
                    TextField("", value: $monoCenterY, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: monoCenterY) { _, new in
                            AppSettings.shared.monoFisheyeCenterYPx = new
                        }
                }
                LabeledContent("Radius (px)") {
                    TextField("", value: $monoRadius, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: monoRadius) { _, new in
                            AppSettings.shared.monoFisheyeRadiusPx = new
                        }
                }
            }

            Section("Field of view + zenith crop") {
                LabeledContent("Color FoV (°)") {
                    TextField("", value: $colorFov, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: colorFov) { _, new in
                            AppSettings.shared.colorFovDeg = new
                        }
                }
                LabeledContent("Monochrome FoV (°)") {
                    TextField("", value: $monoFov, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: monoFov) { _, new in
                            AppSettings.shared.monoFovDeg = new
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Horizon exclusion (°)")
                        Spacer()
                        Text(String(format: "%.0f°", horizonExclusion))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $horizonExclusion,
                        in: 0...45,
                        step: 1
                    )
                    .onChange(of: horizonExclusion) { _, new in
                        AppSettings.shared.horizonExclusionDeg = new
                    }
                    Text(cropSummaryText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Section("Compass alignment") {
                LabeledContent("Color north offset (°)") {
                    TextField("0", value: $colorNorthOffset, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: colorNorthOffset) { _, new in
                            AppSettings.shared.colorNorthOffsetDeg = new
                        }
                }
                LabeledContent("Mono north offset (°)") {
                    TextField("0", value: $monoNorthOffset, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: monoNorthOffset) { _, new in
                            AppSettings.shared.monoNorthOffsetDeg = new
                        }
                }
                Text("Rotation, in degrees, of true north away from straight-up-in-the-frame. 0° when a compass-aligned rig shows north at the top; positive rotates clockwise (as the image prints on screen). Only used by the v2 cloud-motion bearing feature — safe to leave at 0 until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("Fisheye center + radius describe the sky disk inside each rectangular frame. Field-of-view + horizon exclusion drive the zenith crop applied to both the matrix thumbnail and the ML embedding. 30° exclusion matches the elevation below which ground-based astro rarely points — setting it higher focuses the rating on the zenith cone, lower lets more horizon through.\n\nDefaults: ZWO ASI676MC OSC (176° FoV) + SX CCD SuperStar mono (112.5°). Changing any value invalidates the caches; next scroll regenerates them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Computed summary line under the Horizon-exclusion slider —
    /// tells the user how the number translates into image pixels per
    /// camera so the physics stays tangible.
    private var cropSummaryText: String {
        // Recompute via explicit math instead of calling the helper
        // so the text reacts to the in-progress @State values before
        // onChange has flushed them into AppSettings.
        let horizonAngle = 90.0 - horizonExclusion
        let colorFrac = max(0.1, min(1.0, horizonAngle / (colorFov / 2)))
        let monoFrac  = max(0.1, min(1.0, horizonAngle / (monoFov / 2)))
        let colorConeDeg = (colorFov / 2) * colorFrac
        let monoConeDeg  = (monoFov / 2) * monoFrac
        let colorLine = String(
            format: "Color keeps %d %% of the fisheye radius (≈ zenith ± %.0f°).",
            Int(colorFrac * 100), colorConeDeg
        )
        let monoLine = String(
            format: "Mono keeps %d %% of the fisheye radius (≈ zenith ± %.0f°).",
            Int(monoFrac * 100), monoConeDeg
        )
        return colorLine + "\n" + monoLine
    }

    // MARK: - Training tab

    /// Hyperparameter knobs for the logistic-regression head and the
    /// autonomous auto-rater. All values take effect on the *next*
    /// train / auto-rate pass — no restart needed. Sliders are ranged
    /// around defaults known to converge on the Rheine data; values
    /// outside these ranges rarely help and make debugging harder.
    private var trainingTab: some View {
        Form {
            Section("Logistic-regression head") {
                sliderRow(
                    label: "Learning rate",
                    value: $trainingLR,
                    range: 0.005...0.2,
                    step: 0.005,
                    displayFormat: "%.3f"
                ) { new in AppSettings.shared.trainingLearningRate = new }

                integerSliderRow(
                    label: "Iterations",
                    value: $trainingIterations,
                    range: 50...500,
                    step: 10
                ) { new in AppSettings.shared.trainingIterations = new }

                sliderRow(
                    label: "L2 regularisation",
                    value: $trainingL2,
                    range: 0...0.01,
                    step: 0.0001,
                    displayFormat: "%.4f"
                ) { new in AppSettings.shared.trainingL2 = new }

            }

            Section("Per-class boost (× inverse-frequency)") {
                ForEach(0..<5, id: \.self) { index in
                    classBoostRow(index: index)
                }
                Text("Each slider is a multiplier on top of inverse-frequency weighting. Start every class at 1.0× for pure balance. If a class keeps losing its share of the gradient (low recall despite many samples), raise *that* class. If a class gets over-predicted, lower it. The 0.4.1 default boosted classes 4 + 5 blindly, which collapsed class 1 on Rheine's library; 0.4.2 switches to a per-class vector so the knob targets the actual failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Autonomous auto-rate (⌘⇧A)") {
                sliderRow(
                    label: "Confidence threshold",
                    value: $autoThreshold,
                    range: 0.3...0.95,
                    step: 0.01,
                    displayFormat: "%.0f %%",
                    displayScale: 100
                ) { new in AppSettings.shared.autonomousConfidenceThreshold = new }

                integerSliderRow(
                    label: "Min human labels",
                    value: $autoMinLabels,
                    range: 50...1000,
                    step: 10
                ) { new in AppSettings.shared.autonomousMinLabels = new }
            }

            Section {
                HStack {
                    Button("Reset training defaults") {
                        AppSettings.shared.resetTrainingHyperparameters()
                        trainingLR         = AppSettings.shared.trainingLearningRate
                        trainingIterations = AppSettings.shared.trainingIterations
                        trainingL2         = AppSettings.shared.trainingL2
                        classBoosts        = AppSettings.shared.classWeightBoosts
                        autoThreshold      = AppSettings.shared.autonomousConfidenceThreshold
                        autoMinLabels      = AppSettings.shared.autonomousMinLabels
                    }
                    Spacer()
                }
            }

            Section {
                Text("Changes take effect on the next ⌘T (train) and ⌘⇧A (auto-rate). Higher learning rate + fewer iterations trains faster but may oscillate around the minimum; lower rate + more iterations converges more smoothly. L2 > 0 stabilises tiny training sets but blunts the model as data grows. The clear-sky boost counters Rheine's cloud-dominant distribution — lower it when the confusion matrix shows class 5 being over-predicted. Raise the auto-rate threshold for more human oversight, lower it for more autonomy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Slider row that commits to `AppSettings` on every change. The
    /// display format runs against `value * displayScale` so the same
    /// row can render a 0…1 probability as a 0…100 percentage without
    /// duplicating the binding.
    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        displayFormat: String,
        displayScale: Double = 1.0,
        onCommit: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: displayFormat, value.wrappedValue * displayScale))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .onChange(of: value.wrappedValue) { _, new in
                    onCommit(new)
                }
        }
    }

    /// Integer variant — SwiftUI's `Slider` is double-backed, so the
    /// binding round-trips through a Double behind the scenes while
    /// the display stays integer.
    private func integerSliderRow(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        onCommit: @escaping (Int) -> Void
    ) -> some View {
        let doubleBinding = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Int($0) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: doubleBinding,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .onChange(of: value.wrappedValue) { _, new in
                onCommit(new)
            }
        }
    }

    /// One row in the per-class boost slider section. Lazily clamps
    /// `classBoosts.count` to 5 so the binding is safe even if the
    /// stored vector was ever truncated.
    @ViewBuilder private func classBoostRow(index: Int) -> some View {
        let binding = Binding<Double>(
            get: {
                guard index < classBoosts.count else { return 1.0 }
                return classBoosts[index]
            },
            set: { new in
                while classBoosts.count <= index { classBoosts.append(1.0) }
                classBoosts[index] = new
            }
        )
        sliderRow(
            label: classBoostLabel(for: index),
            value: binding,
            range: 0.1...5.0,
            step: 0.1,
            displayFormat: "%.1f×"
        ) { _ in
            AppSettings.shared.classWeightBoosts = classBoosts
        }
    }

    private func classBoostLabel(for index: Int) -> String {
        switch index {
        case 0: return "1 · full clouds"
        case 1: return "2 · mostly clouds"
        case 2: return "3 · some clouds"
        case 3: return "4 · little / thin"
        case 4: return "5 · clear"
        default: return "class \(index + 1)"
        }
    }

    // MARK: - Advanced tab

    private var advancedTab: some View {
        Form {
            Section("Supabase") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resend all ratings to Supabase")
                            .font(.subheadline.weight(.semibold))
                        Text("Flips `synced_to_supabase = false` on every local label, so the next push re-uploads the full set. Use after a DTO change that adds fields (image hash, camera profile id, …) so the server rows catch up. Safe — Supabase upserts on image_path, identical content is a no-op.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Resend…") {
                        Task {
                            purgeStatus = "Marking all labels for resync…"
                            isPurging = true
                            await SyncEngine.shared.markAllForResync()
                            await SyncEngine.shared.pushPending()
                            purgeStatus = "Resync triggered. Watch the sync gauge."
                            isPurging = false
                        }
                    }
                    .disabled(isPurging)
                }
                .padding(.vertical, 4)
            }

            Section("Sandbox access") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grant folder access")
                            .font(.subheadline.weight(.semibold))
                        Text("Re-authorise the sandbox for a folder (e.g. /Volumes/AllSky-Rheine). A security-scoped bookmark is stored so access persists across app relaunches. Without this, the matrix loses SMB read access every time you quit and the thumbnail / embedding pipelines silently fail for anything not already cached on disk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        let granted = BookmarkStore.shared.grantedPaths
                        if !granted.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(granted, id: \.self) { p in
                                    HStack {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green)
                                        Text(p)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    Spacer()
                    Button("Grant…") {
                        grantFolderAccess()
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Embedding warmer") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Re-run Vision FeaturePrint warmer")
                            .font(.subheadline.weight(.semibold))
                        Text("Walks every rated frame first (so ⌘T has something to train on) then every unrated frame (so the matrix can show brain badges), writing a `.fp` sidecar for anything that's missing. The launch-time warmer snapshots the rated list exactly once, so any frames you rate *during* the session stay unembedded until this button re-snapshots and catches them up. Safe to run any time — `sidecarExists` guards skip every frame that's already cached.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if warmer.isRunning {
                            embeddingWarmerProgressView
                                .padding(.top, 4)
                        } else if let finished = warmer.lastFinishedAt {
                            Text("Last finished: \(finished.formatted(date: .omitted, time: .shortened))  ·  \(warmer.lastSummary ?? "done")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    Spacer()
                    if warmer.isRunning {
                        Button("Cancel") {
                            warmer.cancel()
                        }
                    } else {
                        Button("Re-run…") {
                            warmer.run()
                        }
                        .disabled(isPurging)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Thumbnail repair") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rebuild missing thumbnails")
                            .font(.subheadline.weight(.semibold))
                        Text("Walks every image in the local index and regenerates any thumbnail whose HEIC sidecar isn't on disk under the current camera geometry + crop fraction. Fixes the 'chunk gap' symptom where changing Preferences → Camera leaves the matrix with spinners for part of the library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let p = rebuildProgress {
                            ProgressView(value: p.fraction)
                                .progressViewStyle(.linear)
                                .padding(.top, 4)
                            Text("\(p.done) of \(p.total) — \(p.regenerated) regenerated, \(p.skipped) already on disk")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isRebuildingThumbnails {
                        Button("Cancel") {
                            rebuildTask?.cancel()
                        }
                    } else {
                        Button("Rebuild…") {
                            startThumbnailRebuild()
                        }
                        .disabled(isPurging)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Fresh start") {
                Text("These actions are destructive. Use only when you want to wipe state and restart from scratch — e.g. after a schema change or a bad ingest run. Supabase rows and the Keychain (Supabase URL / key) are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(PurgeService.Scope.allCases, id: \.self) { scope in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scope.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(scope.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Purge…") {
                            purgeConfirmScope = scope
                        }
                        .disabled(isPurging)
                        .tint(scope == .everything ? .red : .orange)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !purgeStatus.isEmpty {
                Section {
                    Text(purgeStatus)
                        .font(.caption)
                        .foregroundStyle(purgeStatus.contains("failed") ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            item: $purgeConfirmScope
        ) { scope in
            Alert(
                title: Text("Purge \(scope.displayName)?"),
                message: Text(scope.explanation + "\n\nThis cannot be undone."),
                primaryButton: .destructive(Text("Purge")) {
                    runPurge(scope)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func runPurge(_ scope: PurgeService.Scope) {
        isPurging = true
        purgeStatus = "Purging \(scope.displayName.lowercased())…"
        Task {
            let summary = await PurgeService.purge(scope)
            purgeStatus = summary
            isPurging = false
        }
    }

    private func grantFolderAccess() {
        let panel = NSOpenPanel()
        panel.title = "Grant access to the allsky root folder"
        panel.message = "Pick the parent folder that holds every image date directory (e.g. /Volumes/AllSky-Rheine). A security-scoped bookmark is persisted so the sandbox keeps access across app relaunches."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ok = BookmarkStore.shared.save(url)
        purgeStatus = ok
            ? "Bookmark saved — access restored for \(url.path)."
            : "Bookmark save failed. Check Console.app for details."
    }

    @ViewBuilder private var embeddingWarmerProgressView: some View {
        let fraction: Double = {
            guard warmer.total > 0 else { return 0 }
            return Double(warmer.done) / Double(warmer.total)
        }()
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            Text(embeddingWarmerProgressLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var embeddingWarmerProgressLabel: String {
        switch warmer.phase {
        case .idle:
            return "idle"
        case .scanning:
            return "Scanning the library…"
        case .rated:
            return "Rated phase — \(warmer.done) of \(warmer.total) walked, \(warmer.newlyEmbedded) new sidecar(s) written"
        case .unrated:
            return "Unrated phase — \(warmer.done) of \(warmer.total) walked, \(warmer.newlyEmbedded) new sidecar(s) written"
        }
    }

    private func startThumbnailRebuild() {
        guard !isRebuildingThumbnails else { return }
        isRebuildingThumbnails = true
        rebuildProgress = ThumbnailCache.RebuildProgress(
            done: 0, total: 0, regenerated: 0, skipped: 0
        )
        rebuildTask = Task {
            await ThumbnailCache.shared.rebuildMissing { snapshot in
                Task { @MainActor in rebuildProgress = snapshot }
            }
            await MainActor.run {
                isRebuildingThumbnails = false
                rebuildTask = nil
            }
        }
    }

    // MARK: - Supabase tab

    private var supabaseTab: some View {
        Form {
            Section("astro-weather project") {
                LabeledContent("URL") {
                    TextField("https://PROJECT_REF.supabase.co", text: $supabaseUrl)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                }
                LabeledContent("Anon key") {
                    SecureField("paste the anon key", text: $supabaseAnonKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Button("Save") { saveSupabaseConfig() }
                        .keyboardShortcut(.defaultAction)
                    Button("Test connection") {
                        Task { await testConnection() }
                    }
                    .disabled(supabaseTesting
                              || supabaseUrl.isEmpty
                              || supabaseAnonKey.isEmpty)
                    if supabaseTesting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if !supabaseStatus.isEmpty {
                    Text(supabaseStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Text("Values are stored in UserDefaults. The Supabase anon key is designed for client-side use (RLS policies do the real enforcement server-side) and the URL is never secret, so Keychain-level protection isn't worth the per-launch login prompt that an ad-hoc-signed dev build otherwise triggers. Environment variables SUPABASE_URL and SUPABASE_ANON_KEY override the stored values when set in the Xcode launch environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func loadSupabaseConfig() {
        if let config = SupabaseClient.shared.loadConfig() {
            supabaseUrl = config.urlString
            supabaseAnonKey = config.anonKey
        }
    }

    private func saveSupabaseConfig() {
        do {
            try SupabaseClient.shared.saveConfig(
                urlString: supabaseUrl.isEmpty ? nil : supabaseUrl,
                anonKey:   supabaseAnonKey.isEmpty ? nil : supabaseAnonKey
            )
            supabaseStatus = "saved to Keychain"
        } catch {
            supabaseStatus = "save failed: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        supabaseTesting = true
        supabaseStatus = "testing…"
        do {
            try SupabaseClient.shared.saveConfig(
                urlString: supabaseUrl, anonKey: supabaseAnonKey
            )
            try await SupabaseClient.shared.healthCheck()
            supabaseStatus = "OK — connection + auth succeeded"
        } catch {
            let description = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            supabaseStatus = "failed: \(description)"
        }
        supabaseTesting = false
    }
}
