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

            Section {
                Text("Fisheye center + radius describe the sky disk inside each rectangular frame. The Phase-2 SkyDiskMask pipeline will crop every image to this circle before feeding it to the ML embedding so burned-in overlay text can't influence the classifier. First-launch defaults match the Rheine rig (ZWO ASI676MC OSC + SX CCD SuperStar mono) and are only a starting point — edit the values above for a different camera. For FITS, future revisions will auto-populate these from the file header (NAXIS1/NAXIS2) when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Text("Values are stored in the macOS Keychain. Environment variables SUPABASE_URL and SUPABASE_ANON_KEY override Keychain when set in the Xcode launch environment.")
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
