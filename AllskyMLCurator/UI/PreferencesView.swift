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

    // MARK: - Advanced tab state

    @State private var purgeConfirmScope: PurgeService.Scope?
    @State private var purgeStatus: String = ""
    @State private var isPurging: Bool = false

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

    // MARK: - Advanced tab

    private var advancedTab: some View {
        Form {
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
