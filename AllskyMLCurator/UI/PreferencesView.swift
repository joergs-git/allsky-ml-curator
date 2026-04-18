import SwiftUI

/// Preferences window. Phase-1 scope: observatory location, Synology
/// mount remap, and the Supabase URL + anon key needed by the ingest
/// service. Autonomous-mode + ML-tuning controls land in later phases.
struct PreferencesView: View {

    @State private var latitude: Double = AppSettings.shared.latitudeDeg
    @State private var longitude: Double = AppSettings.shared.longitudeDeg
    @State private var allskyMount: String = AppSettings.shared.allskyMountPath
    @State private var nasPrefix: String = AppSettings.shared.nasPathPrefix

    @State private var supabaseUrl: String = ""
    @State private var supabaseAnonKey: String = ""
    @State private var supabaseStatus: String = ""
    @State private var supabaseTesting: Bool = false

    var body: some View {
        TabView {
            observatoryTab
                .tabItem { Label("Observatory", systemImage: "location") }
            supabaseTab
                .tabItem { Label("Supabase", systemImage: "externaldrive.connected.to.line.below") }
        }
        .frame(width: 560, height: 360)
        .onAppear(perform: loadSupabaseConfig)
    }

    // MARK: - Observatory tab

    private var observatoryTab: some View {
        Form {
            Section("Location") {
                HStack {
                    Text("Latitude (°N)")
                    Spacer()
                    TextField("52.17", value: $latitude, format: .number)
                        .frame(width: 120)
                        .onSubmit { AppSettings.shared.latitudeDeg = latitude }
                }
                HStack {
                    Text("Longitude (°E)")
                    Spacer()
                    TextField("7.25", value: $longitude, format: .number)
                        .frame(width: 120)
                        .onSubmit { AppSettings.shared.longitudeDeg = longitude }
                }
            }

            Section("Synology mount") {
                HStack {
                    Text("Mount path")
                    Spacer()
                    TextField("/Volumes/AllSky-Rheine", text: $allskyMount)
                        .frame(width: 280)
                        .onSubmit { AppSettings.shared.allskyMountPath = allskyMount }
                }
                HStack {
                    Text("NAS path prefix")
                    Spacer()
                    TextField("/volume1/AllSky-Rheine", text: $nasPrefix)
                        .frame(width: 280)
                        .onSubmit { AppSettings.shared.nasPathPrefix = nasPrefix }
                }
            }
        }
        .padding()
    }

    // MARK: - Supabase tab

    private var supabaseTab: some View {
        Form {
            Section("Project") {
                HStack {
                    Text("URL")
                    Spacer()
                    TextField("https://PROJECT_REF.supabase.co", text: $supabaseUrl)
                        .frame(width: 340)
                        .textContentType(.URL)
                }
                HStack(alignment: .top) {
                    Text("Anon key")
                    Spacer()
                    SecureField("paste the anon key", text: $supabaseAnonKey)
                        .frame(width: 340)
                }
            }
            Section {
                HStack {
                    Button("Test connection") { Task { await testConnection() } }
                        .disabled(supabaseTesting || supabaseUrl.isEmpty || supabaseAnonKey.isEmpty)
                    Button("Save") { saveSupabaseConfig() }
                        .keyboardShortcut(.defaultAction)
                    if supabaseTesting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if !supabaseStatus.isEmpty {
                    Text(supabaseStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Values are stored in the macOS Keychain, never in UserDefaults or on disk. Environment variables `SUPABASE_URL` / `SUPABASE_ANON_KEY` override Keychain when set in the launch environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
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
        // Save before testing so the client reads the latest values.
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
