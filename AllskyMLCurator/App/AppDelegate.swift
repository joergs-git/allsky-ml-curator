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
        // Re-establish sandbox access to every folder the user
        // previously granted so thumbnail / embedding pipelines keep
        // reading SMB files across relaunches. Without this the
        // matrix shows spinners for any tile whose HEIC wasn't
        // already written in the last session.
        BookmarkStore.shared.restoreAll()

        // Repair any images.filePath that still carries the
        // Synology-internal `/volume1/...` prefix. This only
        // affects rows from the first weather-ingest run, before
        // WeatherIngestSheet learned to remap the prefix. A no-op
        // on a clean DB. Labels + predictions stay attached since
        // we're only rewriting the path column.
        repairLegacyVolumePaths()

        keyboardHandler = KeyboardHandler()
        keyboardHandler?.install()
    }

    private func repairLegacyVolumePaths() {
        do {
            let changed = try Database.shared.writer.write { db -> Int in
                try db.execute(sql: """
                    UPDATE images
                    SET filePath = '/Volumes/' || SUBSTR(filePath, 10)
                    WHERE filePath LIKE '/volume1/%'
                    """)
                return db.changesCount
            }
            if changed > 0 {
                NSLog("AppDelegate repaired \(changed) /volume1 path prefixes at launch.")
            }
        } catch {
            NSLog("AppDelegate /volume1 repair failed: \(error)")
        }
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
