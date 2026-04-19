import Foundation
import Security

enum KeychainError: LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case notFound
    case accessGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode value for Keychain storage."
        case .saveFailed(let status): "Keychain save failed with status \(status)."
        case .readFailed(let status): "Keychain read failed with status \(status)."
        case .deleteFailed(let status): "Keychain delete failed with status \(status)."
        case .notFound: "Item not found in Keychain."
        case .accessGroupUnavailable: "Keychain access group is unavailable."
        }
    }
}

actor KeychainHelper {
    static let shared = KeychainHelper()

    private let service = Bundle.main.bundleIdentifier ?? "com.poole.james.Trawl"
    private let accessGroup = KeychainAccessGroup.currentValue()

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete existing item first (upsert pattern)
        do {
            try delete(key: key)
        } catch KeychainError.deleteFailed(let status) where status == errSecItemNotFound {
            // No existing item to replace.
        } catch {
            throw error
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility(for: key)
        ].merging(accessGroupQuery(), uniquingKeysWith: { _, new in new })

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func read(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ].merging(accessGroupQuery(), uniquingKeysWith: { _, new in new })

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }

        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }

        return value
    }

    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ].merging(accessGroupQuery(), uniquingKeysWith: { _, new in new })

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private func accessGroupQuery() -> [String: Any] {
        guard let accessGroup else { return [:] }
        return [kSecAttrAccessGroup as String: accessGroup]
    }

    private func accessibility(for key: String) -> CFString {
        if key.hasPrefix("ssh.privatekey.") || key.hasPrefix("ssh.passphrase.") || key.hasPrefix("ssh.password.") {
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        if key.hasPrefix("server_") {
            return kSecAttrAccessibleAfterFirstUnlock
        }

        return kSecAttrAccessibleWhenUnlocked
    }
    private struct KeychainAccessGroup {
        static func currentValue() -> String? {
            guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
                  !prefix.isEmpty else {
                return nil
            }

            return "\(prefix)com.poole.james.Trawl.shared"
        }
    }
}
