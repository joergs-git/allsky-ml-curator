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
        // Back-fill reflectionRiskScore for daytime colour-camera
        // rows whose score was computed under the pre-fix formula
        // that returned 0 for any sun above the horizon.
        repairLegacyReflectionRisk()

        keyboardHandler = KeyboardHandler()
        keyboardHandler?.install()
    }

    /// Back-fill reflectionRiskScore for color-camera daytime rows
    /// that were ingested under the pre-fix "sun above horizon →
    /// 0 risk" formula. Idempotent: only touches rows whose current
    /// score is below the new daylight floor (0.7).
    private func repairLegacyReflectionRisk() {
        do {
            let patched = try Database.shared.writer.write { db -> Int in
                try db.execute(sql: """
                    UPDATE images
                    SET reflectionRiskScore = max(
                        reflectionRiskScore,
                        max(0.7, 1.0 - abs(sunAltDeg - 30.0) / 60.0)
                    )
                    WHERE cameraSource = 'color_allsky_jpg'
                      AND sunAltDeg > 0
                      AND reflectionRiskScore < 0.7
                    """)
                return db.changesCount
            }
            if patched > 0 {
                NSLog("AppDelegate repaired \(patched) daytime reflectionRiskScore entries at launch.")
            }
        } catch {
            NSLog("AppDelegate reflection-risk repair failed: \(error)")
        }
    }

    private func repairLegacyVolumePaths() {
        do {
            let (prefixFixed, cameraFixed) = try Database.shared.writer.write { db -> (Int, Int) in
                // 1. Synology-internal prefix → local mount prefix.
                try db.execute(sql: """
                    UPDATE images
                    SET filePath = '/Volumes/' || SUBSTR(filePath, 10)
                    WHERE filePath LIKE '/volume1/%'
                    """)
                let prefix = db.changesCount

                // 2. cameraSource ↔ path-pattern consistency for the
                // Rheine rig. The first weather-ingest pass (before
                // aa24653) pulled allsky_url for `.color` which is
                // actually the mono camera's path on this user's
                // setup. Fix: anything under `/zwo/` is the colour
                // ZWO ASI676MC, everything else under
                // `/Volumes/AllSky-Rheine/` is the mono SX CCD.
                // Deterministic rewrite; labels + predictions keep
                // their FK on the image row.
                try db.execute(sql: """
                    UPDATE images
                    SET cameraSource = 'mono_allsky_jpg'
                    WHERE cameraSource = 'color_allsky_jpg'
                      AND filePath LIKE '/Volumes/AllSky-Rheine/%'
                      AND filePath NOT LIKE '/Volumes/AllSky-Rheine/zwo/%'
                    """)
                let toMono = db.changesCount

                try db.execute(sql: """
                    UPDATE images
                    SET cameraSource = 'color_allsky_jpg'
                    WHERE cameraSource = 'mono_allsky_jpg'
                      AND filePath LIKE '/Volumes/AllSky-Rheine/zwo/%'
                    """)
                let toColor = db.changesCount

                return (prefix, toMono + toColor)
            }
            if prefixFixed > 0 {
                NSLog("AppDelegate repaired \(prefixFixed) /volume1 path prefixes at launch.")
            }
            if cameraFixed > 0 {
                NSLog("AppDelegate repaired \(cameraFixed) cameraSource mismatches at launch.")
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
