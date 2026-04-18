import SwiftUI

/// Entry point for the Allsky ML Curator.
///
/// The app opens a single main window that hosts the matrix view and
/// single-image inspection view. An NSApplicationDelegateAdaptor bridges
/// to AppKit for the global NSEvent keyboard monitor and for checking
/// that the Synology SMB mount is present at launch.
@main
struct AllskyMLCuratorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Allsky ML Curator", id: "main") {
            ContentView()
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Allsky ML Curator") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
        }

        Settings {
            PreferencesView()
        }
    }
}
