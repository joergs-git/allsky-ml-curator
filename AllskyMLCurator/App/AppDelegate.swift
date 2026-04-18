import AppKit
import Foundation

/// Bridges SwiftUI's app lifecycle to AppKit services that SwiftUI
/// cannot express directly: the global NSEvent keyboard monitor and
/// the SMB-mount sanity check.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var keyboardHandler: KeyboardHandler?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyboardHandler = KeyboardHandler()
        keyboardHandler?.install()

        checkSMBMountAvailability()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboardHandler?.uninstall()
    }

    // MARK: - SMB mount check

    /// Verifies that the allsky SMB share is mounted at the configured path
    /// and displays a non-blocking alert if it is not. The curator can still
    /// use the app without the mount, but image loads will fail until the
    /// user connects in Finder.
    private func checkSMBMountAvailability() {
        let mount = AppSettings.shared.allskyMountPath
        let exists = FileManager.default.fileExists(atPath: mount)
        guard !exists else { return }

        let alert = NSAlert()
        alert.messageText = "Synology share not mounted"
        alert.informativeText = """
            The allsky image share is expected at:

                \(mount)

            Open Finder → Go → Connect to Server and mount the share,
            then restart the app or re-trigger ingest.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
