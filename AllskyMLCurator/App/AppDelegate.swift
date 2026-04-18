import AppKit
import Foundation

/// Bridges SwiftUI's app lifecycle to AppKit services that SwiftUI
/// cannot express directly: the global NSEvent keyboard monitor and
/// the SMB-mount sanity check.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var keyboardHandler: KeyboardHandler?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        openDatabase()

        keyboardHandler = KeyboardHandler()
        keyboardHandler?.install()
    }

    /// Open (and migrate) the local SQLite store. The app can function
    /// without the DB for pure read-only flows, but the ingest pipeline
    /// needs it — so a failure here becomes a visible alert rather than
    /// a silent null-pointer later.
    private func openDatabase() {
        do {
            let url = try Database.defaultURL()
            try Database.shared.open(at: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open local database"
            alert.informativeText = """
                \(error.localizedDescription)

                Ingest and labelling are disabled until this is resolved.
                """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboardHandler?.uninstall()
    }

}
