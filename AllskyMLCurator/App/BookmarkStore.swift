import AppKit
import Foundation

/// Persists security-scoped bookmarks for user-selected folders so
/// the sandbox keeps access across app relaunches. Without this the
/// app's `com.apple.security.files.user-selected.read-write`
/// entitlement only grants access for the session in which the user
/// picked the folder — the moment the app quits, every SMB path
/// becomes unreadable and any subsequent CGImageSourceCreateWithURL
/// (for a thumbnail that isn't already on disk) returns nil silently.
///
/// Flow:
///   1. After a successful `NSOpenPanel` pick, `save(_:)` archives a
///      security-scoped bookmark into `UserDefaults`.
///   2. At app launch, `restoreAll()` resolves every stored bookmark
///      and calls `startAccessingSecurityScopedResource()` on each.
///   3. Access stays live for the lifetime of the app process.
@MainActor
final class BookmarkStore {

    static let shared = BookmarkStore()
    private init() {}

    /// URLs whose access is currently live. Held strongly so the
    /// `stopAccessingSecurityScopedResource` balance is one-to-one
    /// even if the user re-picks the same folder later.
    private var activeURLs: [URL] = []

    private let defaultsKey = "bookmarks.userGrantedFolders"

    // MARK: - Save

    /// Archive a security-scoped bookmark for `url` and activate
    /// access immediately. Returns false on failure; the caller can
    /// still proceed — the current session's access (from the open
    /// panel itself) is orthogonal to bookmark persistence.
    @discardableResult
    func save(_ url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = storedBookmarks()
            bookmarks[url.path] = data
            store(bookmarks)
            activate(url: url)
            return true
        } catch {
            NSLog("BookmarkStore save failed for \(url.path): \(error)")
            return false
        }
    }

    // MARK: - Restore

    /// Resolve every stored bookmark and start access on each. Stale
    /// bookmarks are dropped silently. Safe to call multiple times;
    /// duplicate activations are de-duplicated via `activeURLs`.
    func restoreAll() {
        let bookmarks = storedBookmarks()
        guard !bookmarks.isEmpty else { return }
        var refreshed = bookmarks

        for (path, data) in bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                activate(url: url)

                // If the bookmark data is stale, regenerate it so a
                // future relaunch gets a fresh copy.
                if isStale {
                    if let fresh = try? url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        refreshed[path] = fresh
                    }
                }
            } catch {
                NSLog("BookmarkStore restore failed for \(path): \(error)")
                refreshed.removeValue(forKey: path)
            }
        }

        if refreshed != bookmarks {
            store(refreshed)
        }
    }

    // MARK: - Inspection

    var grantedPaths: [String] {
        storedBookmarks().keys.sorted()
    }

    func forget(_ path: String) {
        var bookmarks = storedBookmarks()
        bookmarks.removeValue(forKey: path)
        store(bookmarks)
        // Note: we don't stopAccessing; the process continues with the
        // current live access until restart. This is intentional —
        // ripping access mid-session would break in-flight reads.
    }

    // MARK: - Private

    private func activate(url: URL) {
        // Dedup: if another URL with the same path is already live,
        // don't double-start access (each start needs a matching stop,
        // and we intentionally keep these live for the whole process).
        if activeURLs.contains(where: { $0.path == url.path }) { return }
        if url.startAccessingSecurityScopedResource() {
            activeURLs.append(url)
        }
    }

    private func storedBookmarks() -> [String: Data] {
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey)
            as? [String: Data]
        else { return [:] }
        return raw
    }

    private func store(_ bookmarks: [String: Data]) {
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }
}
