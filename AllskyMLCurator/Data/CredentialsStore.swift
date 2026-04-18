import Foundation

/// Local credential store for the Supabase URL and anon key.
///
/// Originally backed by the macOS Keychain. The dev build is signed
/// ad-hoc, which means its code signature changes with every rebuild
/// — the Keychain ACL no longer recognises the caller and the user
/// gets prompted for the login password on every launch. The Supabase
/// anon key is designed for client-side exposure anyway (RLS does the
/// real policing server-side), and the URL isn't secret at all, so
/// we trade a sliver of at-rest protection for a dramatically better
/// UX: values now live in `UserDefaults` where no prompt ever fires.
///
/// API surface is identical to the old `KeychainStore` so callers
/// don't have to change.
enum CredentialsStore {

    enum StoreError: Error {
        /// Parity placeholder — the UserDefaults backend never throws
        /// in practice; kept so the throwing signature remains stable.
        case writeFailed
    }

    // MARK: - Public API

    static func read(_ account: String) throws -> String? {
        let raw = UserDefaults.standard.string(forKey: namespacedKey(for: account))
        return (raw?.isEmpty == true) ? nil : raw
    }

    static func write(_ value: String, for account: String) throws {
        UserDefaults.standard.set(value, forKey: namespacedKey(for: account))
    }

    static func delete(_ account: String) throws {
        UserDefaults.standard.removeObject(forKey: namespacedKey(for: account))
    }

    // MARK: - Namespacing

    /// Prefix every key so these entries are obvious in `defaults
    /// read com.joergsflow.AllskyMLCurator` output and don't collide
    /// with unrelated settings.
    private static func namespacedKey(for account: String) -> String {
        "credentials." + account
    }
}
