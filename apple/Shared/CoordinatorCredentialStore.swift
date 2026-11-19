import Foundation
import Security

struct CoordinatorCredentialStore: Sendable {
    let servicePrefix: String

    init(servicePrefix: String = "com.section9labs.tachi.coordinator") {
        self.servicePrefix = servicePrefix
    }

    func load(origin: URL, account: String) async throws -> CoordinatorCredential? {
        var query = key(origin: origin, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let credential = try? JSONDecoder().decode(CoordinatorCredential.self, from: data),
              credential.isValid else {
            throw CredentialStoreError.read
        }
        return credential
    }

    func save(_ credential: CoordinatorCredential, origin: URL, account: String) async throws {
        var item = key(origin: origin, account: account)
        item[kSecValueData as String] = try JSONEncoder().encode(credential)
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw status == errSecDuplicateItem ? CredentialStoreError.occupied : CredentialStoreError.write
        }
    }

    func remove(origin: URL, account: String) async throws {
        let status = SecItemDelete(key(origin: origin, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.remove }
    }

    private func key(origin: URL, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix):\(origin.absoluteString)",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

enum CredentialStoreError: LocalizedError {
    case read
    case write
    case occupied
    case remove

    var errorDescription: String? {
        switch self {
        case .read: "Couldn’t read the saved account from Keychain."
        case .write: "Couldn’t save this account to Keychain. Unlock Keychain and ask for a new invitation."
        case .occupied: "This label already has a saved account. Check that account or choose a different label."
        case .remove: "Access was revoked. Couldn’t remove the device’s credential from Keychain."
        }
    }
}
