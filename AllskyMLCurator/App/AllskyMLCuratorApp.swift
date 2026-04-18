import SwiftUI

/// Entry point for the Allsky ML Curator.
///
/// The app opens a single main window that hosts the matrix view and
/// single-image inspection view. An NSApplicationDelegateAdaptor bridges
/// to AppKit for the global NSEvent keyboard monitor and for opening
/// the local SQLite database at launch.
@main
struct AllskyMLCuratorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Allsky ML Curator", id: "main") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // Replace the default New-from-template entry with our own
            // Open Folder command so Cmd+O is free and familiar.
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    NotificationCenter.default.post(
                        name: .openAllskyFolderRequested, object: nil
                    )
                }
                .keyboardShortcut("o", modifiers: .command)
            }
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

/// Cross-component signal fired when the user asks to open a folder
/// (from the File menu, the Cmd+O shortcut, or a button in the UI).
extension Notification.Name {
    static let openAllskyFolderRequested =
        Notification.Name("AllskyMLCurator.openAllskyFolderRequested")
}
