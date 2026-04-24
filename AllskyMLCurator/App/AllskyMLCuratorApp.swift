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
        Window(Self.windowTitle, id: "main") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // Seed the window at a comfortable 1400 × 900 instead of its
        // minimum 1100 × 720 — 0.7.6 fix. Without this the window
        // opens at the SwiftUI content frame's minWidth, and once
        // the user hit the green maximize / fullscreen button they
        // couldn't shrink back to anything reasonable.
        .defaultSize(width: 1400, height: 900)
        // `.contentSize` keeps the window strictly tied to the
        // SwiftUI content's min/max — hide-the-title-bar + ⌃⌘F full
        // screen then behave predictably on macOS 14+. Before this
        // the window chrome could drift out of the visible screen
        // area after a maximize cycle, hiding the green traffic
        // light behind the menu bar.
        .windowResizability(.contentSize)
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
            // Edit → Delete Selected. Registered at the Commands
            // level so macOS's standard responder chain routes the
            // shortcut to it even when keyboard focus is on an
            // element outside the matrix (toolbar picker, gauge chip).
            //
            // 0.8.6: primary shortcut is bare ⌫ (Finder / Mail
            // convention for "move the selected row to trash"). The
            // `.onKeyPress` in MatrixView / ListView catches it too
            // when the matrix has focus, but routing through the
            // menu command ensures the shortcut lands even if focus
            // drifted elsewhere. Text fields in Preferences / ingest
            // sheets keep their native ⌫-to-delete-char behaviour —
            // the responder chain gives them priority before menu
            // shortcuts see the event. A second hidden "Edit →
            // Delete Selected (⌘⌫)" command preserves ⌘⌫ for people
            // with macOS muscle memory.
            CommandGroup(after: .pasteboard) {
                Button("Delete Selected Images") {
                    NotificationCenter.default.post(
                        name: .deleteSelectedImagesRequested, object: nil
                    )
                }
                .keyboardShortcut(.delete, modifiers: [])
                Button("Delete Selected Images (⌘⌫ alt)") {
                    NotificationCenter.default.post(
                        name: .deleteSelectedImagesRequested, object: nil
                    )
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            // Belt-and-suspenders escape hatch out of fullscreen /
            // oversized window states. macOS normally provides this
            // as ⌃⌘F on the View menu, but when the window chrome
            // has drifted off-screen the default path can get stuck.
            // Window → Reset Window resets to the default 1400 × 900
            // size and exits fullscreen if active.
            CommandGroup(after: .windowSize) {
                Divider()
                Button("Reset Window") {
                    guard let win = NSApp.keyWindow else { return }
                    if win.styleMask.contains(.fullScreen) {
                        win.toggleFullScreen(nil)
                    }
                    win.setContentSize(NSSize(width: 1400, height: 900))
                    win.center()
                }
                .keyboardShortcut("0", modifiers: [.command, .control])
            }
        }

        Settings {
            PreferencesView()
        }
    }

    /// Bundle-version-aware window title so every release is
    /// self-identifying. Falls back to just "Allsky ML Curator" when
    /// the Info.plist keys are missing (e.g. Xcode previews).
    private static var windowTitle: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (marketing, build) {
        case let (.some(v), .some(b)): return "Allsky ML Curator \(v) (\(b))"
        case let (.some(v), nil):      return "Allsky ML Curator \(v)"
        default:                        return "Allsky ML Curator"
        }
    }
}

/// Cross-component signal fired when the user asks to open a folder
/// (from the File menu, the Cmd+O shortcut, or a button in the UI).
extension Notification.Name {
    static let openAllskyFolderRequested =
        Notification.Name("AllskyMLCurator.openAllskyFolderRequested")
    /// Posted when the user triggers ⌘⌫ / the Edit → Delete menu
    /// item / the tile context menu. Every selection-aware view
    /// (MatrixView, ListView) subscribes and presents its own
    /// confirmation dialog if it owns a non-empty selection.
    static let deleteSelectedImagesRequested =
        Notification.Name("AllskyMLCurator.deleteSelectedImagesRequested")
    /// Posted when Preferences toggles night-only mode or changes its
    /// sun-alt threshold. ContentView listens so the matrix refreshes
    /// immediately rather than staying stale until the next filter
    /// change or ingest.
    static let nightOnlyFilterChanged =
        Notification.Name("AllskyMLCurator.nightOnlyFilterChanged")
}
