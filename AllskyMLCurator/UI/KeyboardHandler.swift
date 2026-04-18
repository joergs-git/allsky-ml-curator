import AppKit
import Foundation

/// Global keyboard monitor for the curator. Uses an NSEvent local monitor
/// because SwiftUI's .onKeyPress does not support key-repeat well enough
/// for a fast rating workflow.
///
/// Phase 1 stub: only the class shell is in place so AppDelegate links.
/// Key binding wiring (0-5, R, T, arrows, Cmd+A, etc.) lands with the
/// matrix view in Phase 3.
final class KeyboardHandler {

    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Phase 3 will dispatch to the active view controller here.
            // For now, let every event pass through unchanged.
            return event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
