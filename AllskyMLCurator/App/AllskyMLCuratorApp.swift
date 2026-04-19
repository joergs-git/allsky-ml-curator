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
            // level so macOS's standard responder chain routes
            // ⌘⌫ to it — the .background + .keyboardShortcut(.delete,
            // modifiers: .command) trick on an opacity-0 Button did
            // not reliably pick the combo up.
            CommandGroup(after: .pasteboard) {
                Button("Delete Selected Images") {
                    NotificationCenter.default.post(
                        name: .deleteSelectedImagesRequested, object: nil
                    )
                }
                .keyboardShortcut(.delete, modifiers: .command)
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
}
