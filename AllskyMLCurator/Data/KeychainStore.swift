import Foundation
import Security

/// Minimal wrapper around the macOS Keychain for `kSecClassGenericPassword`.
///
/// Used to persist the Supabase anon key and URL so secrets never land
/// in UserDefaults or a plaintext file the user might accidentally
/// include in a screenshot or commit.
enum KeychainStore {

    // MARK: - Errors

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case dataEncodingFailed
    }

    // MARK: - Service namespace

    private static let service = "com.joergsflow.AllskyMLCurator"

    // MARK: - Read

    /// Returns the stored value for `account`, or `nil` if not present.
    static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataEncodingFailed
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Write

    /// Upsert: if an item for `account` exists it is replaced, otherwise added.
    static func write(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(insertStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Delete

    static func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
