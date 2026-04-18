import SwiftUI

/// Preferences window. Phase 1 stub — basic observatory / mount settings
/// surface here; autonomous-mode and ML tuning controls are added as
/// those features land.
struct PreferencesView: View {

    @State private var latitude: Double = AppSettings.shared.latitudeDeg
    @State private var longitude: Double = AppSettings.shared.longitudeDeg
    @State private var allskyMount: String = AppSettings.shared.allskyMountPath
    @State private var nasPrefix: String = AppSettings.shared.nasPathPrefix

    var body: some View {
        TabView {
            observatoryTab
                .tabItem { Label("Observatory", systemImage: "location") }
        }
        .frame(width: 520, height: 320)
    }

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
                        .frame(width: 240)
                        .onSubmit { AppSettings.shared.allskyMountPath = allskyMount }
                }
                HStack {
                    Text("NAS path prefix")
                    Spacer()
                    TextField("/volume1/AllSky-Rheine", text: $nasPrefix)
                        .frame(width: 240)
                        .onSubmit { AppSettings.shared.nasPathPrefix = nasPrefix }
                }
            }
        }
        .padding()
    }
}
