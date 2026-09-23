import Foundation
import Security

/// Stores ntfy credentials in the shared iOS Keychain access group so both the
/// main app and notification service extension can authenticate requests.
final class CredentialStore {
    static let shared = CredentialStore()

    private static let service = "com.emrikol.ntfy.credentials"
    private static let accessGroup = "3T9RX85H44.com.emrikol.ntfy.shared"

    private struct StoredCredential: Codable {
        let username: String
        let secret: String
    }

    private init() {}

    func save(baseUrl: String, user: BasicUser) throws {
        let account = normalizeBaseUrl(baseUrl)
        let data = try JSONEncoder().encode(
            StoredCredential(username: user.username, secret: user.password)
        )
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    func load(baseUrl: String) -> BasicUser? {
        var query = baseQuery(account: normalizeBaseUrl(baseUrl))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.w("CredentialStore", "Unable to read credentials from Keychain (OSStatus \(status))")
            }
            return nil
        }
        guard let credential = try? JSONDecoder().decode(StoredCredential.self, from: data) else {
            Log.w("CredentialStore", "Unable to decode credentials from Keychain")
            return nil
        }
        return BasicUser(username: credential.username, password: credential.secret)
    }

    func delete(baseUrl: String) {
        let status = SecItemDelete(baseQuery(account: normalizeBaseUrl(baseUrl)) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.w("CredentialStore", "Unable to delete credentials from Keychain (OSStatus \(status))")
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Self.accessGroup
        ]
    }
}

private enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain operation failed (OSStatus \(status))"
        }
    }
}
